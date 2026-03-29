# 腾讯云轻量应用服务器双机部署方案

本文档介绍如何在两台腾讯云轻量应用服务器（Lighthouse）上部署 CinaToken，实现高可用和负载均衡。

## 📋 方案对比

### 方案一：主从架构（推荐）

```
┌─────────────────┐
│   服务器 A      │  主节点
│   (Master)      │  - Web 应用
│   公网 IP        │  - PostgreSQL
│                 │  - Redis
└─────────────────┘
         │
         │ 内网同步
         ▼
┌─────────────────┐
│   服务器 B      │  从节点
│   (Slave)       │  - Web 应用（只读）
│   公网 IP        │  - 数据备份
└─────────────────┘

用户访问：服务器 A（主）
故障切换：手动切换到服务器 B
```

**优点：**
- ✅ 架构简单，易于维护
- ✅ 数据一致性好
- ✅ 成本低（无需额外负载均衡器）
- ✅ 适合轻量服务器场景

**缺点：**
- ⚠️ 需要手动故障切换
- ⚠️ 从节点资源利用率较低

---

### 方案二：双活 + Keepalived

```
                    ┌──────────────┐
                    │  虚拟 IP (VIP)│
                    │  浮动 IP      │
                    └──────┬───────┘
                           │
              ┌────────────┴────────────┐
              ▼                         ▼
    ┌─────────────────┐       ┌─────────────────┐
    │   服务器 A      │       │   服务器 B      │
    │   (Master)      │◄─────►│   (Backup)      │
    │   Keepalived    │ VRRP  │   Keepalived    │
    │   + Web + DB    │       │   + Web + DB    │
    └─────────────────┘       └─────────────────┘
```

**优点：**
- ✅ 自动故障切换（秒级）
- ✅ 双机都可提供服务
- ✅ 高可用性好

**缺点：**
- ⚠️ 配置复杂
- ⚠️ 需要配置数据库主从复制
- ⚠️ 轻量服务器不支持内网通信，需走公网

---

### 方案三：Nginx 反向代理 + 双活

```
                    ┌──────────────┐
                    │   服务器 A    │
                    │   Nginx LB    │
                    │   + Web + DB  │
                    └──────┬───────┘
                           │
              ┌────────────┴────────────┐
              ▼                         ▼
    ┌─────────────────┐       ┌─────────────────┐
    │   服务器 A      │       │   服务器 B      │
    │   Web 实例 1     │       │   Web 实例 2     │
    └─────────────────┘       └─────────────────┘
```

**优点：**
- ✅ 负载均衡
- ✅ 配置相对简单

**缺点：**
- ⚠️ 单点故障（Nginx 所在服务器）
- ⚠️ 需要数据库同步

---

## 🎯 推荐方案：主从架构（方案一）

基于腾讯云轻量服务器的特点（无内网、带宽有限），推荐主从架构。

### 架构设计

```
┌─────────────────────────────────────────────────────┐
│                    用户访问                          │
│              https://your-domain.com                │
└────────────────────┬────────────────────────────────┘
                     │
                     ▼
          ┌──────────────────┐
          │   腾讯云 CDN      │  (可选，加速 + 防护)
          └────────┬─────────┘
                   │
                   ▼
     ┌─────────────────────────┐
     │    服务器 A (主节点)     │
     │    公网 IP: 1.2.3.4      │
     │    - Nginx 反向代理      │
     │    - CinaToken Web       │
     │    - PostgreSQL (主)     │
     │    - Redis               │
     │    - Docker              │
     └────────────┬────────────┘
                  │
                  │ PostgreSQL 流复制
                  ▼
     ┌─────────────────────────┐
     │    服务器 B (从节点)     │
     │    公网 IP: 5.6.7.8      │
     │    - CinaToken Web       │
     │    - PostgreSQL (从)     │
     │    - 数据备份            │
     │    - Docker              │
     └─────────────────────────┘
```

---

## 📦 服务器配置要求

### 最低配置

| 配置项 | 服务器 A（主） | 服务器 B（从） |
|--------|---------------|---------------|
| CPU | 2 核 | 2 核 |
| 内存 | 4GB | 2GB |
| 磁盘 | 50GB SSD | 30GB SSD |
| 带宽 | 5Mbps+ | 3Mbps+ |
| 系统 | Ubuntu 22.04 LTS | Ubuntu 22.04 LTS |

