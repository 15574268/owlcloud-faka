#!/usr/bin/env bash
# 租户自托管安装：拉取店端镜像（不含主控），写入配置并启动。
# 用法：
#   sudo bash install-tenant.sh \
#     --master-url https://master.example.com \
#     --license FK-xxxx \
#     --shop-domain shop.example.com \
#     --admin-domain admin.example.com \
#     --image-prefix registry.example.com/yourns
# 这台机器已有 MySQL / Redis / RabbitMQ 时加上 --use-existing，不再另起一套。
# 卡密密钥用 --card-key。不写则新安装时生成；已有 .env 且未写该参数时沿用原来的。
set -euo pipefail

need() { command -v "$1" >/dev/null 2>&1 || { echo "缺少命令：$1"; exit 1; }; }

MASTER_BASE_URL=""
LICENSE_KEY=""
SHOP_DOMAIN=""
ADMIN_DOMAIN=""
IMAGE_PREFIX="faka"
IMAGE_TAG="1.0.0"
HTTP_BIND="29101"
DIR="$(pwd)/faka-tenant"
USE_EXISTING=0
MYSQL_HOST_ARG=""
MYSQL_PORT_ARG=""
MYSQL_USER_ARG=""
MYSQL_PASSWORD_ARG=""
REDIS_ADDR_ARG=""
REDIS_PASSWORD_ARG=""
REDIS_PASSWORD_SET=0
RABBITMQ_URL_ARG=""
FAKA_CARD_KEY_ARG=""
FAKA_CARD_KEY_SET=0

usage() {
  sed -n '2,11p' "$0"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --master-url) MASTER_BASE_URL="$2"; shift 2 ;;
    --license) LICENSE_KEY="$2"; shift 2 ;;
    --shop-domain) SHOP_DOMAIN="$2"; shift 2 ;;
    --admin-domain) ADMIN_DOMAIN="$2"; shift 2 ;;
    --image-prefix) IMAGE_PREFIX="$2"; shift 2 ;;
    --tag) IMAGE_TAG="$2"; shift 2 ;;
    --http-bind) HTTP_BIND="$2"; shift 2 ;;
    --dir) DIR="$2"; shift 2 ;;
    --use-existing) USE_EXISTING=1; shift ;;
    --mysql-host) MYSQL_HOST_ARG="$2"; shift 2 ;;
    --mysql-port) MYSQL_PORT_ARG="$2"; shift 2 ;;
    --mysql-user) MYSQL_USER_ARG="$2"; shift 2 ;;
    --mysql-password) MYSQL_PASSWORD_ARG="$2"; shift 2 ;;
    --redis-addr) REDIS_ADDR_ARG="$2"; shift 2 ;;
    --redis-password) REDIS_PASSWORD_ARG="$2"; REDIS_PASSWORD_SET=1; shift 2 ;;
    --rabbitmq-url) RABBITMQ_URL_ARG="$2"; shift 2 ;;
    --card-key) FAKA_CARD_KEY_ARG="$2"; FAKA_CARD_KEY_SET=1; shift 2 ;;
    -h|--help) usage ;;
    *) echo "未知参数：$1"; usage ;;
  esac
done

prompt() {
  local var="$1" msg="$2" def="${3:-}"
  local cur="${!var}"
  if [[ -n "$cur" ]]; then return; fi
  if [[ -n "$def" ]]; then
    read -r -p "$msg [$def]: " cur || true
    cur="${cur:-$def}"
  else
    read -r -p "$msg: " cur || true
  fi
  printf -v "$var" '%s' "$cur"
}

strip_host() {
  local d="$1"
  d="${d#http://}"
  d="${d#https://}"
  d="${d%%/*}"
  d="${d,,}"
  printf '%s' "$d"
}

rand() {
  local n="${1:-32}"
  # head 读够就关管道，tr 会 SIGPIPE；pipefail 下必须忽略，否则 Debian 上会静默退出
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$n" || true
}

prompt MASTER_BASE_URL "主控地址，例如 https://master.example.com"
prompt LICENSE_KEY "授权码 FK-xxxx（可留空，不填也能开店）"
prompt SHOP_DOMAIN "商城域名（不要加 https://）"
prompt ADMIN_DOMAIN "后台域名"
prompt IMAGE_PREFIX "镜像前缀（平台提供）" "$IMAGE_PREFIX"

