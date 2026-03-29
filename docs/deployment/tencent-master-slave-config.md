# 腾讯云轻量服务器主从结构配置指南

本文档提供腾讯云轻量应用服务器主从架构的**完整配置步骤**，包含所有配置文件和命令。

## 📋 架构设计

```
┌─────────────────────────────────────────────────────┐
│                    用户访问                          │
│              https://your-domain.com                │
└────────────────────┬────────────────────────────────┘
                     │
                     ▼
     ┌─────────────────────────┐
     │    服务器 A (主节点)     │
     │    公网 IP: 1.2.3.4      │
     │    - Nginx 反向代理      │
     │    - CinaToken Web       │
     │    - PostgreSQL (主库)   │
     │    - Redis               │
     └────────────┬────────────┘
                  │
                  │ PostgreSQL 流复制
                  │ (端口 5432)
                  ▼
     ┌─────────────────────────┐
     │    服务器 B (从节点)     │
     │    公网 IP: 5.6.7.8      │
     │    - CinaToken Web       │
     │    - PostgreSQL (从库)   │
     │    - 数据备份            │
     └─────────────────────────┘
```

---

## 🖥️ 服务器准备

### 服务器配置

| 配置 | 服务器 A（主） | 服务器 B（从） |
|------|---------------|---------------|
| 系统 | Ubuntu 22.04 LTS | Ubuntu 22.04 LTS |
| CPU | 4 核 | 2 核 |
| 内存 | 8GB | 4GB |
| 磁盘 | 80GB SSD | 50GB SSD |
| 带宽 | 10Mbps | 5Mbps |
| 公网 IP | 1.2.3.4 | 5.6.7.8 |

### 开放安全组端口

**服务器 A（主节点）：**

| 端口 | 协议 | 来源 | 说明 |
|------|------|------|------|
| 80 | TCP | 0.0.0.0/0 | HTTP |
| 443 | TCP | 0.0.0.0/0 | HTTPS |
| 5432 | TCP | 5.6.7.8 | PostgreSQL 主从复制（仅允许服务器 B） |
| 22 | TCP | 你的 IP | SSH |

**服务器 B（从节点）：**

| 端口 | 协议 | 来源 | 说明 |
|------|------|------|------|
| 80 | TCP | 0.0.0.0/0 | HTTP（备用） |
| 443 | TCP | 0.0.0.0/0 | HTTPS（备用） |
| 22 | TCP | 你的 IP | SSH |

---

## 📦 步骤 1：服务器 A（主节点）完整配置

### 1.1 安装基础软件

```bash
# 更新系统
apt update && apt upgrade -y

# 安装必要工具
apt install -y curl wget vim git htop net-tools

# 安装 Docker
curl -fsSL https://get.docker.com | sh

# 安装 Docker Compose
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# 验证安装
docker --version
docker-compose --version
```

### 1.2 创建部署目录

```bash
mkdir -p /opt/cinatoken/{data,logs,backup,ssl,nginx/conf.d}
cd /opt/cinatoken
```

### 1.3 创建 docker-compose.yml

```bash
cat > /opt/cinatoken/docker-compose.yml << 'EOF'
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
      - SQL_DSN=postgresql://cinatoken:YOUR_DB_PASSWORD@postgres:5432/cinatoken
      - REDIS_CONN_STRING=redis://redis:6379
      - TZ=Asia/Shanghai
      - SESSION_SECRET=YOUR_RANDOM_SECRET_STRING_CHANGE_THIS
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
      POSTGRES_PASSWORD: YOUR_DB_PASSWORD
      POSTGRES_DB: cinatoken
      # 启用 WAL 日志用于流复制
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
```

### 1.4 创建 PostgreSQL 配置文件

```bash
mkdir -p /opt/cinatoken/postgres

cat > /opt/cinatoken/postgres/postgresql.conf << 'EOF'
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
```

### 1.5 创建 Nginx 配置

**nginx.conf:**

```bash
cat > /opt/cinatoken/nginx/nginx.conf << 'EOF'
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

    # Gzip 压缩
    gzip  on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_proxied any;
    gzip_types text/plain text/css text/xml text/javascript application/x-javascript application/xml application/javascript application/json;
    gzip_disable "msie6";

    include /etc/nginx/conf.d/*.conf;
}
EOF
```

**conf.d/default.conf:**