### 推荐配置

| 配置项 | 服务器 A（主） | 服务器 B（从） |
|--------|---------------|---------------|
| CPU | 4 核 | 2 核 |
| 内存 | 8GB | 4GB |
| 磁盘 | 80GB SSD | 50GB SSD |
| 带宽 | 10Mbps+ | 5Mbps+ |

---

## 🚀 部署步骤

### 步骤 1：服务器 A（主节点）部署

#### 1.1 安装 Docker

```bash
# 更新系统
apt update && apt upgrade -y

# 安装 Docker
curl -fsSL https://get.docker.com | sh

# 安装 Docker Compose
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# 验证安装
docker --version
docker-compose --version
```

#### 1.2 创建部署目录

```bash
mkdir -p /opt/cinatoken/{data,logs,backup}
cd /opt/cinatoken
```

#### 1.3 创建 docker-compose.yml

```yaml
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
      - SQL_DSN=postgresql://cinatoken:YOUR_PASSWORD@postgres:5432/cinatoken
      - REDIS_CONN_STRING=redis://redis:6379
      - TZ=Asia/Shanghai
      - SESSION_SECRET=YOUR_RANDOM_SECRET_STRING
      - ERROR_LOG_ENABLED=true
      - BATCH_UPDATE_ENABLED=true
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

  # PostgreSQL 数据库
  postgres:
    image: postgres:15-alpine
    container_name: cinatoken-db
    restart: always
    environment:
      POSTGRES_USER: cinatoken
      POSTGRES_PASSWORD: YOUR_PASSWORD
      POSTGRES_DB: cinatoken
      # 启用 WAL 日志用于流复制
      POSTGRES_INITDB_ARGS: "-c wal_level=replica -c max_wal_senders=3 -c wal_keep_size=64"
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
      - ./backup/postgres:/backup
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
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - ./ssl:/etc/nginx/ssl:ro
    depends_on:
      - cinatoken
    networks:
      - cinatoken-net

networks:
  cinatoken-net:
    driver: bridge
```

#### 1.4 创建 Nginx 配置

```bash
mkdir -p /opt/cinatoken/nginx/conf.d
```

**nginx.conf:**
```nginx
user  nginx;
worker_processes  auto;

error_log  /var/log/nginx/error.log notice;
pid        /var/run/nginx.pid;

events {
    worker_connections  1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile        on;
    keepalive_timeout  65;
    gzip  on;
    gzip_types text/plain text/css application/json application/javascript;

    include /etc/nginx/conf.d/*.conf;
}
```

**conf.d/default.conf:**
```nginx
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
    ssl_ciphers HIGH:!aNULL:!MD5;

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
    }

    # 健康检查端点
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
```

#### 1.5 启动服务

```bash
# 获取 SSL 证书（使用 Let's Encrypt）
apt install certbot -y
certbot certonly --standalone -d your-domain.com

# 复制证书到 Nginx 目录
mkdir -p /opt/cinatoken/ssl
cp /etc/letsencrypt/live/your-domain.com/fullchain.pem /opt/cinatoken/ssl/
cp /etc/letsencrypt/live/your-domain.com/privkey.pem /opt/cinatoken/ssl/

# 启动 Docker 服务
cd /opt/cinatoken
docker-compose up -d

# 查看日志
docker-compose logs -f
```

---

### 步骤 2：服务器 B（从节点）部署

#### 2.1 安装 Docker（同服务器 A）

```bash
apt update && apt upgrade -y
curl -fsSL https://get.docker.com | sh
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
```

#### 2.2 创建部署目录

```bash
mkdir -p /opt/cinatoken/{data,logs,backup}
cd /opt/cinatoken
```

#### 2.3 创建 docker-compose.yml（从节点）

```yaml
version: '3.8'

services:
  # CinaToken Web 应用（只读模式）
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
      # 连接到主节点的数据库
      - SQL_DSN=postgresql://cinatoken:YOUR_PASSWORD@MASTER_SERVER_IP:5432/cinatoken
      - REDIS_CONN_STRING=redis://redis:6379
      - TZ=Asia/Shanghai
      - SESSION_SECRET=YOUR_RANDOM_SECRET_STRING
      - ERROR_LOG_ENABLED=true
      - BATCH_UPDATE_ENABLED=true
      # 只读模式（可选）
      - READ_ONLY_MODE=true
    depends_on:
      - redis
    networks:
      - cinatoken-net

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
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - ./ssl:/etc/nginx/ssl:ro
    depends_on:
      - cinatoken
    networks:
      - cinatoken-net

networks:
  cinatoken-net:
    driver: bridge
```

