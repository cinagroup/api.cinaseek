# Docker + Keepalived 双机高可用部署方案

⚠️ **重要提示：** 腾讯云轻量应用服务器无内网，原生 Keepalived VRRP 协议无法直接使用。
本方案采用 **HTTP 健康检查 + 弹性公网 IP 切换** 的替代方案。

## 📋 方案架构

```
                    ┌─────────────────┐
                    │   监控服务       │
                    │  (独立服务器)    │
                    │  或云函数        │
                    └────────┬────────┘
                             │ HTTP 健康检查
              ┌──────────────┴──────────────┐
              ▼                             ▼
    ┌─────────────────┐           ┌─────────────────┐
    │   服务器 A      │           │   服务器 B      │
    │   (Master)      │           │   (Backup)      │
    │   公网 IP: 1.2.3.4          │   公网 IP: 5.6.7.8
    │   Keepalived    │           │   Keepalived    │
    │   + Web + DB    │           │   + Web + DB    │
    └─────────────────┘           └─────────────────┘
            │                             │
            └──────────┬──────────────────┘
                       │
                       ▼
              ┌─────────────────┐
              │   域名解析       │
              │   your-domain.com│
              │   → 1.2.3.4     │
              └─────────────────┘
```

## ⚠️ 技术限制说明

### 腾讯云轻量服务器限制

1. **无内网通信** - 服务器之间通过公网通信
2. **VRRP 协议不支持** - 安全组无法放行协议号 112
3. **弹性公网 IP 限制** - 不支持 Keepalived VIP 浮动

### 解决方案

采用 **应用层高可用** 替代 **网络层高可用**：
- 使用 HTTP/HTTPS 健康检查
- 使用 DNS API 自动切换
- 使用数据库主从复制

---

## 🚀 部署方案

### 方案 A：使用云监控 + DNS 切换（推荐）

#### 1. 架构设计

```
监控服务（云函数/第三方）
    ↓ HTTP 检查
服务器 A (主) ←──→ 服务器 B (备)
    ↓                  ↓
DNS 自动切换域名解析
```

#### 2. 创建监控脚本

**monitor-and-switch.py** (部署到云函数或独立服务器)：