```bash
cat > /opt/cinatoken/nginx/conf.d/default.conf << 'EOF'
server {
    listen 80;
    server_name your-domain.com;

    # 强制 HTTPS
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name your-domain.com;

    # SSL 证书配置
    ssl_certificate /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256';
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # 上传文件大小限制
    client_max_body_size 50M;

    # CinaToken 主应用
    location / {
        proxy_pass http://cinatoken:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # WebSocket 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
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
```

### 1.6 获取 SSL 证书

```bash
# 安装 Certbot
apt install certbot python3-certbot-nginx -y

# 获取证书（先临时启动 Nginx）
docker-compose up -d nginx

# 获取 SSL 证书
certbot certonly --standalone -d your-domain.com -d www.your-domain.com

# 复制证书到 Nginx 目录
cp /etc/letsencrypt/live/your-domain.com/fullchain.pem /opt/cinatoken/ssl/
cp /etc/letsencrypt/live/your-domain.com/privkey.pem /opt/cinatoken/ssl/

# 设置权限
chmod 600 /opt/cinatoken/ssl/*.pem
```

### 1.7 创建数据库复制用户

```bash
# 启动 PostgreSQL
docker-compose up -d postgres

# 等待 PostgreSQL 启动
sleep 10

# 创建复制用户
docker exec -it cinatoken-db psql -U cinatoken -c "
CREATE ROLE replication WITH REPLICATION LOGIN PASSWORD 'YOUR_REPLICATION_PASSWORD';
"

# 验证用户
docker exec -it cinatoken-db psql -U cinatoken -c "\du"
```

### 1.8 启动所有服务

```bash
# 启动所有服务
cd /opt/cinatoken
docker-compose up -d

# 查看服务状态
docker-compose ps

# 查看日志
docker-compose logs -f
```

---

## 📦 步骤 2：服务器 B（从节点）完整配置

### 2.1 安装基础软件（同服务器 A）

```bash
apt update && apt upgrade -y
apt install -y curl wget vim git htop net-tools
curl -fsSL https://get.docker.com | sh
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
```

### 2.2 创建部署目录

```bash
mkdir -p /opt/cinatoken/{data,logs,backup,ssl,nginx/conf.d}
cd /opt/cinatoken
```

### 2.3 创建 docker-compose.yml（从节点）

```bash
cat > /opt/cinatoken/docker-compose.yml << 'EOF'
version: '3.8'

services:
  # CinaToken Web 应用（连接主库或本地从库）
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
      # 正常运行时连接主库
      - SQL_DSN=postgresql://cinatoken:YOUR_DB_PASSWORD@1.2.3.4:5432/cinatoken
      - REDIS_CONN_STRING=redis://redis:6379
      - TZ=Asia/Shanghai
      - SESSION_SECRET=YOUR_RANDOM_SECRET_STRING_CHANGE_THIS
      - ERROR_LOG_ENABLED=true
      - BATCH_UPDATE_ENABLED=true
      # 故障切换后改为本地从库
      # - SQL_DSN=postgresql://cinatoken:YOUR_DB_PASSWORD@localhost:5432/cinatoken
    depends_on:
      - redis
    networks:
      - cinatoken-net
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "-", "http://localhost:3000/api/status"]
      interval: 30s
      timeout: 10s
      retries: 3

  # Redis 缓存（本地）
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

  # Nginx 反向代理（备用）
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
```

### 2.4 创建 Nginx 配置（同服务器 A）

```bash
mkdir -p /opt/cinatoken/nginx/conf.d

cat > /opt/cinatoken/nginx/nginx.conf << 'EOF'
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

cat > /opt/cinatoken/nginx/conf.d/default.conf << 'EOF'
server {
    listen 80;
    server_name backup.your-domain.com;
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name backup.your-domain.com;

    ssl_certificate /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256';
    ssl_prefer_server_ciphers on;

    client_max_body_size 50M;

    location / {
        proxy_pass http://cinatoken:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        
        proxy_connect_timeout 60s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
        
        proxy_buffering off;
    }
}
EOF
```

### 2.5 获取 SSL 证书（从节点）

```bash
apt install certbot python3-certbot-nginx -y

docker-compose up -d nginx
certbot certonly --standalone -d backup.your-domain.com

cp /etc/letsencrypt/live/backup.your-domain.com/fullchain.pem /opt/cinatoken/ssl/
cp /etc/letsencrypt/live/backup.your-domain.com/privkey.pem /opt/cinatoken/ssl/
chmod 600 /opt/cinatoken/ssl/*.pem
```

