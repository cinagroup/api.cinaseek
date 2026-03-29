#!/bin/bash
# CinaToken 服务器 A（主节点）自动化配置脚本
# 适用于 Ubuntu 22.04 LTS

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否以 root 运行
if [ "$EUID" -ne 0 ]; then
    log_error "请以 root 用户运行此脚本：sudo $0"
    exit 1
fi

log_info "=========================================="
log_info "CinaToken 服务器 A（主节点）配置脚本"
log_info "=========================================="

# 步骤 1：更新系统
log_info "步骤 1/10: 更新系统..."
apt update && apt upgrade -y
log_success "系统更新完成"

# 步骤 2：安装基础工具
log_info "步骤 2/10: 安装基础工具..."
apt install -y curl wget vim git htop net-tools jq
log_success "基础工具安装完成"

# 步骤 3：安装 Docker
log_info "步骤 3/10: 安装 Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
    log_success "Docker 安装完成"
else
    log_warning "Docker 已安装，跳过"
fi

# 步骤 4：安装 Docker Compose
log_info "步骤 4/10: 安装 Docker Compose..."
if ! command -v docker-compose &> /dev/null; then
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    log_success "Docker Compose 安装完成"
else
    log_warning "Docker Compose 已安装，跳过"
fi

# 步骤 5：创建部署目录
log_info "步骤 5/10: 创建部署目录..."
DEPLOY_DIR="/opt/cinatoken"
mkdir -p $DEPLOY_DIR/{data,logs,backup,ssl,nginx/conf.d,postgres}
cd $DEPLOY_DIR
log_success "部署目录创建完成：$DEPLOY_DIR"

# 步骤 6：生成配置文件
log_info "步骤 6/10: 生成配置文件..."

# 生成随机密码和密码
DB_PASSWORD=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
SESSION_SECRET=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 64)
REPLICATION_PASSWORD=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)

# 保存配置到文件
cat > $DEPLOY_DIR/.env << EOF
# CinaToken 环境配置
# 生成时间：$(date)

# 数据库配置
DB_PASSWORD=$DB_PASSWORD
REPLICATION_PASSWORD=$REPLICATION_PASSWORD

# 会话配置
SESSION_SECRET=$SESSION_SECRET

# 域名配置（请修改为你的域名）
DOMAIN=your-domain.com
BACKUP_DOMAIN=backup.your-domain.com

# 服务器 IP（请修改为实际 IP）
MASTER_IP=$(curl -s ifconfig.me)
SLAVE_IP=请配置从节点 IP
EOF

chmod 600 $DEPLOY_DIR/.env
log_success "环境配置文件生成完成"

# 加载环境变量
source $DEPLOY_DIR/.env

# 创建 docker-compose.yml
cat > $DEPLOY_DIR/docker-compose.yml << EOF
version: '3.8'

services:
  # CinaToken 主应用
  cinatoken:
    image: cinagroup/cinatoken:latest
    container_name: cinatoken
    restart: always
    ports:
      - "3000:3000"
    volumes:
      - ./data:/data
      - ./logs:/app/logs
    environment:
      - SQL_DSN=postgresql://cinatoken:${DB_PASSWORD}@postgres:5432/cinatoken
      - REDIS_CONN_STRING=redis://redis:6379
      - TZ=Asia/Shanghai
      - SESSION_SECRET=${SESSION_SECRET}
      - ERROR_LOG_ENABLED=true
      - BATCH_UPDATE_ENABLED=true
      - STREAMING_TIMEOUT=300
    depends_on:
      - postgres
      - redis
    networks:
      - cinatoken-net
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "-", "http://localhost:3000/api/status"]
      interval: 30s
      timeout: 10s
      retries: 3

  # PostgreSQL 数据库（主库）
  postgres:
    image: postgres:15-alpine
    container_name: cinatoken-db
    restart: always
    environment:
      POSTGRES_USER: cinatoken
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_DB: cinatoken
      POSTGRES_INITDB_ARGS: "-c wal_level=replica -c max_wal_senders=5 -c wal_keep_size=128 -c hot_standby=on"
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
      - ./backup/postgres:/backup
      - ./postgres/postgresql.conf:/etc/postgresql/postgresql.conf:ro
    ports:
      - "5432:5432"
    networks:
      - cinatoken-net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U cinatoken"]
      interval: 10s
      timeout: 5s
      retries: 5

  # Redis 缓存
  redis:
    image: redis:7-alpine
    container_name: cinatoken-redis
    restart: always
    command: redis-server --appendonly yes
    volumes:
      - ./data/redis:/data
    networks:
      - cinatoken-net
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  # Nginx 反向代理
  nginx:
    image: nginx:alpine
    container_name: cinatoken-nginx
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx/conf.d/default.conf:/etc/nginx/conf.d/default.conf:ro
      - ./ssl:/etc/nginx/ssl:ro
    depends_on:
      - cinatoken
    networks:
      - cinatoken-net

networks:
  cinatoken-net:
    driver: bridge
EOF

log_success "docker-compose.yml 生成完成"

# 创建 PostgreSQL 配置文件
cat > $DEPLOY_DIR/postgres/postgresql.conf << 'EOF'
# PostgreSQL 主库配置
listen_addresses = '*'
port = 5432
max_connections = 200

# WAL 配置（用于流复制）
wal_level = replica
max_wal_senders = 5
wal_keep_size = 128
max_replication_slots = 5

# 日志配置
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d.log'
log_statement = 'ddl'
log_min_duration_statement = 1000

# 性能优化
shared_buffers = 256MB
effective_cache_size = 768MB
work_mem = 8MB
maintenance_work_mem = 64MB
EOF

