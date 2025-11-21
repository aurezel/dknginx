#!/bin/bash

###################################################
# 安全模式一键部署脚本（可重复执行不会破坏数据）
# - 自动 clone 或 pull（不会清空目录）
# - 使用 www 用户
# - Docker + PHP7.4 + Apache
# - 自动修复 Apache 日志权限
# - 宝塔 Nginx 自动反代（若存在则不覆盖）
###################################################

if [ $# -lt 1 ]; then
    echo "用法: $0 <子域名>"
    exit 1
fi

SUB_DOMAIN=$1
MAIN_DOMAIN=$(echo $SUB_DOMAIN | sed 's/^[^.]*\.//')

PROJECT_DIR="/opt/docker/$SUB_DOMAIN"
WWW_DIR="/www/wwwroot/$SUB_DOMAIN"
LOG_DIR="/var/log/$SUB_DOMAIN"
NGINX_CONF="/www/server/panel/vhost/nginx/${SUB_DOMAIN}.conf"

GIT_REPO="ssh://git@38.58.183.76:57577/home/git/local/stripifyv11.git"

echo "=============================================="
echo " 部署域名：$SUB_DOMAIN"
echo " Docker：  $PROJECT_DIR"
echo " 网站目录：$WWW_DIR"
echo " 日志目录：$LOG_DIR"
echo " Git仓库： $GIT_REPO"
echo "=============================================="

mkdir -p $PROJECT_DIR
mkdir -p $LOG_DIR

###################################################
# 1️⃣ 目录权限处理
###################################################
chattr -R -i $WWW_DIR 2>/dev/null
mkdir -p $WWW_DIR

echo "修复权限..."
chown -R www:www $WWW_DIR
chown -R www:www $LOG_DIR

###################################################
# 2️⃣ Git（安全模式 clone/pull）
###################################################
echo "=== Git 部署 ==="

if [ ! -d "$WWW_DIR/.git" ]; then
    echo "目录不存在 Git 仓库 → 执行 clone"

    read -sp "请输入 Git 仓库密码: " GIT_PASS
    echo

    if ! command -v sshpass >/dev/null; then
        apt-get update -y
        apt-get install -y sshpass
    fi

    sshpass -p "$GIT_PASS" git clone "$GIT_REPO" "$WWW_DIR"
    if [ $? -ne 0 ]; then
        echo "❌ Git clone 失败"
        exit 1
    fi
else
    echo "检测到已有 Git 仓库 → 执行 git pull"
    (
        cd $WWW_DIR
        git reset --hard
        git pull
    )
fi

echo "✔ Git 同步完成"

###################################################
# 3️⃣ 权限再次修复
###################################################
chown -R www:www $WWW_DIR
find $WWW_DIR -type d -exec chmod 755 {} \;
find $WWW_DIR -type f -exec chmod 644 {} \;

###################################################
# 4️⃣ 生成 Dockerfile（带日志修复）
###################################################

cat > $PROJECT_DIR/Dockerfile <<EOF
FROM php:7.4-apache

ENV TZ=Asia/Shanghai

# 创建 www 用户
RUN groupadd -g 1000 www && \
    useradd -u 1000 -g 1000 -m -s /bin/bash www

RUN a2enmod rewrite

USER root

# 提前创建 Apache 日志（解决权限问题）
RUN mkdir -p /var/log/apache2 && \
    touch /var/log/apache2/error.log && \
    touch /var/log/apache2/access.log && \
    chown -R www:www /var/log/apache2

# 修复 web 目录权限
RUN mkdir -p /var/www/html && \
    chown -R www:www /var/www

USER www

COPY vhost.conf /etc/apache2/sites-available/000-default.conf

WORKDIR /var/www/html
EOF

echo "Dockerfile 已生成"

###################################################
# 5️⃣ vhost.conf
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
# 6️⃣ docker-compose.yml
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
      - $LOG_DIR:/var/log/apache2
    environment:
      - TZ=Asia/Shanghai
    networks:
      - deploy_net

networks:
  deploy_net:
    driver: bridge
EOF

###################################################
# 7️⃣ 启动/更新 Docker（智能模式）
###################################################
cd $PROJECT_DIR

echo "=== Docker 构建 ==="

docker compose build
docker compose up -d

echo "Docker 已启动（智能安全模式）"

###################################################
# 8️⃣ 宝塔 Nginx 反代（已存在不会覆盖）
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

    echo "重载 nginx..."
    /www/server/nginx/sbin/nginx -s reload
else
    echo "检测到 Nginx 配置已存在 → 跳过写入"
fi

echo "=============================================="
echo "🎉 安全模式部署完成（可重复执行，无风险）"
echo "访问：https://$SUB_DOMAIN"
echo "=============================================="