### 2.6 启动从节点服务

```bash
cd /opt/cinatoken
docker-compose up -d

# 查看服务状态
docker-compose ps
```

---

## 📦 步骤 3（可选）：配置 PostgreSQL 热备从库

如果需要服务器 B 也有数据库用于快速故障切换：

### 3.1 在服务器 B 创建 PostgreSQL 从库配置

```bash
mkdir -p /opt/cinatoken/{data/postgres,backup/postgres}

cat > /opt/cinatoken/docker-compose-db.yml << 'EOF'
version: '3.8'

services:
  # PostgreSQL 从库
  postgres:
    image: postgres:15-alpine
    container_name: cinatoken-db-slave
    restart: always
    environment:
      POSTGRES_USER: cinatoken
      POSTGRES_PASSWORD: YOUR_DB_PASSWORD
      POSTGRES_DB: cinatoken
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
      - ./backup/postgres:/backup
    ports:
      - "5432:5432"
    networks:
      - cinatoken-net
    command: >
      postgres
      -c hot_standby=on
      -c hot_standby_feedback=on
      -c primary_conninfo='host=1.2.3.4 port=5432 user=replication password=YOUR_REPLICATION_PASSWORD'
      -c trigger_file='/tmp/postgresql.trigger'
    networks:
      - cinatoken-net

networks:
  cinatoken-net:
    driver: bridge
EOF
```

### 3.2 初始化从库数据

```bash
# 从主库基础备份
docker run --rm \
  -v /opt/cinatoken/data/postgres:/var/lib/postgresql/data \
  postgres:15-alpine \
  bash -c "
    pg_basebackup -h 1.2.3.4 -D /var/lib/postgresql/data -U replication -P -R -X stream
  "

# 创建 standby.signal 文件
touch /opt/cinatoken/data/postgres/standby.signal

# 启动从库
docker-compose -f docker-compose-db.yml up -d

# 查看复制状态（在服务器 A 执行）
docker exec -it cinatoken-db psql -U cinatoken -c "SELECT * FROM pg_stat_replication;"
```

---

## 🔄 步骤 4：配置故障切换

### 4.1 创建故障切换脚本

**在服务器 B 创建 `/opt/cinatoken/failover.sh`：**

```bash
cat > /opt/cinatoken/failover.sh << 'EOF'
#!/bin/bash

# CinaToken 故障切换脚本
# 部署在服务器 B（从节点）

MASTER_IP="1.2.3.4"
LOCAL_DB="localhost"
LOG_FILE="/opt/cinatoken/failover.log"
WEBHOOK_URL="YOUR_WEBHOOK_URL"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> $LOG_FILE
}

send_alert() {
    curl -X POST "$WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "{\"msgtype\":\"text\",\"text\":{\"content\":\"CinaToken 故障切换：$1\"}}"
}

check_master() {
    wget -q -O - "http://$MASTER_IP:3000/api/status" --timeout=5 > /dev/null 2>&1
    return $?
}

promote_slave() {
    log "提升从库为主库..."
    
    # 如果是 Docker 部署
    docker exec cinatoken-db-slave psql -U cinatoken -c "SELECT pg_promote();"
    
    # 修改 CinaToken 配置为本地数据库
    cd /opt/cinatoken
    sed -i 's|SQL_DSN=postgresql://.*@1.2.3.4:5432|SQL_DSN=postgresql://cinatoken:YOUR_DB_PASSWORD@localhost:5432|g' docker-compose.yml
    
    # 重启 CinaToken
    docker-compose restart cinatoken
    
    log "从库已提升为主库"
    send_alert "服务器 B 已接管服务，数据库已提升为主库"
}

# 主逻辑
log "开始检查主节点状态..."

if ! check_master; then
    log "主节点不可达，开始故障切换..."
    send_alert "检测到主节点故障，开始故障切换"
    promote_slave
else
    log "主节点正常"
fi
EOF

chmod +x /opt/cinatoken/failover.sh
```

### 4.2 设置定时检查

```bash
# 编辑 crontab
crontab -e

# 添加每 2 分钟检查一次
*/2 * * * * /opt/cinatoken/failover.sh
```

---

## 📊 步骤 5：验证部署

### 5.1 验证服务器 A（主节点）

