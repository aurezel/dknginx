#!/bin/bash

###################################################
# ProInstall.sh（安全模式 + checkout 子目录版）
# - Git clone/pull → /www/wwwroot/<domain>/checkout
# - Docker PHP7.4 + Apache（www 用户）
# - 自动修复 Apache 日志权限
# - 自动生成 docker-compose + vhost.conf
# - 宝塔 Nginx 自动反代
###################################################

if [ $# -lt 1 ]; then
    echo "用法: $0 <子域名>"
    exit 1
fi

SUB_DOMAIN=$1
MAIN_DOMAIN=$(echo $SUB_DOMAIN | sed 's/^[^.]*\.//')

WWW_DIR="/www/wwwroot/$SUB_DOMAIN"              # 网站根目录（不清空）
PROJECT_CODE_DIR="$WWW_DIR/checkout"            # Git clone 在 checkout 子目录
PROJECT_DIR="/opt/docker/$SUB_DOMAIN"           # Docker 构建路径
LOG_DIR="/var/log/$SUB_DOMAIN"                  # Apache 日志目录
NGINX_CONF="/www/server/panel/vhost/nginx/${SUB_DOMAIN}.conf"

GIT_REPO="ssh://git@38.58.183.76:57577/home/git/local/stripifyv11.git"

echo "=============================================="
echo " 部署域名：$SUB_DOMAIN"
echo " 网站目录：$WWW_DIR"
echo " Git代码： $PROJECT_CODE_DIR"
echo " Docker：  $PROJECT_DIR"
echo " 日志目录：$LOG_DIR"
echo "=============================================="

mkdir -p $PROJECT_DIR
mkdir -p $PROJECT_CODE_DIR
mkdir -p $LOG_DIR

###################################################
# 1️⃣ 修复权限（不清空网站根目录）
###################################################
chattr -R -i $WWW_DIR 2>/dev/null

chown -R www:www $WWW_DIR
chown -R www:www $LOG_DIR

###################################################
# 2️⃣ Git（clone 或 pull，仅在 checkout 目录）
###################################################
echo "=== Git 部署（checkout 子目录）==="

if [ ! -d "$PROJECT_CODE_DIR/.git" ]; then
    echo "checkout 目录无 Git 仓库 → clone"

    read -sp "请输入 Git 仓库密码: " GIT_PASS
    echo

    if ! command -v sshpass >/dev/null; then
        apt-get update -y
        apt-get install -y sshpass
    fi

    # 清空 checkout 子目录（不影响网站目录）
    if [ "$(ls -A $PROJECT_CODE_DIR)" ]; then
        rm -rf ${PROJECT_CODE_DIR:?}/*
    fi

    sshpass -p "$GIT_PASS" git clone "$GIT_REPO" "$PROJECT_CODE_DIR"

    if [ $? -ne 0 ]; then
        echo "❌ Git clone 失败"
        exit 1
    fi
else
    echo "checkout 已存在 Git 仓库 → 执行 git pull"

    (
        cd "$PROJECT_CODE_DIR"
        git reset --hard
        git pull
    )
fi

echo "✔ Git 同步完成"

# 修复权限（checkout 目录）
chown -R www:www $PROJECT_CODE_DIR
find $PROJECT_CODE_DIR -type d -exec chmod 755 {} \;
find $PROJECT_CODE_DIR -type f -exec chmod 644 {} \;

###################################################
# 3️⃣ Dockerfile（包含 Apache 日志修复）
###################################################
cat > $PROJECT_DIR/Dockerfile <<EOF
FROM php:7.4-apache

ENV TZ=Asia/Shanghai

# 创建 www 用户
RUN groupadd -g 1000 www && \
    useradd -u 1000 -g 1000 -m -s /bin/bash www

RUN a2enmod rewrite

USER root

# 提前创建 Apache 日志文件（避免权限问题）
RUN mkdir -p /var/log/apache2 && \
    touch /var/log/apache2/error.log && \
    touch /var/log/apache2/access.log && \
    chown -R www:www /var/log/apache2

# 修复 web 根目录
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
# 5️⃣ docker-compose.yml（挂载整个网站目录）
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
# 6️⃣ Docker 构建 + 启动
###################################################
cd $PROJECT_DIR

docker compose build
docker compose up -d

echo "Docker 启动完成"

###################################################
# 7️⃣ 宝塔 Nginx 反代配置（存在则跳过）
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
    echo "Nginx 配置已存在 → 跳过写入"
fi

echo "=============================================="
echo "🎉 部署完成 | checkout 子目录 + 安全模式"
echo "访问地址：https://$SUB_DOMAIN"
echo "=============================================="
