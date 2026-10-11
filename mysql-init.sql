-- 本店安装时创建 tenant_1_db。不在这台机器上删除库。
GRANT CREATE ON *.* TO 'faka'@'%';
GRANT ALL ON `tenant_%`.* TO 'faka'@'%';
FLUSH PRIVILEGES;
