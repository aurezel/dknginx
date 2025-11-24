#!/bin/bash

###################################################
# ProInstall.sh（Docker 与宿主机权限完全一致版本）
# - 宿主机 www UID/GID 自动读取 → Docker 内创建同 UID/GID
# - checkout 子目录 Git 部署
# - Docker PHP7.4 + Apache
# - 无日志挂载（彻底无权限问题）
# - 自动生成宝塔 Nginx 反代
###################################################

if [ $# -lt 1 ]; then
    echo "用法: $0 <子域名>"
    exit 1
fi

SUB_DOMAIN=$1
MAIN_DOMAIN=$(echo $SUB_DOMAIN | sed 's/^[^.]*\.//')

WWW_DIR="/www/wwwroot/$SUB_DOMAIN"
PROJECT_CODE_DIR="$WWW_DIR/checkout"
PROJECT_DIR="/opt/docker/$SUB_DOMAIN"
NGINX_CONF="/www/server/panel/vhost/nginx/${SUB_DOMAIN}.conf"

# 获取宿主机 www 用户 UID & GID
HOST_UID=$(id -u www)
HOST_GID=$(id -g www)

echo "宿主机用户 UID=$HOST_UID  GID=$HOST_GID"

GIT_REPO="ssh://git@38.58.183.76:57577/home/git/local/stripifyv11.git"

echo "=============================================="
echo " 部署域：$SUB_DOMAIN"
echo " 网站目录：$WWW_DIR"
echo " Docker 容器目录：$PROJECT_DIR"
echo " checkout 代码目录：$PROJECT_CODE_DIR"
echo " Docker 将使用 UID:GID → $HOST_UID:$HOST_GID"
echo "=============================================="

mkdir -p $PROJECT_DIR
mkdir -p $PROJECT_CODE_DIR

###################################################
# 1️⃣ 修复权限（不清空网站根目录）
###################################################
chattr -R -i $WWW_DIR 2>/dev/null
chown -R www:www $WWW_DIR

###################################################
# 2️⃣ Git clone/pull
###################################################
echo "=== Git 同步 checkout 目录 ==="

if [ ! -d "$PROJECT_CODE_DIR/.git" ]; then
    echo "checkout 目录无 Git 仓库 → 执行 clone"

    read -sp "请输入 Git 仓库密码: " GIT_PASS
    echo

    if ! command -v sshpass >/dev/null; then
        apt-get update -y
        apt-get install -y sshpass
    fi

    rm -rf ${PROJECT_CODE_DIR:?}/*

    sshpass -p "$GIT_PASS" \
    GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no" \
    git clone "$GIT_REPO" "$PROJECT_CODE_DIR"

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

###################################################
# 3️⃣ 生成 Dockerfile（宿主机权限继承）
###################################################
cat > $PROJECT_DIR/Dockerfile <<EOF
FROM php:7.4-apache

ENV TZ=Asia/Shanghai
ENV APACHE_LOG_DIR=/var/log/apache2

# 创建与宿主机一致的 www 用户
RUN groupadd -g ${HOST_GID} www || true
RUN useradd -u ${HOST_UID} -g ${HOST_GID} -m -s /bin/bash www || true

RUN a2enmod rewrite

USER root

# 提前创建日志，避免 403/500
RUN mkdir -p /var/log/apache2 && \
    touch /var/log/apache2/error.log && \
    touch /var/log/apache2/access.log && \
    chown -R www:www /var/log/apache2

RUN mkdir -p /var/www/html && \
    chown -R www:www /var/www

COPY vhost.conf /etc/apache2/sites-available/000-default.conf

USER www

WORKDIR /var/www/html
EOF

echo "✔ Dockerfile 生成完成"

###################################################
# 4️⃣ Apache vhost
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
# 5️⃣ docker-compose（无日志挂载）
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
      - net

networks:
  net:
    driver: bridge
EOF

echo "✔ docker-compose.yml 生成完成"

###################################################
# 6️⃣ Docker 构建启动
###################################################
cd $PROJECT_DIR
docker compose build
docker compose up -d

echo "✔ Docker 启动完成"

###################################################
# 7️⃣ 宝塔 Nginx 反代设置
###################################################

if grep -q "proxy_pass http://127.0.0.1:9001" "$NGINX_CONF" 2>/dev/null; then
    echo "✔ 检测到 Nginx 已配置反代 → 跳过"
else
    echo "执行 Nginx 配置写入..."

cat > $NGINX_CONF <<EOF
server
{
    listen 80;
    server_name $SUB_DOMAIN;
    return 301 https://\$server_name\$request_uri;
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
fi

echo "=============================================="
echo "🎉 部署完成（权限完美同步版）"
echo "访问：https://$SUB_DOMAIN"
echo "=============================================="