log_success "PostgreSQL 配置文件生成完成"

# 创建 Nginx 配置
cat > $DEPLOY_DIR/nginx/nginx.conf << 'EOF'
user  nginx;
worker_processes  auto;

error_log  /var/log/nginx/error.log notice;
pid        /var/run/nginx.pid;

events {
    worker_connections  2048;
    multi_accept        on;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
    keepalive_timeout  65;
    types_hash_max_size 2048;

    gzip  on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_proxied any;
    gzip_types text/plain text/css text/xml text/javascript application/x-javascript application/xml application/javascript application/json;
    gzip_disable "msie6";

    include /etc/nginx/conf.d/*.conf;
}
EOF

# 创建 Nginx 站点配置（临时 HTTP 配置）
cat > $DEPLOY_DIR/nginx/conf.d/default.conf << EOF
server {
    listen 80;
    server_name ${DOMAIN:-your-domain.com};

    location / {
        proxy_pass http://cinatoken:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        proxy_connect_timeout 60s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
        
        proxy_buffering off;
    }

    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
EOF

log_success "Nginx 配置文件生成完成"

# 步骤 7：启动服务
log_info "步骤 7/10: 启动 Docker 服务..."
cd $DEPLOY_DIR
docker-compose up -d
log_success "服务启动完成"

# 步骤 8：等待 PostgreSQL 就绪
log_info "步骤 8/10: 等待 PostgreSQL 就绪..."
sleep 15

# 检查 PostgreSQL 状态
if docker exec cinatoken-db pg_isready -U cinatoken > /dev/null 2>&1; then
    log_success "PostgreSQL 已就绪"
else
    log_error "PostgreSQL 启动失败，请检查日志：docker-compose logs postgres"
    exit 1
fi

# 步骤 9：创建数据库复制用户
log_info "步骤 9/10: 创建数据库复制用户..."
docker exec cinatoken-db psql -U cinatoken -c "
CREATE ROLE replication WITH REPLICATION LOGIN PASSWORD '${REPLICATION_PASSWORD}';
" 2>/dev/null || log_warning "复制用户可能已存在"

# 验证用户
REPL_USER=$(docker exec cinatoken-db psql -U cinatoken -t -c "SELECT usename FROM pg_user WHERE userepl = true;" | tr -d ' ')
if [ -n "$REPL_USER" ]; then
    log_success "复制用户创建成功：$REPL_USER"
else
    log_error "复制用户创建失败"
fi

# 步骤 10：安装 SSL 证书
log_info "步骤 10/10: 配置 SSL 证书..."

# 检查是否已安装 certbot
if ! command -v certbot &> /dev/null; then
    apt install -y certbot python3-certbot-nginx
fi

# 提示用户配置域名
log_warning "请配置域名以获取 SSL 证书"
log_info "当前服务器公网 IP: $(curl -s ifconfig.me)"
log_info "请确保域名已解析到此 IP"

# 提供手动获取证书的说明
cat << EOF

========================================
SSL 证书配置说明
========================================

1. 将域名解析到服务器 IP: $(curl -s ifconfig.me)

2. 运行以下命令获取 SSL 证书:
   certbot certonly --standalone -d your-domain.com -d www.your-domain.com

3. 复制证书到 Nginx 目录:
   cp /etc/letsencrypt/live/your-domain.com/fullchain.pem $DEPLOY_DIR/ssl/
   cp /etc/letsencrypt/live/your-domain.com/privkey.pem $DEPLOY_DIR/ssl/

4. 更新 Nginx 配置启用 HTTPS

========================================
EOF

# 显示配置摘要
log_success "=========================================="
log_success "CinaToken 服务器 A 配置完成！"
log_success "=========================================="
log_info "部署目录：$DEPLOY_DIR"
log_info "访问地址：http://$(curl -s ifconfig.me):3000"
log_info "数据库端口：5432"
log_info ""
log_info "重要配置信息已保存到：$DEPLOY_DIR/.env"
log_warning "请妥善保管此文件！"
log_info ""
log_info "常用命令："
log_info "  查看服务状态：docker-compose ps"
log_info "  查看日志：docker-compose logs -f"
log_info "  重启服务：docker-compose restart"
log_info "  停止服务：docker-compose down"
log_info ""
log_info "下一步："
log_info "  1. 配置域名解析"
log_info "  2. 获取 SSL 证书"
log_info "  3. 配置服务器 B（从节点）"
log_info "  4. 配置 PostgreSQL 主从复制"
log_success "=========================================="

# 创建配置摘要文件
cat > $DEPLOY_DIR/SETUP_SUMMARY.md << EOF
# CinaToken 服务器 A 配置摘要

## 部署时间
$(date)

## 服务器信息
- 公网 IP: $(curl -s ifconfig.me)
- 部署目录：$DEPLOY_DIR

## 服务状态
$(docker-compose ps)

## 数据库配置
- 数据库用户：cinatoken
- 数据库名称：cinatoken
- 数据库端口：5432
- 复制用户：replication

## 访问地址
- HTTP: http://$(curl -s ifconfig.me):3000
- HTTPS: 待配置 SSL 证书后访问

## 下一步操作
1. 配置域名解析
2. 获取 SSL 证书
3. 配置服务器 B
4. 配置主从复制

## 配置文件
- 环境配置：$DEPLOY_DIR/.env
- Docker Compose: $DEPLOY_DIR/docker-compose.yml
- PostgreSQL: $DEPLOY_DIR/postgres/postgresql.conf
- Nginx: $DEPLOY_DIR/nginx/conf.d/default.conf
EOF

log_info "配置摘要已保存到：$DEPLOY_DIR/SETUP_SUMMARY.md"

exit 0
