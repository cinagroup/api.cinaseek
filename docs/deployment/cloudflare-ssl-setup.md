# Cloudflare Full (Strict) SSL 配置指南

本文档介绍如何为 CinaToken 配置 **Cloudflare Full (Strict) SSL** 模式，使用免费的 **Origin CA 证书**（15 年有效期）。

## 📋 前提条件

1. **域名已添加到 Cloudflare**
   - 域名 DNS 已托管到 Cloudflare
   - DNS 记录已配置（橙色云朵启用）

2. **服务器信息**
   - 服务器 IP: `43.156.66.122`
   - 部署目录：`/opt/cinatoken`

3. **Cloudflare API Token**
   - 需要创建 Origin CA 权限的 Token

---

## 🚀 快速配置（3 步）

### 步骤 1：获取 Cloudflare API Token

1. 访问：https://dash.cloudflare.com/profile/api-tokens
2. 点击 **"Create Token"**
3. 选择模板：**"Origin CA"**
4. 配置：
   - **Permissions:** Origin CA
   - **Account:** 选择你的账户
   - **Zone:** 选择你的域名
5. 点击 **"Continue to summary"**
6. **复制 Token**（只显示一次，请妥善保存）

### 步骤 2：运行配置脚本

在服务器执行：

```bash
# 下载配置脚本
curl -o setup-ssl.sh https://raw.githubusercontent.com/cinagroup/cinatoken/cinatoken/scripts/setup-cloudflare-ssl.sh
chmod +x setup-ssl.sh

# 运行脚本
sudo ./setup-ssl.sh
```

按提示输入：
- **Cloudflare API Token:** （步骤 1 中复制的 Token）
- **域名:** 例如 `example.com`
- **子域名:** 例如 `www`（可选，留空表示仅主域名）

脚本会自动：
- ✅ 安装 acme.sh
- ✅ 签发 Cloudflare Origin CA 证书（15 年）
- ✅ 配置 Nginx HTTPS
- ✅ 重启 Nginx 服务

### 步骤 3：Cloudflare Dashboard 设置

1. 登录 [Cloudflare Dashboard](https://dash.cloudflare.com)
2. 选择你的域名
3. 进入 **SSL/TLS** → **Overview**
4. 加密模式选择：**Full (Strict)**
5. （可选）进入 **SSL/TLS** → **Origin Server** 安装证书

---

## 🔍 验证配置

### 检查证书

```bash
# 查看证书信息
openssl x509 -in /opt/cinatoken/ssl/fullchain.pem -text -noout

# 查看证书有效期
openssl x509 -in /opt/cinatoken/ssl/fullchain.pem -dates -noout
```

### 测试 HTTPS

```bash
# 测试 HTTPS 连接
curl -I https://your-domain.com

# 应该看到：
# HTTP/2 200
# strict-transport-security: max-age=31536000
```

### 浏览器访问

访问 `https://your-domain.com`，应该看到：
- ✅ 绿色锁标志
- ✅ 证书有效
- ✅ 无安全警告

---

## 📊 架构说明

```
用户浏览器
    ↓ HTTPS (加密)
Cloudflare CDN
    ↓ HTTPS (加密，Origin CA 证书)
源服务器 (Nginx)
    ↓ HTTP (内网)
CinaToken 应用
```

**安全特性：**
- ✅ 用户到 Cloudflare：加密
- ✅ Cloudflare 到源站：加密（Origin CA 证书）
- ✅ 防止中间人攻击
- ✅ 防止数据窃听
- ✅ 证书 15 年有效期

---

## 🔄 证书管理

### 自动续期

acme.sh 已配置自动续期，证书会在到期前自动更新。

```bash
# 查看自动续期任务
~/.acme.sh/acme.sh --list

# 手动续期（如果需要）
~/.acme.sh/acme.sh --renew -d your-domain.com --force
```

### 证书位置

```
/opt/cinatoken/ssl/
├── cert.pem          # 证书
├── key.pem           # 私钥
├── fullchain.pem     # 完整证书链
└── SSL_CONFIG.txt    # 配置信息
```

---

## ⚠️ 常见问题

### Q1: DNS 解析不生效

**解决：**
1. 确保 DNS 记录已添加到 Cloudflare
2. 确保 CDN 代理已启用（橙色云朵）
3. 等待 DNS 传播（最多 24 小时）

### Q2: Cloudflare 显示错误 521/522

**解决：**
1. 检查 Nginx 是否运行：`docker compose ps`
2. 检查 443 端口是否开放：`netstat -tlnp | grep 443`
3. 检查防火墙规则

### Q3: 浏览器显示证书错误

**解决：**
1. 清除浏览器缓存
2. 检查系统时间是否正确
3. 确保证书未过期

### Q4: HTTP 不跳转到 HTTPS

**解决：**
1. 检查 Nginx 配置：`cat /opt/cinatoken/nginx/conf.d/default.conf`
2. 重启 Nginx：`docker compose restart nginx`
3. 清除浏览器缓存

---

## 🔒 安全最佳实践

### 1. 启用 HSTS

在 Nginx 配置中添加：

```nginx
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
```

### 2. 配置防火墙

腾讯云控制台 → 防火墙：
- ✅ 开放 80 端口（HTTP，用于证书验证）
- ✅ 开放 443 端口（HTTPS）
- ❌ 限制 22 端口（仅你的 IP）

### 3. 定期更新

```bash
# 更新 acme.sh
~/.acme.sh/acme.sh --upgrade

# 更新系统
apt update && apt upgrade -y
```

---

## 📝 配置摘要

| 项目 | 配置 |
|------|------|
| **SSL 模式** | Full (Strict) |
| **证书类型** | Cloudflare Origin CA |
| **证书有效期** | 15 年（5475 天） |
| **签发机构** | ZeroSSL |
| **自动续期** | 是（acme.sh） |
| **HSTS** | 可选 |
| **HTTP 跳转** | 是（301） |

---

## 🔗 相关资源

- [Cloudflare Origin CA 文档](https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/)
- [acme.sh GitHub](https://github.com/acmesh-official/acme.sh)
- [CinaToken 部署文档](./tencent-master-slave-config.md)

---

## 🆘 获取帮助

遇到问题？

- 📘 查看 [CinaToken 文档](https://docs.cinatoken.pro)
- 🐛 提交 [GitHub Issue](https://github.com/cinagroup/cinatoken/issues)
- 💬 社区讨论
