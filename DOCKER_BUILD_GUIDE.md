# CinaToken Docker 镜像构建指南

## 📋 前提条件

1. **Docker Hub 账户**
   - 用户名：cinagroup
   - 需要已创建并验证

2. **Docker 登录**
   ```bash
   # 方式 1：交互式登录
   docker login
   
   # 方式 2：使用 Access Token（推荐用于自动化）
   echo "YOUR_ACCESS_TOKEN" | docker login -u cinagroup --password-stdin
   ```

3. **获取 Docker Hub Access Token**
   - 访问：https://hub.docker.com/settings/security
   - 点击 "New Access Token"
   - 设置权限：Read & Write
   - 复制 Token 并保存

## 🚀 构建和推送

### 方式 1：使用构建脚本（推荐）

```bash
cd /root/.openclaw/workspace/cinatoken

# 1. 确保已登录 Docker Hub
docker login

# 2. 运行构建脚本
./build-and-push.sh
```

### 方式 2：手动构建

```bash
cd /root/.openclaw/workspace/cinatoken

# 1. 登录 Docker Hub
docker login

# 2. 构建镜像
VERSION="v0.11.9-cinatoken.1"
docker build \
    --progress=plain \
    -t cinagroup/cinatoken:${VERSION} \
    -t cinagroup/cinatoken:latest \
    -t cinagroup/cinatoken:v0.11.9 \
    .

# 3. 推送镜像
docker push cinagroup/cinatoken:${VERSION}
docker push cinagroup/cinatoken:latest
docker push cinagroup/cinatoken:v0.11.9
```

## ⏱️ 预计时间

- **构建时间：** 15-25 分钟（取决于网络）
- **推送时间：** 5-10 分钟（取决于带宽）
- **总计：** 约 20-35 分钟

## 📦 镜像信息

- **镜像名称：** cinagroup/cinatoken
- **标签：**
  - `latest` - 最新稳定版
  - `v0.11.9` - 版本号
  - `v0.11.9-cinatoken.1` - 完整版本标识

- **大小：** 约 150-200 MB
- **架构：** linux/amd64

## 🔍 验证镜像

构建完成后验证：

```bash
# 查看本地镜像
docker images | grep cinatoken

# 查看 Docker Hub
# https://hub.docker.com/r/cinagroup/cinatoken/tags

# 测试拉取
docker pull cinagroup/cinatoken:latest
```

## 📝 更新部署

镜像推送完成后，更新服务器部署：

```bash
cd /opt/cinatoken

# 1. 更新 docker-compose.yml
# 将 image: calciumion/new-api:latest 改为
# image: cinagroup/cinatoken:latest

sed -i 's/calciumion\/new-api/cinagroup\/cinatoken/g' docker-compose.yml

# 2. 拉取新镜像
docker compose pull

# 3. 重新部署
docker compose down
docker compose up -d

# 4. 验证
docker compose ps
curl http://localhost/api/status
```

## ⚠️ 常见问题

### 构建失败：前端编译错误

```bash
# 检查 web/package.json 和 web/bun.lock
cd web
bun install
bun run build

# 如果有错误，修复后重新构建 Docker 镜像
```

### 推送失败：认证错误

```bash
# 重新登录
docker logout
docker login

# 或使用 Token
echo "TOKEN" | docker login -u cinagroup --password-stdin
```

### 构建太慢

```bash
# 使用国内 Docker 镜像加速
# 编辑 /etc/docker/daemon.json
{
  "registry-mirrors": [
    "https://docker.mirrors.ustc.edu.cn",
    "https://registry.docker-cn.com"
  ]
}

# 重启 Docker
systemctl restart docker
```

## 📁 相关文件

- `Dockerfile` - Docker 镜像构建文件
- `VERSION` - 版本号文件
- `build-and-push.sh` - 自动化构建脚本
- `common/constants.go` - 系统名称配置

## 🔗 相关链接

- [Docker Hub](https://hub.docker.com/r/cinagroup/cinatoken)
- [Docker 官方文档](https://docs.docker.com/)
- [CinaToken GitHub](https://github.com/cinagroup/cinatoken)