```python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CinaToken 双机健康检查与 DNS 自动切换脚本
部署位置：腾讯云云函数 / 独立监控服务器
"""

import requests
import time
import json
import logging
from tencentcloud.common import credential
from tencentcloud.dnspod.v20210323 import dnspod_client, models

# 配置
CONFIG = {
    'servers': {
        'master': {
            'name': '服务器 A',
            'ip': '1.2.3.4',
            'domain': 'server-a.your-domain.com',
            'check_url': 'http://1.2.3.4:3000/api/status'
        },
        'backup': {
            'name': '服务器 B',
            'ip': '5.6.7.8',
            'domain': 'server-b.your-domain.com',
            'check_url': 'http://5.6.7.8:3000/api/status'
        }
    },
    'dns': {
        'domain': 'your-domain.com',
        'subdomain': 'www',
        'record_id': '123456789',  # DNSPod 记录 ID
        'ttl': 60
    },
    'threshold': 3,  # 连续失败次数阈值
    'interval': 10,  # 检查间隔（秒）
    'dns_secret_id': 'YOUR_SECRET_ID',
    'dns_secret_key': 'YOUR_SECRET_KEY'
}

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

class HealthChecker:
    def __init__(self):
        self.failure_count = {'master': 0, 'backup': 0}
        self.current_active = 'master'
        self.cred = credential.Credential(
            CONFIG['dns_secret_id'], 
            CONFIG['dns_secret_key']
        )
        self.dns_client = dnspod_client.DnspodClient(
            self.cred, 
            "ap-guangzhou"
        )
    
    def check_server(self, server_key):
        """检查服务器健康状态"""
        server = CONFIG['servers'][server_key]
        try:
            response = requests.get(server['check_url'], timeout=5)
            if response.status_code == 200:
                data = response.json()
                if data.get('success') == True:
                    return True
        except Exception as e:
            logger.warning(f"{server['name']} 检查失败：{e}")
        return False
    
    def switch_dns(self, target_server):
        """切换 DNS 解析"""
        server = CONFIG['servers'][target_server]
        try:
            req = models.ModifyRecordRequest()
            params = {
                "Domain": CONFIG['dns']['domain'],
                "SubDomain": CONFIG['dns']['subdomain'],
                "RecordType": "A",
                "RecordLine": "默认",
                "Value": server['ip'],
                "RecordId": int(CONFIG['dns']['record_id'])
            }
            req.from_json_string(json.dumps(params))
            
            resp = self.dns_client.ModifyRecord(req)
            logger.info(f"DNS 切换到 {server['name']} ({server['ip']}) 成功")
            return True
        except Exception as e:
            logger.error(f"DNS 切换失败：{e}")
            return False
    
    def send_notification(self, message):
        """发送告警通知（企业微信/钉钉）"""
        webhook = "YOUR_WEBHOOK_URL"
        try:
            requests.post(webhook, json={
                "msgtype": "text",
                "text": {
                    "content": f"CinaToken 故障切换告警：{message}"
                }
            })
        except Exception as e:
            logger.error(f"发送通知失败：{e}")
    
    def run(self):
        """主循环"""
        logger.info("健康检查服务启动")
        
        while True:
            # 检查当前活跃服务器
            if self.check_server(self.current_active):
                self.failure_count[self.current_active] = 0
            else:
                self.failure_count[self.current_active] += 1
                logger.warning(
                    f"{CONFIG['servers'][self.current_active]['name']} "
                    f"连续失败 {self.failure_count[self.current_active]}/{CONFIG['threshold']} 次"
                )
            
            # 判断是否需要切换
            if self.failure_count[self.current_active] >= CONFIG['threshold']:
                target = 'backup' if self.current_active == 'master' else 'master'
                
                # 检查备用服务器是否可用
                if self.check_server(target):
                    logger.warning(
                        f"切换服务：{self.current_active} → {target}"
                    )
                    
                    if self.switch_dns(target):
                        self.send_notification(
                            f"服务已从 {CONFIG['servers'][self.current_active]['name']} "
                            f"切换到 {CONFIG['servers'][target]['name']}"
                        )
                        self.current_active = target
                        self.failure_count = {'master': 0, 'backup': 0}
                else:
                    logger.error(
                        f"备用服务器 {CONFIG['servers'][target]['name']} 也不可用！"
                    )
                    self.send_notification(
                        "⚠️ 严重：主备服务器均不可用！"
                    )
            
            time.sleep(CONFIG['interval'])

if __name__ == '__main__':
    checker = HealthChecker()
    checker.run()
```

#### 3. 部署到腾讯云云函数