MASTER_BASE_URL="${MASTER_BASE_URL%/}"
SHOP_DOMAIN="$(strip_host "$SHOP_DOMAIN")"
ADMIN_DOMAIN="$(strip_host "$ADMIN_DOMAIN")"

echo "==> 安装到 $DIR （HTTP 端口 $HTTP_BIND）"
if [[ -z "$MASTER_BASE_URL" || -z "$SHOP_DOMAIN" || -z "$ADMIN_DOMAIN" ]]; then
  echo "主控地址、商城域名、后台域名都不能空"
  exit 1
fi
if [[ "$LICENSE_KEY" == "FK-DEMO-LOCAL" ]]; then
  echo "不要用 FK-DEMO-LOCAL"
  exit 1
fi

need docker
if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  echo "需要 Docker Compose 插件"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC=""
if [[ -f "$SCRIPT_DIR/../deploy/tenant-stack/docker-compose.yml" ]]; then
  SRC="$(cd "$SCRIPT_DIR/../deploy/tenant-stack" && pwd)"
elif [[ -f "$SCRIPT_DIR/docker-compose.yml" ]]; then
  SRC="$SCRIPT_DIR"
else
  echo "找不到 deploy/tenant-stack。请把安装脚本和 tenant-stack 目录放在一起，或在仓库里执行。"
  exit 1
fi
if [[ ! -f "$SRC/docker-compose.middleware.yml" ]]; then
  echo "找不到 docker-compose.middleware.yml"
  exit 1
fi

mkdir -p "$DIR/config"
cp -f "$SRC/docker-compose.yml" "$SRC/mysql-init.sql" "$DIR/"
YAML_EXISTED=0
if [[ -f "$DIR/config/tenant.yaml" ]]; then
  YAML_EXISTED=1
fi
ENV_FILE="$DIR/.env"
if [[ "$YAML_EXISTED" -eq 1 && ! -f "$ENV_FILE" ]]; then
  echo "发现已有 $DIR/config/tenant.yaml，但缺少 $ENV_FILE。"
  echo "请先恢复原 .env（含 FAKA_CARD_KEY 和数据库密码）。不要在这里重新生成，否则旧卡密解不开、数据库也连不上。"
  exit 1
fi
if [[ -f "$SRC/https-proxy.conf.example" ]]; then
  sed -e "s/ADMIN_DOMAIN_HERE/${ADMIN_DOMAIN}/g" \
      -e "s/SHOP_DOMAIN_HERE/${SHOP_DOMAIN}/g" \
      -e "s/HTTP_BIND_HERE/${HTTP_BIND}/g" \
    "$SRC/https-proxy.conf.example" >"$DIR/https-proxy.conf.example"
fi
if [[ -f "$SRC/README.md" ]]; then
  cp -f "$SRC/README.md" "$DIR/README.md"
fi

MASTER_BASE_URL_IN="$MASTER_BASE_URL"
LICENSE_KEY_IN="$LICENSE_KEY"
SHOP_DOMAIN_IN="$SHOP_DOMAIN"
ADMIN_DOMAIN_IN="$ADMIN_DOMAIN"
HTTP_BIND_IN="$HTTP_BIND"
USE_EXISTING_CLI="$USE_EXISTING"

MYSQL_ROOT_PASSWORD="$(rand 32)"
MYSQL_PASSWORD="$(rand 32)"
REDIS_PASSWORD="$(rand 32)"
RABBITMQ_PASSWORD="$(rand 32)"
TENANT_ADMIN_JWT_SECRET="$(rand 48)"
TENANT_SHOP_JWT_SECRET="$(rand 48)"
FAKA_CARD_KEY="$(rand 48)"
SEED_TENANT_PASS="$(rand 20)"
MYSQL_HOST="mysql"
MYSQL_PORT="3306"
MYSQL_USER="faka"
REDIS_ADDR="redis:6379"
MIDDLEWARE_NETWORK=""

