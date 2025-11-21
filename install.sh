#!/bin/bash

###################################################
# 一键部署 Docker + Apache + 宝塔 Nginx 自动反向代理
# 使用方式：
#   bash deploy.sh billing.payshopnow.com
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

echo "=============================================="
echo " 部署域名：$SUB_DOMAIN"
echo " 主域名：  $MAIN_DOMAIN"
echo " Docker：  $PROJECT_DIR"
echo " 网站目录：$WWW_DIR"
echo " 日志目录：$LOG_DIR"
echo "=============================================="

mkdir -p $PROJECT_DIR
mkdir -p $WWW_DIR
mkdir -p $LOG_DIR

###################################################
# 1️⃣ 解锁宝塔保护文件
###################################################

echo "解除宝塔保护文件锁定..."
chattr -R -i $WWW_DIR 2>/dev/null

###################################################
# 2️⃣ 修复宿主机权限（全部改为 www 用户）
###################################################

echo "修复宿主机目录权限（www: www）..."

chown -R www:www $WWW_DIR
chown -R www:www $LOG_DIR

find $WWW_DIR -type d -exec chmod 755 {} \;
find $WWW_DIR -type f -exec chmod 644 {} \;

###################################################
# 3️⃣ 写 OpenSSL Legacy Provider
###################################################

OPENSSL_FILE="/etc/ssl/openssl.cnf"

LEGACY_BLOCK=$(cat << 'EOF'
[openssl_init]
providers = provider_sect
[provider_sect]
default = default_sect
legacy = legacy_sect
[default_sect]
activate = 1
[legacy_sect]
activate = 1
EOF
)

if ! grep -q "\[openssl_init\]" "$OPENSSL_FILE"; then
    echo "$LEGACY_BLOCK" | sudo tee -a "$OPENSSL_FILE" > /dev/null
    echo "OpenSSL Legacy Provider 写入成功"
else
    echo "OpenSSL Legacy Provider 已存在"
fi

###################################################
# 4️⃣ Dockerfile（容器内部也改为 www 用户）
###################################################

cat > $PROJECT_DIR/Dockerfile <<EOF
FROM php:7.4-apache

ENV TZ=Asia/Shanghai

# 添加 www 用户（uid=1000）
RUN groupadd -g 1000 www && \
    useradd -u 1000 -g 1000 -m -s /bin/bash www

# 启用 Apache rewrite
RUN a2enmod rewrite

# 调整 Apache 目录权限
RUN chown -R www:www /var/www && \
    chown -R www:www /var/log/apache2

# 以 www 用户运行
USER www

COPY vhost.conf /etc/apache2/sites-available/000-default.conf

WORKDIR /var/www/html
EOF

echo "Dockerfile 已生成"

###################################################
# 5️⃣ Apache vhost.conf
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

echo "vhost.conf 已生成"

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
      - billing_network

networks:
  billing_network:
    driver: bridge
EOF

echo "docker-compose.yml 已生成"

###################################################
# 7️⃣ 启动 Docker 容器
###################################################

cd $PROJECT_DIR
docker compose up -d --build

echo "Docker 容器已启动 → http://127.0.0.1:9001"

###################################################
# 8️⃣ 写入 Nginx 反向代理
###################################################

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
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass http://127.0.0.1:9001;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
    }

    location ^~ /.well-known/acme-challenge/ {
        allow all;
    }

    location ~ ^/(\.user.ini|\.htaccess|\.git|\.env|README.md) {
        return 404;
    }

    access_log  /www/wwwlogs/$SUB_DOMAIN.log;
    error_log   /www/wwwlogs/$SUB_DOMAIN.error.log;
}
EOF

echo "Nginx 配置写入成功"

###################################################
# 9️⃣ 重载 nginx
###################################################

/www/server/nginx/sbin/nginx -s reload

echo "=============================================="
echo "部署完成！（www 用户版本）"
echo "访问：https://$SUB_DOMAIN"
echo "=============================================="
