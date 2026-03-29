# CinaToken Render.com 部署指南

本文档介绍如何将 CinaToken 部署到 [Render.com](https://render.com) 云平台。

## 📋 部署方式

### 方式一：使用 render.yaml 一键部署（推荐）

#### 1. 准备 Render 账户

1. 访问 [Render.com](https://render.com) 注册/登录账户
2. 进入 [Dashboard](https://dashboard.render.com/)

#### 2. 创建 Blueprints

1. 点击 **New +** → **Blueprint**
2. 连接你的 GitHub 仓库：`https://github.com/cinagroup/cinatoken`
3. 选择 `cinatoken` 分支
4. Render 会自动识别 `render.yaml` 配置文件
5. 点击 **Apply** 开始部署

#### 3. 等待部署完成

Render 会自动创建以下资源：
- ✅ Web Service（CinaToken 主应用）
- ✅ PostgreSQL 数据库
- ✅ Redis 缓存服务
- ✅ 持久化磁盘（5GB）

部署完成后，你会收到一个 `https://*.onrender.com` 的访问地址。

---

### 方式二：手动部署

如果不想使用 `render.yaml`，可以手动创建各个服务。

#### 步骤 1：创建 PostgreSQL 数据库

1. 进入 Render Dashboard → **New +** → **PostgreSQL**
2. 配置：
   - **Name:** `cinatoken-db`
   - **Region:** 选择离你最近的区域（推荐 Oregon）
   - **Plan:** Starter（免费层）
   - **Database Name:** `cinatoken`
   - **User:** `cinatoken`
3. 创建后保存 **Internal Database URL**（类似 `postgresql://user:pass@host:5432/cinatoken`）

#### 步骤 2：创建 Redis 服务

1. **New +** → **Redis**
2. 配置：
   - **Name:** `cinatoken-redis`
   - **Region:** 与数据库相同区域
   - **Plan:** Starter
   - **Max Memory Policy:** noeviction
3. 保存 **Internal Redis URL**

#### 步骤 3：创建 Web Service

1. **New +** → **Web Service**
2. 连接 GitHub 仓库：`cinagroup/cinatoken`
3. 配置：
   - **Name:** `cinatoken`
   - **Region:** 与数据库相同区域
   - **Branch:** `cinatoken`
   - **Root Directory:** （留空）
   - **Runtime:** `Docker`
   - **DockerfilePath:** `./Dockerfile`
   - **Plan:** Starter（$7/月）或更高

4. **Environment Variables** 添加以下环境变量：

```bash
# 数据库连接（从步骤 1 获取）
SQL_DSN=postgresql://user:pass@host:5432/cinatoken

# Redis 连接（从步骤 2 获取）
REDIS_CONN_STRING=redis://host:6379

# 会话密钥（自动生成）
SESSION_SECRET=<随机生成一个长字符串>

# 时区
TZ=Asia/Shanghai

# 日志配置
ERROR_LOG_ENABLED=true
BATCH_UPDATE_ENABLED=true

# 流式响应超时（秒）
STREAMING_TIMEOUT=300
```

5. **Disk** 添加持久化存储：
   - **Name:** `cinatoken-data`
   - **Mount Path:** `/data`
   - **Size:** 5GB（最小）

6. **Health Check Path:** `/api/status`

7. 点击 **Create Web Service**

---

## 🔧 配置说明

### 必需环境变量

| 变量名 | 说明 | 示例 |
|--------|------|------|
| `SQL_DSN` | PostgreSQL 连接字符串 | `postgresql://user:pass@host:5432/cinatoken` |
| `REDIS_CONN_STRING` | Redis 连接字符串 | `redis://host:6379` |
| `SESSION_SECRET` | 会话加密密钥（多实例部署时必须） | `random_string_here` |
| `TZ` | 时区 | `Asia/Shanghai` |

### 可选环境变量

| 变量名 | 默认值 | 说明 |
|--------|--------|------|
| `ERROR_LOG_ENABLED` | `true` | 启用错误日志 |
| `BATCH_UPDATE_ENABLED` | `true` | 启用批量更新 |
| `STREAMING_TIMEOUT` | `120` | 流式响应超时（秒） |
| `SYNC_FREQUENCY` | - | 数据库同步频率（秒） |
| `GOOGLE_ANALYTICS_ID` | - | Google Analytics ID |
| `UMAMI_WEBSITE_ID` | - | Umami 网站 ID |

---

## 💰 费用估算

| 服务 | Plan | 价格/月 |
|------|------|---------|
| Web Service | Starter | $7 |
| PostgreSQL | Starter | 免费（90 天后需手动续期） |
| Redis | Starter | 免费（90 天后需手动续期） |
| 磁盘存储 | 5GB | 包含在 Web Service 中 |
| **总计** | | **~$7/月** |

> ⚠️ **注意：** Render 的免费层数据库和 Redis 在 90 天后会过期，需要手动续期或升级到付费计划。

---

## 🚀 部署后操作

### 1. 访问应用

部署完成后，访问 `https://<your-service-name>.onrender.com`

### 2. 初始设置

1. 首次访问会自动进入设置向导
2. 设置管理员账户
3. 配置渠道和模型

### 3. 域名绑定（可选）

1. 进入 Render Dashboard → Web Service → **Settings**
2. 滚动到 **Custom Domains**
3. 添加你的域名并按照提示配置 DNS

---

## 🔍 故障排查

### 服务启动失败

1. 查看日志：Dashboard → Web Service → **Logs**
2. 常见错误：
   - **数据库连接失败：** 检查 `SQL_DSN` 是否正确
   - **Redis 连接失败：** 检查 `REDIS_CONN_STRING` 是否正确
   - **端口冲突：** 确保使用 3000 端口

### 数据库迁移

如果需要从其他平台迁移数据：

```bash
# 导出原数据库
pg_dump -h old_host -U user cinatoken > backup.sql

# 导入到 Render
psql -h render_host -U user -d cinatoken < backup.sql
```

### 性能优化

如果遇到性能问题：

1. **升级 Plan：** Starter → Standard（$25/月）
2. **启用缓存：** 确保 Redis 正常工作
3. **调整超时：** 增加 `STREAMING_TIMEOUT`
4. **启用 CDN：** 使用 Cloudflare 等 CDN 服务

---

## 📝 注意事项

1. **冷启动问题：** Render 免费层在 15 分钟无访问后会进入休眠，下次访问需要 30-60 秒唤醒。建议升级到付费计划或设置定时访问。

2. **数据持久化：** 确保 `/data` 目录挂载到持久化磁盘，否则重启后数据会丢失。

3. **安全配置：**
   - 生产环境务必修改默认密码
   - 设置强 `SESSION_SECRET`
   - 启用 HTTPS（Render 默认提供）

4. **备份策略：** 定期导出数据库备份，Render 不保证数据永久保存。

---

## 🔗 相关资源

- [Render 官方文档](https://render.com/docs)
- [Render YAML 规格](https://render.com/docs/render-yaml-spec)
- [CinaToken GitHub](https://github.com/cinagroup/cinatoken)
- [CinaToken 文档](https://docs.cinatoken.pro)

---

## 🆘 获取帮助

遇到问题？

- 📘 查看 [官方文档](https://docs.cinatoken.pro)
- 🐛 提交 [GitHub Issue](https://github.com/cinagroup/cinatoken/issues)
- 💬 加入社区讨论