ENV_FILE="$DIR/.env"
ENV_EXISTED=0
SAVED_EXISTING=0
if [[ -f "$ENV_FILE" ]] && grep -q '^USE_EXISTING=1$' "$ENV_FILE"; then
  SAVED_EXISTING=1
fi
if [[ -f "$ENV_FILE" ]]; then
  ENV_EXISTED=1
  echo "发现已有 $ENV_FILE，复用其中的密钥（域名/授权会更新）"
  set -a
  # shellcheck disable=SC1091
  source "$ENV_FILE"
  set +a
  MASTER_BASE_URL="$MASTER_BASE_URL_IN"
  LICENSE_KEY="$LICENSE_KEY_IN"
  SHOP_DOMAIN="$SHOP_DOMAIN_IN"
  ADMIN_DOMAIN="$ADMIN_DOMAIN_IN"
  HTTP_BIND="$HTTP_BIND_IN"
  if [[ "$USE_EXISTING_CLI" == "1" && "$SAVED_EXISTING" != "1" ]]; then
    echo "这台店已经在用安装包自带的数据库，不能改成已有容器。"
    exit 1
  fi
  if [[ "$USE_EXISTING_CLI" != "1" ]]; then
    USE_EXISTING="${USE_EXISTING:-0}"
  fi
fi
if [[ "$USE_EXISTING_CLI" == "1" ]]; then
  USE_EXISTING=1
fi

no_break() {
  case "$1" in
    *[[:space:]]*|*\#*) echo "$2 不要包含空格或 #"; exit 1 ;;
  esac
}