#### 2.4 配置 PostgreSQL 从库（可选，用于数据备份）

如果需要配置数据库主从复制：

**在主节点（服务器 A）创建复制用户：**

```bash
docker exec -it cinatoken-db psql -U cinatoken -c "CREATE ROLE replication WITH REPLICATION LOGIN PASSWORD 'YOUR_REPLICATION_PASSWORD';"
```

**在从节点创建恢复配置：**

```bash
# 创建 standby.signal 文件
touch /opt/cinatoken/data/postgres/standby.signal

# 配置主库连接
cat >> /opt/cinatoken/data/postgres/postgresql.auto.conf << EOF
primary_conninfo = 'host=MASTER_SERVER_IP port=5432 user=replication password=YOUR_REPLICATION_PASSWORD'
EOF
```

#### 2.5 启动从节点服务

```bash
cd /opt/cinatoken
docker-compose up -d
```

---

### 步骤 3：配置防火墙和安全组

#### 腾讯云控制台配置

**服务器 A（主节点）安全组：**

| 端口 | 协议 | 来源 | 说明 |
|------|------|------|------|
| 80 | TCP | 0.0.0.0/0 | HTTP |
| 443 | TCP | 0.0.0.0/0 | HTTPS |
| 5432 | TCP | 服务器 B 内网 IP | PostgreSQL 主从复制 |
| 22 | TCP | 你的 IP | SSH |

**服务器 B（从节点）安全组：**

| 端口 | 协议 | 来源 | 说明 |
|------|------|------|------|
| 80 | TCP | 0.0.0.0/0 | HTTP（备用） |
| 443 | TCP | 0.0.0.0/0 | HTTPS（备用） |
| 22 | TCP | 你的 IP | SSH |

---

### 步骤 4：配置域名和 DNS

#### DNS 解析配置

```
类型    主机记录    记录值            TTL
A       @          服务器 A 公网 IP     600
A       www        服务器 A 公网 IP     600
A       backup     服务器 B 公网 IP     600
```

#### 故障切换 DNS（可选）

使用 DNS 故障切换服务：
- 腾讯云 DNSPod
- Cloudflare
- AWS Route53

配置健康检查和自动切换。

---

## 🔄 故障切换流程

### 手动切换步骤

当服务器 A 故障时，切换到服务器 B：

#### 1. 验证服务器 B 状态

```bash
# 登录服务器 B
ssh root@服务器 B_IP

# 检查服务状态
docker-compose ps

# 检查数据库连接
docker exec -it cinatoken-db psql -U cinatoken -c "SELECT 1;"
```

#### 2. 提升从库为主库（如果配置了主从复制）

```bash
docker exec -it cinatoken-db psql -U cinatoken -c "SELECT pg_promote();"
```

#### 3. 更新 DNS 解析

将域名解析指向服务器 B：

```
A @ 服务器 B 公网 IP
A www 服务器 B 公网 IP
```

#### 4. 更新应用配置

如果服务器 B 原本连接服务器 A 的数据库，需要改为本地数据库：

```bash
# 编辑 docker-compose.yml
# 修改 SQL_DSN 为本地数据库

docker-compose down
docker-compose up -d
```

---

## 📊 监控和告警

### 监控脚本

创建 `/opt/cinatoken/monitor.sh`：

```bash
#!/bin/bash

# CinaToken 健康检查脚本

LOG_FILE="/opt/cinatoken/monitor.log"
WEBHOOK_URL="YOUR_WEBHOOK_URL"  # 企业微信/钉钉 webhook

check_service() {
    local service_name=$1
    local status=$(docker inspect -f '{{.State.Status}}' $service_name 2>/dev/null)
    
    if [ "$status" != "running" ]; then
        echo "$(date) - $service_name is down!" >> $LOG_FILE
        send_alert "$service_name is down!"
        return 1
    fi
    return 0
}

send_alert() {
    local message=$1
    curl -X POST "$WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "{\"msgtype\":\"text\",\"text\":{\"content\":\"CinaToken Alert: $message\"}}"
}

# 检查所有服务
check_service "cinatoken"
check_service "postgres"
check_service "redis"
check_service "nginx"

# 检查 HTTP 健康端点
http_status=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/api/status)
if [ "$http_status" != "200" ]; then
    send_alert "HTTP health check failed with status $http_status"
fi
```