1. **创建云函数**
   - 登录 [腾讯云云函数控制台](https://console.cloud.tencent.com/scf)
   - 创建函数 → 自定义创建
   - 运行环境：Python 3.8
   - 上传方式：本地上传 zip 包

2. **配置触发器**
   - 触发方式：定时触发
   - 触发周期：`*/10 * * * * *` (每 10 秒)

3. **配置环境变量**
   ```bash
   DNS_SECRET_ID=your_secret_id
   DNS_SECRET_KEY=your_secret_key
   WEBHOOK_URL=your_webhook_url
   ```

---

### 方案 B：Docker + 自研健康检查（无需 Keepalived）

如果不想使用外部监控服务，可以在两台服务器上都部署健康检查脚本。

#### 1. 服务器 A 配置

**docker-compose.yml:**

```yaml
version: '3.8'

services:
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
      - SESSION_SECRET=YOUR_SECRET
      - NODE_ROLE=master
    depends_on:
      - postgres
      - redis
    networks:
      - cinatoken-net
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "-", "http://localhost:3000/api/status"]
      interval: 10s
      timeout: 5s
      retries: 3

  postgres:
    image: postgres:15-alpine
    container_name: cinatoken-db
    restart: always
    environment:
      POSTGRES_USER: cinatoken
      POSTGRES_PASSWORD: YOUR_PASSWORD
      POSTGRES_DB: cinatoken
      POSTGRES_INITDB_ARGS: "-c wal_level=replica -c max_wal_senders=3"
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
      - ./backup/postgres:/backup
    networks:
      - cinatoken-net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U cinatoken"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    container_name: cinatoken-redis
    restart: always
    command: redis-server --appendonly yes
    volumes:
      - ./data/redis:/data
    networks:
      - cinatoken-net

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

  # 健康检查容器
  healthcheck:
    image: python:3.9-alpine
    container_name: healthcheck
    restart: always
    volumes:
      - ./healthcheck:/app
    working_dir: /app
    command: sh -c "pip install requests && python healthcheck.py master"
    depends_on:
      - cinatoken
    network_mode: "host"
    environment:
      - PEER_SERVER_IP=5.6.7.8
      - CURRENT_ROLE=master
      - DNS_API_URL=https://api.dnspod.cn/record.modify
      - DNS_API_TOKEN=YOUR_API_TOKEN
      - DOMAIN=your-domain.com
      - SUBDOMAIN=www

networks:
  cinatoken-net:
    driver: bridge
```

#### 2. 健康检查脚本

**healthcheck/healthcheck.py:**

```python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
双机健康检查脚本
运行在每台服务器上，检测对等节点状态
"""

import os
import sys
import requests
import time
import logging
from datetime import datetime

# 配置
ROLE = os.getenv('CURRENT_ROLE', 'master')
PEER_IP = os.getenv('PEER_SERVER_IP')
DNS_API_TOKEN = os.getenv('DNS_API_TOKEN')
DOMAIN = os.getenv('DOMAIN')
SUBDOMAIN = os.getenv('SUBDOMAIN', 'www')
CHECK_INTERVAL = int(os.getenv('CHECK_INTERVAL', '10'))
FAILURE_THRESHOLD = int(os.getenv('FAILURE_THRESHOLD', '3'))
LOCK_FILE = '/tmp/cinatoken_ha.lock'

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/app/healthcheck.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

class DualServerHA:
    def __init__(self, role, peer_ip):
        self.role = role
        self.peer_ip = peer_ip
        self.failure_count = 0
        self.is_active = (role == 'master')
        self.last_switch_time = 0
    
    def check_local(self):
        """检查本地服务"""
        try:
            resp = requests.get('http://localhost:3000/api/status', timeout=5)
            return resp.status_code == 200 and resp.json().get('success') == True
        except Exception as e:
            logger.warning(f"本地检查失败：{e}")
            return False
    
    def check_peer(self):
        """检查对等节点"""
        try:
            resp = requests.get(f'http://{self.peer_ip}:3000/api/status', timeout=5)
            return resp.status_code == 200 and resp.json().get('success') == True
        except Exception as e:
            logger.warning(f"对等节点检查失败：{e}")
            return False
    
    def switch_to_backup(self):
        """切换到备用模式"""
        logger.info("切换到备用模式")
        self.is_active = False
        # 可以在这里添加通知逻辑
    
    def switch_to_master(self):
        """切换到主模式"""
        logger.info("切换到主模式")
        self.is_active = True
        self.switch_dns()
    
    def switch_dns(self):
        """切换 DNS 解析"""
        if not DNS_API_TOKEN:
            logger.warning("未配置 DNS API Token，跳过 DNS 切换")
            return
        
        current_ip = self.get_current_ip()
        try:
            # 调用 DNSPod API 切换
            headers = {'Authorization': f'Token {DNS_API_TOKEN}'}
            params = {
                'domain': DOMAIN,
                'sub_domain': SUBDOMAIN,
                'record_type': 'A',
                'record_line': '默认',
                'value': current_ip
            }
            resp = requests.post(
                'https://dnsapi.cn/Record.Modify',
                headers=headers,
                data=params
            )
            if resp.status_code == 200:
                logger.info(f"DNS 切换到 {current_ip} 成功")
            else:
                logger.error(f"DNS 切换失败：{resp.text}")
        except Exception as e:
            logger.error(f"DNS 切换异常：{e}")
    
    def get_current_ip(self):
        """获取当前服务器公网 IP"""
        try:
            resp = requests.get('http://ident.me', timeout=5)
            return resp.text.strip()
        except:
            return PEER_IP if self.role == 'backup' else 'unknown'
    
    def run(self):
        """主循环"""
        logger.info(f"健康检查启动 - 角色：{self.role}")
        
        while True:
            try:
                # 防止频繁切换
                if time.time() - self.last_switch_time < 300:
                    time.sleep(CHECK_INTERVAL)
                    continue
                
                local_ok = self.check_local()
                peer_ok = self.check_peer()
                
                if self.role == 'master':
                    if not local_ok:
                        self.failure_count += 1
                        logger.warning(f"主节点连续失败 {self.failure_count}/{FAILURE_THRESHOLD} 次")
                        
                        if self.failure_count >= FAILURE_THRESHOLD:
                            if peer_ok:
                                logger.warning("主节点故障，切换到备用节点")
                                self.switch_to_backup()
                                self.last_switch_time = time.time()
                    else:
                        self.failure_count = 0
                
                elif self.role == 'backup':
                    if not peer_ok and local_ok:
                        logger.warning("主节点不可用，备用节点接管")
                        self.switch_to_master()
                        self.last_switch_time = time.time()
                
                time.sleep(CHECK_INTERVAL)
                
            except Exception as e:
                logger.error(f"健康检查异常：{e}")
                time.sleep(CHECK_INTERVAL)

if __name__ == '__main__':
    if len(sys.argv) > 1:
        role = sys.argv[1]
    else:
        role = ROLE
    
    peer_ip = PEER_IP
    if not peer_ip:
        logger.error("未配置 PEER_SERVER_IP 环境变量")
        sys.exit(1)
    
    ha = DualServerHA(role, peer_ip)
    ha.run()
```

---

## 📊 方案对比

| 特性 | 原生 Keepalived | 云监控 + DNS | 自研健康检查 |
|------|----------------|--------------|--------------|
| **切换速度** | 秒级 | 分钟级 | 分钟级 |
| **配置复杂度** | 高 | 中 | 中 |
| **依赖外部服务** | 否 | 是 | 可选 |
| **轻量服务器支持** | ❌ | ✅ | ✅ |
| **成本** | 免费 | 云函数免费额度 | 免费 |
| **推荐度** | ⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ |

---

## 🎯 最终推荐

**对于腾讯云轻量应用服务器，推荐使用：云监控 + DNS 自动切换**

### 优势：
1. ✅ 绕过 VRRP 协议限制
2. ✅ 无需内网通信
3. ✅ 配置简单
4. ✅ 成本低（云函数免费额度够用）
5. ✅ 可观测性好（日志、告警）

### 部署步骤：
1. 在两台服务器部署 CinaToken（Docker）
2. 配置 PostgreSQL 主从复制
3. 部署云函数健康检查脚本
4. 配置 DNSPod API 自动切换
5. 配置企业微信/钉钉告警

---

## 📝 注意事项

1. **DNS 生效时间**
   - 设置 TTL = 60 秒
   - 实际切换时间约 1-2 分钟

2. **数据库一致性**
   - 确保 PostgreSQL 主从同步正常
   - 切换前检查从库延迟

3. **脑裂问题**
   - 设置合理的切换阈值
   - 添加切换冷却时间（5 分钟）

4. **监控告警**
   - 配置多渠道告警
   - 定期演练故障切换

---

## 🔗 相关资源

- [腾讯云云函数文档](https://cloud.tencent.com/document/product/583)
- [DNSPod API 文档](https://cloud.tencent.com/document/api/302/8516)
- [PostgreSQL 流复制](https://www.postgresql.org/docs/current/warm-standby.html)
- [CinaToken 部署文档](./tencent-lighthouse-dual-server.md)
