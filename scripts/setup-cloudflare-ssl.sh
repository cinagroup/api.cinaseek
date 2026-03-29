#!/bin/bash
# CinaToken Cloudflare Origin CA 证书自动配置脚本
# 适用于 Ubuntu 22.04 LTS

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 检查是否以 root 运行
if [ "$EUID" -ne 0 ]; then
    log_error "请以 root 用户运行此脚本：sudo $0"
    exit 1
fi

log_info "=========================================="
log_info "CinaToken Cloudflare Origin CA 配置脚本"
log_info "=========================================="

# 配置变量
DEPLOY_DIR="/opt/cinatoken"
SSL_DIR="$DEPLOY_DIR/ssl"

# 提示用户输入
echo ""
log_info "请输入以下信息："
echo ""
read -p "Cloudflare API Token: " CF_TOKEN
read -p "域名 (例如：example.com): " DOMAIN
read -p "子域名 (例如：www，留空表示主域名): " SUBDOMAIN

if [ -z "$CF_TOKEN" ] || [ -z "$DOMAIN" ]; then
    log_error "Cloudflare API Token 和域名不能为空"
    exit 1
fi

# 设置环境变量
export CF_Token="$CF_TOKEN"

# 步骤 1：安装 acme.sh
log_info "步骤 1/5: 安装 acme.sh..."
if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
    curl https://get.acme.sh | sh
    source ~/.bashrc
    log_success "acme.sh 安装完成"
else
    log_warning "acme.sh 已安装，跳过"
fi

# 步骤 2：创建 SSL 目录
log_info "步骤 2/5: 创建 SSL 目录..."
mkdir -p $SSL_DIR
chmod 700 $SSL_DIR
log_success "SSL 目录创建完成：$SSL_DIR"

# 步骤 3：签发证书
log_info "步骤 3/5: 签发 Cloudflare Origin CA 证书..."

# 构建域名列表
DOMAINS="-d $DOMAIN"
if [ -n "$SUBDOMAIN" ]; then
    DOMAINS="$DOMAINS -d $SUBDOMAIN.$DOMAIN"
    log_info "将为以下域名签发证书：$DOMAIN, $SUBDOMAIN.$DOMAIN"
else
    log_info "将为以下域名签发证书：$DOMAIN"
fi

# 签发证书
~/.acme.sh/acme.sh --issue --dns dns_cf \
    $DOMAINS \
    --server zerossl \
    --days 5475  # 15 年

if [ $? -eq 0 ]; then
    log_success "证书签发成功"
else
    log_error "证书签发失败"
    exit 1
fi

# 步骤 4：安装证书
log_info "步骤 4/5: 安装证书..."

~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
    --cert-file      $SSL_DIR/cert.pem  \
    --key-file       $SSL_DIR/key.pem  \
    --fullchain-file $SSL_DIR/fullchain.pem

chmod 600 $SSL_DIR/*.pem
log_success "证书安装完成"

# 步骤 5：配置 Nginx
log_info "步骤 5/5: 配置 Nginx..."

# 备份旧配置
if [ -f "$DEPLOY_DIR/nginx/conf.d/default.conf" ]; then
    cp "$DEPLOY_DIR/nginx/conf.d/default.conf" "$DEPLOY_DIR/nginx/conf.d/default.conf.bak"
fi

# 创建 Nginx 配置
cat > $DEPLOY_DIR/nginx/conf.d/default.conf << EOF
server {
    listen 80;
    server_name $DOMAIN ${SUBDOMAIN:+"$SUBDOMAIN.$DOMAIN"};
    
    # 强制 HTTPS
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN ${SUBDOMAIN:+"$SUBDOMAIN.$DOMAIN"};

    # SSL 证书配置
    ssl_certificate $SSL_DIR/fullchain.pem;
    ssl_certificate_key $SSL_DIR/key.pem;
    
    # SSL 安全配置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384';
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_session_tickets off;

    # HSTS (可选，生产环境建议启用)
    # add_header Strict-Transport-Security "max-age=31536000" always;

    # 上传文件大小限制
    client_max_body_size 50M;

    # CinaToken 主应用
    location / {
        proxy_pass http://cinatoken:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # WebSocket 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # 超时设置
        proxy_connect_timeout 60s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
        
        # 缓冲
        proxy_buffering off;
    }

    # 健康检查端点
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
EOF

log_success "Nginx 配置完成"

# 重启 Nginx
log_info "重启 Nginx 服务..."
cd $DEPLOY_DIR
docker compose restart nginx
log_success "Nginx 重启完成"

# 显示配置摘要
log_success "=========================================="
log_success "Cloudflare Origin CA 证书配置完成！"
log_success "=========================================="
log_info ""
log_info "域名：$DOMAIN"
if [ -n "$SUBDOMAIN" ]; then
    log_info "子域名：$SUBDOMAIN.$DOMAIN"
fi
log_info "证书路径：$SSL_DIR"
log_info "证书有效期：15 年"
log_info ""
log_info "下一步操作："
log_info ""
log_info "1. 在 Cloudflare Dashboard 设置 SSL/TLS 模式："
log_info "   - 访问：https://dash.cloudflare.com"
log_info "   - 选择域名 → SSL/TLS → Overview"
log_info "   - 加密模式选择：Full (Strict)"
log_info ""
log_info "2. 配置 DNS 解析："
log_info "   - A 记录：$DOMAIN → $(curl -s ifconfig.me)"
log_info "   - A 记录：$SUBDOMAIN.$DOMAIN → $(curl -s ifconfig.me) (如果配置了子域名)"
log_info "   - 确保 CDN 代理已启用（橙色云朵）"
log_info ""
log_info "3. 验证 HTTPS："
log_info "   curl -I https://$DOMAIN"
log_info ""
log_info "4. 设置证书自动续期（acme.sh 已自动配置）："
log_info "   证书将在到期前自动续期"
log_info ""
log_success "=========================================="

# 创建配置摘要文件
cat > $SSL_DIR/SSL_CONFIG.txt << EOF
========================================
CinaToken SSL 证书配置信息
========================================

配置时间：$(date)
域名：$DOMAIN
${SUBDOMAIN:+"子域名：$SUBDOMAIN.$DOMAIN"}

证书信息：
- 类型：Cloudflare Origin CA
- 有效期：15 年
- 签发机构：ZeroSSL

证书文件：
- 证书：$SSL_DIR/fullchain.pem
- 私钥：$SSL_DIR/key.pem
- 公钥：$SSL_DIR/cert.pem

Nginx 配置：
- 配置文件：$DEPLOY_DIR/nginx/conf.d/default.conf
- HTTP 端口：80 (自动跳转到 HTTPS)
- HTTPS 端口：443

Cloudflare 设置：
- SSL/TLS 模式：Full (Strict)
- DNS 代理：启用（橙色云朵）

自动续期：
- acme.sh 已配置自动续期
- 证书将在到期前自动更新

验证命令：
- 检查证书：openssl x509 -in $SSL_DIR/fullchain.pem -text -noout
- 测试 HTTPS: curl -I https://$DOMAIN
- 查看有效期：openssl x509 -in $SSL_DIR/fullchain.pem -dates -noout

========================================
EOF

log_info "配置摘要已保存到：$SSL_DIR/SSL_CONFIG.txt"

exit 0
