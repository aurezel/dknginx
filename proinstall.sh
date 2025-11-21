#!/bin/bash

###################################################
# ProInstall.sh（安全模式 + checkout 子目录 + 无日志挂载）
# - Git clone/pull → checkout 子目录
# - Docker PHP7.4 + Apache
# - 移除 Apache 日志挂载（彻底解决权限问题）
# - 自动反代到宝塔 Nginx
###################################################

if [ $# -lt 1 ]; then
    echo "用法: $0 <子域名>"
    exit 1
fi

SUB_DOMAIN=$1
MAIN_DOMAIN=$(echo $SUB_DOMAIN | sed 's/^[^.]*\.//')

WWW_DIR="/www/wwwroot/$SUB_DOMAIN"                # 网站根目录
PROJECT_CODE_DIR="$WWW_DIR/checkout"              # Git 代码目录
PROJECT_DIR="/opt/docker/$SUB_DOMAIN"             # Docker 构建目录
NGINX_CONF="/www/server/panel/vhost/nginx/${SUB_DOMAIN}.conf"

# Git 仓库
GIT_REPO="ssh://git@38.58.183.76:57577/home/git/local/stripifyv11.git"

echo "=============================================="
echo " 部署域名：$SUB_DOMAIN"
echo " 网站目录：$WWW_DIR"
echo " Git代码： $PROJECT_CODE_DIR"
echo " Docker：  $PROJECT_DIR"
echo "=============================================="

mkdir -p $PROJECT_DIR
mkdir -p $PROJECT_CODE_DIR

###################################################
# 1️⃣ 修复权限（不清空网站根目录）
###################################################
chattr -R -i $WWW_DIR 2>/dev/null
chown -R www:www $WWW_DIR

###################################################
# 2️⃣ Git clone/pull（安全模式）
###################################################
echo "=== Git 部署（checkout 子目录）==="

if [ ! -d "$PROJECT_CODE_DIR/.git" ]; then
    echo "checkout 目录无 Git 仓库 → 执行 clone"

    read -sp "请输入 Git 仓库密码: " GIT_PASS
    echo

    if ! command -v sshpass >/dev/null; then
        apt-get update -y
        apt-get install -y sshpass
    fi

    # 清空 checkout 子目录（不影响网站根目录其他文件）
    if [ "$(ls -A $PROJECT_CODE_DIR)" ]; then
        rm -rf ${PROJECT_CODE_DIR:?}/*
    fi

    sshpass -p "$GIT_PASS" git clone "$GIT_REPO" "$PROJECT_CODE_DIR"

    if [ $? -ne 0 ]; then
        echo "❌ Git clone 失败"
        exit 1
    fi
else
    echo "checkout 存在 Git 仓库 → 执行 pull"
    (
        cd "$PROJECT_CODE_DIR"
        git reset --hard
        git pull
    )
fi

echo "✔ Git 同步完成"

chown -R www:www $PROJECT_CODE_DIR
find $PROJECT_CODE_DIR -type d -exec chmod 755 {} \;
find $PROJECT_CODE_DIR -type f -exec chmod 644 {} \;

###################################################
# 3️⃣ Dockerfile（无需日志挂载）
###################################################
cat > $PROJECT_DIR/Dockerfile <<EOF
FROM php:7.4-apache

ENV TZ=Asia/Shanghai

# 创建 www 用户
RUN groupadd -g 1000 www && \
    useradd -u 1000 -g 1000 -m -s /bin/bash www

RUN a2enmod rewrite

USER root

# 提前创建 Apache 日志，避免容器内报错
RUN mkdir -p /var/log/apache2 && \
    touch /var/log/apache2/error.log && \
    touch /var/log/apache2/access.log && \
    chown -R www:www /var/log/apache2

# 修复 Web 根目录权限
RUN mkdir -p /var/www/html && chown -R www:www /var/www

USER www

COPY vhost.conf /etc/apache2/sites-available/000-default.conf

WORKDIR /var/www/html
EOF

echo "Dockerfile 已生成"

###################################################
# 4️⃣ vhost.conf
###################################################
cat > $PROJECT_DIR/vhost.conf <<EOF
<VirtualHost *:80>
    ServerName $SUB_DOMAIN
    DocumentRoot /var/www/html

    <Directory "/var/www/html">
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF

###################################################
# 5️⃣ docker-compose.yml（已删除日志挂载！）
###################################################
cat > $PROJECT_DIR/docker-compose.yml <<EOF
version: "3.8"

services:
  web:
    build: .
    container_name: ${SUB_DOMAIN//./_}
    restart: always
    ports:
      - "127.0.0.1:9001:80"
    volumes:
      - $WWW_DIR:/var/www/html
    environment:
      - TZ=Asia/Shanghai
    networks:
      - deploy_net

networks:
  deploy_net:
    driver: bridge
EOF

echo "docker-compose.yml 已生成（已删除日志挂载）"

###################################################
# 6️⃣ Docker 构建 + 启动
###################################################
cd $PROJECT_DIR

docker compose build
docker compose up -d

echo "Docker 启动完成"

###################################################
# 7️⃣ 宝塔 Nginx 自动反代（存在则跳过）
###################################################

if [ ! -f "$NGINX_CONF" ]; then
    echo "写入 Nginx 反代配置..."

cat > $NGINX_CONF <<EOF
server
{
    listen 80;
    server_name $SUB_DOMAIN;
    return 301 https://\$host\$request_uri;
}

server
{
    listen 443 ssl http2;
    server_name $SUB_DOMAIN;

    ssl_certificate       /www/server/panel/vhost/cert/$SUB_DOMAIN/fullchain.pem;
    ssl_certificate_key   /www/server/panel/vhost/cert/$SUB_DOMAIN/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:9001;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

    /www/server/nginx/sbin/nginx -s reload
else
    echo "Nginx 配置已存在 → 跳过"
fi

echo "=============================================="
echo "🎉 部署完成（无日志挂载版本，100% 稳定）"
echo "访问：https://$SUB_DOMAIN"
echo "=============================================="