#### 设置定时任务

```bash
chmod +x /opt/cinatoken/monitor.sh
crontab -e

# 每 5 分钟检查一次
*/5 * * * * /opt/cinatoken/monitor.sh
```

---

## 💾 备份策略

### 数据库备份脚本

创建 `/opt/cinatoken/backup-db.sh`：

```bash
#!/bin/bash

BACKUP_DIR="/opt/cinatoken/backup/postgres"
DATE=$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS=7

# 创建备份
docker exec cinatoken-db pg_dump -U cinatoken cinatoken > "$BACKUP_DIR/backup_$DATE.sql"

# 压缩备份
gzip "$BACKUP_DIR/backup_$DATE.sql"

# 删除旧备份
find $BACKUP_DIR -name "backup_*.sql.gz" -mtime +$RETENTION_DAYS -delete

echo "Backup completed: backup_$DATE.sql.gz"
```

#### 设置定时任务

```bash
chmod +x /opt/cinatoken/backup-db.sh
crontab -e

# 每天凌晨 2 点备份
0 2 * * * /opt/cinatoken/backup-db.sh
```

---

## 💰 成本估算

### 腾讯云轻量应用服务器价格（广州地区）

| 配置 | 月付 | 年付 |
|------|------|------|
| 2 核 2GB 30GB SSD 3Mbps | ¥24 | ¥240 |
| 2 核 4GB 50GB SSD 5Mbps | ¥48 | ¥480 |
| 4 核 8GB 80GB SSD 10Mbps | ¥96 | ¥960 |

### 推荐配置成本

```
服务器 A（4 核 8GB 80GB 10Mbps）：¥96/月
服务器 B（2 核 4GB 50GB 5Mbps）：  ¥48/月
域名：                            ¥60/年
SSL 证书（Let's Encrypt）：         免费
-------------------------------------------
总计：约 ¥144/月（¥1728/年）
```

---

## ⚠️ 注意事项

### 1. 网络延迟

- 轻量服务器之间无内网，通信走公网
- 数据库主从复制会受网络延迟影响
- 建议将 Redis 部署在每个节点本地

### 2. 数据安全

- 定期备份数据库
- 配置 SSL 加密数据库连接
- 使用强密码和防火墙规则

### 3. 带宽限制

- 轻量服务器带宽有限
- 大文件上传可能受限
- 考虑使用 CDN 加速静态资源

### 4. 故障切换

- 手动切换需要人工介入
- 建议编写切换检查清单
- 定期演练故障切换流程

---

## 📝 运维检查清单

### 每日检查

- [ ] 检查服务状态：`docker-compose ps`
- [ ] 检查磁盘空间：`df -h`
- [ ] 检查日志：`docker-compose logs --tail 100`
- [ ] 检查备份是否完成

### 每周检查

- [ ] 检查系统更新：`apt update`
- [ ] 检查 Docker 镜像更新
- [ ] 检查 SSL 证书有效期
- [ ] 审查访问日志

### 每月检查

- [ ] 执行故障切换演练
- [ ] 检查备份恢复测试
- [ ] 审查资源使用情况
- [ ] 更新监控告警阈值

---

## 🔗 相关资源

- [腾讯云轻量应用服务器文档](https://cloud.tencent.com/document/product/1207)
- [Docker Compose 官方文档](https://docs.docker.com/compose/)
- [PostgreSQL 流复制配置](https://www.postgresql.org/docs/current/warm-standby.html)
- [Nginx 配置最佳实践](https://www.nginx.com/resources/wiki/start/topics/tutorials/config_pitfalls/)
- [CinaToken 官方文档](https://docs.cinatoken.pro)

---

## 🆘 获取帮助

遇到问题？

- 📘 查看 [CinaToken 文档](https://docs.cinatoken.pro)
- 🐛 提交 [GitHub Issue](https://github.com/cinagroup/cinatoken/issues)
- 💬 加入社区讨论
