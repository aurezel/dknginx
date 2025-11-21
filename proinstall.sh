#!/bin/bash

###################################################
# 完整版一键部署脚本：
# - Git 自动克隆（交互式密码）
# - 使用 www 用户
# - Docker + Apache + PHP7.4
# - 宝塔 Nginx 自动反向代理
# - 自动处理目录权限
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

# 你的仓库
GIT_REPO="ssh://git@38.58.183.76:57577/home/git/local/stripifyv11.git"

echo "=============================================="
echo " 部署域名：$SUB_DOMAIN"
echo " 主域名：  $MAIN_DOMAIN"
echo " Docker：  $PROJECT_DIR"
echo " 网站目录：$WWW_DIR"
echo " 日志目录：$LOG_DIR"
echo " Git仓库： $GIT_REPO"
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
# 2️⃣ Git 克隆项目（交互式密码）
###################################################
echo "===> 开始克隆 Git 项目"

# 隐藏输入
read -sp "请输入 Git 仓库密码: " GIT_PASS
echo

# 安装 sshpass（若无）
if ! command -v sshpass >/dev/null 2>&1; then
    echo "安装 sshpass..."
    apt-get update -y
    apt-get install -y sshpass
fi

# 清空旧目录
if [ "$(ls -A $WWW_DIR)" ]; then
    echo "检测到 $WWW_DIR 非空 → 清空目录..."
    rm -rf ${WWW_DIR:?}/*
fi

# 克隆代码
sshpass -p "$GIT_PASS" git clone "$GIT_REPO" "$WWW_DIR"

if [ $? -ne 0 ]; then
    echo "❌ Git 克隆失败！请检查密码与仓库权限"
    exit 1
fi

echo "✔ Git 克隆成功！"

###################################################
# 3️⃣ 修复宿主机权限（全部改为 www）
###################################################
echo "修复目录权限..."

chown -R www:www $WWW_DIR
chown -R www:www $LOG_DIR

find $WWW_DIR -type d -exec chmod 755 {} \;
find $WWW_DIR -type f -exec chmod 644 {} \;

###################################################
# 4️⃣ 写 Dockerfile（使用 www 用户）
###################################################

cat > $PROJECT_DIR/Dockerfile <<EOF
FROM php:7.4-apache

ENV TZ=Asia/Shanghai

# 创建 www 用户
RUN groupadd -g 1000 www && \
    useradd -u 1000 -g 1000 -m -s /bin/bash www

RUN a2enmod rewrite

RUN chown -R www:www /var/www && \
    chown -R www:www /var/log/apache2

USER www

COPY vhost.conf /etc/apache2/sites-available/000-default.conf

WORKDIR /var/www/html
EOF

echo "Dockerfile 已生成"

###################################################
# 5️⃣ 生成 vhost.conf
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
# 6️⃣ 生成 docker-compose.yml
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
    networks:
      - deploy_net
    environment:
      - TZ=Asia/Shanghai

networks:
  deploy_net:
    driver: bridge
EOF

echo "docker-compose.yml 已生成"

###################################################
# 7️⃣ 启动 Docker
###################################################

cd $PROJECT_DIR
docker compose up -d --build

echo "Docker 已启动 → http://127.0.0.1:9001"

###################################################
# 8️⃣ 写入 nginx 配置
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

echo "=============================================="
echo "部署完成！🎉"
echo "访问地址：https://$SUB_DOMAIN"
echo "=============================================="