```bash
# 检查所有服务
docker-compose ps

# 检查数据库
docker exec -it cinatoken-db psql -U cinatoken -c "SELECT version();"

# 检查复制用户
docker exec -it cinatoken-db psql -U cinatoken -c "SELECT usename, userepl FROM pg_user WHERE userepl = true;"

# 检查 CinaToken
curl http://localhost:3000/api/status

# 检查 Nginx
curl -k https://localhost/api/status
```

### 5.2 验证服务器 B（从节点）

```bash
# 检查服务
docker-compose ps

# 检查 CinaToken
curl http://localhost:3000/api/status

# 测试连接主库
docker exec -it cinatoken psql -c "SELECT version();"
```

### 5.3 验证主从复制（如果配置了从库）

**在服务器 A 执行：**

```bash
# 查看复制状态
docker exec -it cinatoken-db psql -U cinatoken -c "
SELECT 
    client_addr,
    state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn
FROM pg_stat_replication;
"
```

---

## 💾 步骤 6：配置备份

### 6.1 创建数据库备份脚本

**在服务器 A 创建 `/opt/cinatoken/backup-db.sh`：**

```bash
cat > /opt/cinatoken/backup-db.sh << 'EOF'
#!/bin/bash

BACKUP_DIR="/opt/cinatoken/backup/postgres"
DATE=$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS=7
DB_USER="cinatoken"
DB_NAME="cinatoken"

# 创建备份目录
mkdir -p $BACKUP_DIR

# 备份数据库
docker exec cinatoken-db pg_dump -U $DB_USER $DB_NAME > "$BACKUP_DIR/backup_$DATE.sql"

# 压缩备份
gzip "$BACKUP_DIR/backup_$DATE.sql"

# 删除旧备份
find $BACKUP_DIR -name "backup_*.sql.gz" -mtime +$RETENTION_DAYS -delete

# 记录日志
echo "$(date '+%Y-%m-%d %H:%M:%S') - 备份完成：backup_$DATE.sql.gz" >> /opt/cinatoken/backup.log
EOF

chmod +x /opt/cinatoken/backup-db.sh
```

### 6.2 设置定时备份

```bash
crontab -e

# 每天凌晨 2 点备份
0 2 * * * /opt/cinatoken/backup-db.sh
```

---

## 📝 运维检查清单

### 每日检查

```bash
# 服务器 A
docker-compose ps
df -h
docker-compose logs --tail 100

# 检查复制状态
docker exec -it cinatoken-db psql -U cinatoken -c "SELECT * FROM pg_stat_replication;"
```

### 每周检查

```bash
# 检查磁盘空间
df -h

# 检查备份
ls -lh /opt/cinatoken/backup/postgres/

# 检查 SSL 证书有效期
echo | openssl s_client -connect your-domain.com:443 2>/dev/null | openssl x509 -noout -dates
```

### 故障切换演练

```bash
# 1. 在服务器 B 手动执行
/opt/cinatoken/failover.sh

# 2. 验证服务正常
curl https://backup.your-domain.com/api/status

# 3. 验证数据库可写
docker exec -it cinatoken-db-slave psql -U cinatoken -c "CREATE TABLE test_failover (id int);"

# 4. 恢复后清理
docker exec -it cinatoken-db-slave psql -U cinatoken -c "DROP TABLE test_failover;"
```

---

## ⚠️ 常见问题

### Q1: 主从复制延迟高

**解决：**
```bash
# 检查网络延迟
ping 1.2.3.4

# 增加 WAL 保持大小
# 修改 postgresql.conf
wal_keep_size = 256

# 重启 PostgreSQL
docker-compose restart postgres
```

### Q2: 从库连接失败

**解决：**
```bash
# 检查服务器 A 安全组
# 确保 5432 端口对服务器 B IP 开放

# 检查复制用户
docker exec -it cinatoken-db psql -U cinatoken -c "\du replication"

# 检查 PostgreSQL 日志
docker-compose logs postgres
```

### Q3: 故障切换后数据不一致

**解决：**
```bash
# 在服务器 B 检查数据库状态
docker exec -it cinatoken-db-slave psql -U cinatoken -c "SELECT pg_is_in_recovery();"

# 如果返回 false，说明已提升为主库
# 可以正常写入
```

---

## 📞 获取帮助

- 📘 [CinaToken 官方文档](https://docs.cinatoken.pro)
- 🐛 [GitHub Issues](https://github.com/cinagroup/cinatoken/issues)
- 💬 社区讨论