if [[ "$FAKA_CARD_KEY_SET" == "1" ]]; then
  if [[ -z "$FAKA_CARD_KEY_ARG" ]]; then
    echo "卡密密钥不能为空"
    exit 1
  fi
  no_break "$FAKA_CARD_KEY_ARG" "卡密密钥"
  if [[ "$FAKA_CARD_KEY_ARG" == *\"* || "$FAKA_CARD_KEY_ARG" == *\'* || "$FAKA_CARD_KEY_ARG" == *\$* ]]; then
    echo "卡密密钥不要包含引号或 \$"
    exit 1
  fi
  if [[ "$ENV_EXISTED" == "1" && "$FAKA_CARD_KEY" != "$FAKA_CARD_KEY_ARG" ]]; then
    echo "已有 .env 里的 FAKA_CARD_KEY 与本次 --card-key 不同。将改用命令里的密钥，此前已入库的卡密会解不开。"
  fi
  FAKA_CARD_KEY="$FAKA_CARD_KEY_ARG"
fi

if [[ "$USE_EXISTING" == "1" ]]; then
  [[ -n "$MYSQL_HOST_ARG" ]] && MYSQL_HOST="$MYSQL_HOST_ARG"
  [[ -n "$MYSQL_PORT_ARG" ]] && MYSQL_PORT="$MYSQL_PORT_ARG"
  [[ -n "$MYSQL_USER_ARG" ]] && MYSQL_USER="$MYSQL_USER_ARG"
  [[ -n "$MYSQL_PASSWORD_ARG" ]] && MYSQL_PASSWORD="$MYSQL_PASSWORD_ARG"
  [[ -n "$REDIS_ADDR_ARG" ]] && REDIS_ADDR="$REDIS_ADDR_ARG"
  if [[ "$REDIS_PASSWORD_SET" == "1" ]]; then
    REDIS_PASSWORD="$REDIS_PASSWORD_ARG"
  fi
  [[ -n "$RABBITMQ_URL_ARG" ]] && RABBITMQ_URL="$RABBITMQ_URL_ARG"
  RABBITMQ_URL="${RABBITMQ_URL:-}"
  if [[ "$ENV_EXISTED" == "0" ]]; then
    if [[ -z "$MYSQL_HOST_ARG" || -z "$MYSQL_PASSWORD_ARG" || -z "$REDIS_ADDR_ARG" ]]; then
      echo "使用已有容器时要同时给出 --mysql-host --mysql-password --redis-addr"
      echo "这台机器另有 RabbitMQ 时再加 --rabbitmq-url。不填则在店内容发货。"
      exit 1
    fi
  fi
  if [[ -z "${MYSQL_HOST:-}" || -z "${MYSQL_PASSWORD:-}" || -z "${REDIS_ADDR:-}" ]]; then
    echo "已有容器的地址或密码不完整。请补上 --mysql-host --mysql-password --redis-addr"
    exit 1
  fi
  MYSQL_PORT="${MYSQL_PORT:-3306}"
  MYSQL_USER="${MYSQL_USER:-faka}"
  no_break "$MYSQL_PASSWORD" "MySQL 密码"
  no_break "$REDIS_PASSWORD" "Redis 密码"
  if [[ -n "$RABBITMQ_URL" ]]; then
    no_break "$RABBITMQ_URL" "RabbitMQ 地址"
  fi
else
  MYSQL_HOST="mysql"
  MYSQL_PORT="3306"
  MYSQL_USER="${MYSQL_USER:-faka}"
  REDIS_ADDR="redis:6379"
  RABBITMQ_URL="amqp://faka:${RABBITMQ_PASSWORD}@rabbitmq:5672/"
  MIDDLEWARE_NETWORK=""
fi

TENANT_IMAGE="${IMAGE_PREFIX}/tenant:${IMAGE_TAG}"
WEB_IMAGE="${IMAGE_PREFIX}/tenant-web:${IMAGE_TAG}"
UPDATER_IMAGE="${IMAGE_PREFIX}/tenant-updater:${IMAGE_TAG}"
UPDATER_URL="http://updater:8791"
if [[ -z "${UPDATER_TOKEN:-}" ]]; then
  UPDATER_TOKEN="$(rand 48)"
fi
INSTALL_DIR="$(cd "$DIR" && pwd)"
DOCKER_CONFIG_DIR="/root/.docker"
if [[ -n "${DOCKER_CONFIG:-}" && -f "${DOCKER_CONFIG}/config.json" ]]; then
  DOCKER_CONFIG_DIR="$DOCKER_CONFIG"
elif [[ -f /root/.docker/config.json ]]; then
  DOCKER_CONFIG_DIR="/root/.docker"
elif [[ -n "${SUDO_USER:-}" && -f "/home/${SUDO_USER}/.docker/config.json" ]]; then
  DOCKER_CONFIG_DIR="/home/${SUDO_USER}/.docker"
elif [[ -n "${HOME:-}" && "${HOME}" != "/" && -f "${HOME}/.docker/config.json" ]]; then
  DOCKER_CONFIG_DIR="${HOME}/.docker"
fi
PAY_PUBLIC_BASE_URL="https://${SHOP_DOMAIN}"
RABBIT_ENABLED="true"
if [[ -z "${RABBITMQ_URL:-}" ]]; then
  RABBIT_ENABLED="false"
fi

remember_network() {
  local target="$1"
  if [[ -z "$target" || "$target" == "localhost" || "$target" == "127.0.0.1" ]]; then
    echo "店端在容器里，不能用 127.0.0.1 连接宿主机上的库。请填容器名，或填 host.docker.internal。"
    exit 1
  fi
  if [[ "$target" == *.* || "$target" == *:* ]]; then
    return 0
  fi
  if ! docker inspect "$target" >/dev/null 2>&1; then
    echo "找不到容器 $target。请填已有容器名，或填 host.docker.internal。"
    exit 1
  fi
  local net
  net="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "$target" | grep -v -E '^(bridge|host|none)$' | head -n 1 || true)"
  if [[ -z "$net" ]]; then
    echo "容器 $target 不在自定义网络上，店端无法用容器名访问它。"
    exit 1
  fi
  if [[ -n "$MIDDLEWARE_NETWORK" && "$MIDDLEWARE_NETWORK" != "$net" ]]; then
    echo "MySQL、Redis、RabbitMQ 不在同一个 Docker 网络：$MIDDLEWARE_NETWORK 和 $net"
    exit 1
  fi
  MIDDLEWARE_NETWORK="$net"
}

PROXY_NETWORK="faka-tenant-proxy"
PROXY_EXTERNAL="false"
if docker network inspect 1panel-network >/dev/null 2>&1; then
  PROXY_NETWORK="1panel-network"
  PROXY_EXTERNAL="true"
fi

if [[ "$USE_EXISTING" == "1" ]]; then
  MIDDLEWARE_NETWORK=""
  remember_network "$MYSQL_HOST"
  remember_network "${REDIS_ADDR%%:*}"
  if [[ -n "$RABBITMQ_URL" ]]; then
    rabbit_host="${RABBITMQ_URL#*://}"
    rabbit_host="${rabbit_host#*@}"
    rabbit_host="${rabbit_host%%/*}"
    rabbit_host="${rabbit_host%%:*}"
    remember_network "$rabbit_host"
  fi
  if [[ -n "$MIDDLEWARE_NETWORK" && "$MIDDLEWARE_NETWORK" != "$PROXY_NETWORK" ]]; then
    cat >"$DIR/docker-compose.override.yml" <<EOF
services:
  tenant:
    networks:
      - faka
      - middleware
networks:
  middleware:
    external: true
    name: ${MIDDLEWARE_NETWORK}
EOF
    echo "==> 连接已有容器，网络 $MIDDLEWARE_NETWORK"
  elif [[ -n "$MIDDLEWARE_NETWORK" ]]; then
    cat >"$DIR/docker-compose.override.yml" <<EOF
services:
  tenant:
    networks:
      - faka
      - proxy
EOF
    echo "==> 连接已有容器，网络 $MIDDLEWARE_NETWORK"
  else
    rm -f "$DIR/docker-compose.override.yml"
    echo "==> 连接已有容器（通过 host.docker.internal）"
  fi
else
  cp -f "$SRC/docker-compose.middleware.yml" "$DIR/docker-compose.override.yml"
  echo "==> 使用安装包自带的 MySQL / Redis / RabbitMQ"
fi
if [[ "$PROXY_EXTERNAL" == "true" ]]; then
  echo "==> 网站容器接入 $PROXY_NETWORK，1Panel 反代填 http://faka-tenant-web:29101"
fi

cat >"$ENV_FILE" <<EOF
MASTER_BASE_URL=$MASTER_BASE_URL
LICENSE_KEY=$LICENSE_KEY
SHOP_DOMAIN=$SHOP_DOMAIN
ADMIN_DOMAIN=$ADMIN_DOMAIN
PAY_PUBLIC_BASE_URL=$PAY_PUBLIC_BASE_URL
HTTP_BIND=$HTTP_BIND
USE_EXISTING=$USE_EXISTING
MIDDLEWARE_NETWORK=$MIDDLEWARE_NETWORK
MYSQL_HOST=$MYSQL_HOST
MYSQL_PORT=$MYSQL_PORT
MYSQL_USER=$MYSQL_USER
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
MYSQL_PASSWORD=$MYSQL_PASSWORD
REDIS_ADDR=$REDIS_ADDR
REDIS_PASSWORD=$REDIS_PASSWORD
RABBITMQ_USER=${RABBITMQ_USER:-faka}
RABBITMQ_PASSWORD=$RABBITMQ_PASSWORD
RABBITMQ_URL=$RABBITMQ_URL
TENANT_ADMIN_JWT_SECRET=$TENANT_ADMIN_JWT_SECRET
TENANT_SHOP_JWT_SECRET=$TENANT_SHOP_JWT_SECRET
FAKA_CARD_KEY=$FAKA_CARD_KEY
SEED_TENANT_PASS=$SEED_TENANT_PASS
TENANT_IMAGE=$TENANT_IMAGE
WEB_IMAGE=$WEB_IMAGE
UPDATER_IMAGE=$UPDATER_IMAGE
UPDATER_URL=$UPDATER_URL
UPDATER_TOKEN=$UPDATER_TOKEN
INSTALL_DIR=$INSTALL_DIR
DOCKER_CONFIG_DIR=$DOCKER_CONFIG_DIR
PROXY_NETWORK=$PROXY_NETWORK
PROXY_EXTERNAL=$PROXY_EXTERNAL
EOF

if [[ "$YAML_EXISTED" -eq 1 ]]; then
  echo "保留已有 $DIR/config/tenant.yaml（不覆盖 tenant_id / 库名）"
else
  cat >"$DIR/config/tenant.yaml" <<EOF
server:
  name: faka-tenant
  host: 0.0.0.0
  port: 8081
  mode: release
master:
  base_url: $MASTER_BASE_URL
  heartbeat_hours: 6
mysql:
  host: $MYSQL_HOST
  port: $MYSQL_PORT
  user: $MYSQL_USER
  password: "$MYSQL_PASSWORD"
  database: tenant_1_db
  charset: utf8mb4
  max_idle: 10
  max_open: 100
redis:
  addr: $REDIS_ADDR
  password: "$REDIS_PASSWORD"
  db: 1
rabbitmq:
  enabled: $RABBIT_ENABLED
  url: "$RABBITMQ_URL"
jwt:
  admin_secret: "$TENANT_ADMIN_JWT_SECRET"
  shop_secret: "$TENANT_SHOP_JWT_SECRET"
  expire_hours: 12
license:
  key: "$LICENSE_KEY"
  domain: $SHOP_DOMAIN
  cache_ttl_hours: 24
order:
  unpaid_timeout_minutes: 15
  after_sale_days: 7
  scan_interval_minutes: 5
fulfillment:
  max_retry: 3
  backoff: [60, 300, 1800]
  worker_num: 8
seckill:
  qualify_ttl_seconds: 120
pay:
  public_base_url: $PAY_PUBLIC_BASE_URL
security:
  card_key: "$FAKA_CARD_KEY"
seed:
  admin_user: shopadmin
  admin_pass: "$SEED_TENANT_PASS"
EOF
fi

CREATED_LOGIN=0
if [[ ! -f "$DIR/FIRST-LOGIN.txt" ]]; then
  cat >"$DIR/FIRST-LOGIN.txt" <<EOF
shopadmin / $SEED_TENANT_PASS
后台 http://$ADMIN_DOMAIN/install
商城 http://$SHOP_DOMAIN
FAKA_CARD_KEY 在 .env，丢失则旧卡密解不开。
EOF
  CREATED_LOGIN=1
fi

echo "==> 拉取并启动 $TENANT_IMAGE / $WEB_IMAGE / $UPDATER_IMAGE"
cd "$DIR"
"${COMPOSE[@]}" --env-file .env pull
"${COMPOSE[@]}" --env-file .env up -d

wait_shop() {
  local seconds="${1:-60}"
  local i=0
  while [[ $i -lt $seconds ]]; do
    if command -v curl >/dev/null 2>&1 && curl -fsS "http://127.0.0.1:${HTTP_BIND}/healthz" >/dev/null 2>&1; then
      return 0
    fi
    if ! command -v curl >/dev/null 2>&1 && (echo >/dev/tcp/127.0.0.1/"$HTTP_BIND") >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

if wait_shop 60; then
  echo "shop OK  http://127.0.0.1:${HTTP_BIND}/healthz"
else
  echo "店铺未就绪。最近日志："
  docker logs --tail 80 faka-tenant 2>&1 || true
  exit 1
fi

echo
if [[ "$PROXY_EXTERNAL" == "true" ]]; then
  echo "1Panel：后台和商城都整站反代到 http://faka-tenant-web:29101 ，并带上 Host。"
fi
echo "宝塔或宿主机 Nginx：整站反代到 http://127.0.0.1:${HTTP_BIND}"
echo "  示例配置：$DIR/https-proxy.conf.example"
echo "  后台  https://$ADMIN_DOMAIN/install"
echo "  商城  https://$SHOP_DOMAIN"
echo "  账号  shopadmin"
if [[ "$CREATED_LOGIN" -eq 1 ]]; then
  echo "  密码  $SEED_TENANT_PASS  （也写在 FIRST-LOGIN.txt）"
else
  echo "  密码  见 $DIR/FIRST-LOGIN.txt（若已在后台改过密，以当前密码为准）"
fi
echo
echo "配置目录：$DIR"
echo "卡密口令在 .env 的 FAKA_CARD_KEY，丢失则旧卡密解不开。"
if [[ "$USE_EXISTING" == "1" ]]; then
  echo "MySQL、Redis、RabbitMQ 用的是已有容器，停止店端不会关掉它们。"
fi
echo "停止：cd $DIR && ${COMPOSE[*]} --env-file .env down"
