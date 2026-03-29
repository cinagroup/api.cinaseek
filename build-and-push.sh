#!/bin/bash
# CinaToken Docker 镜像构建和推送脚本

set -e

echo "=== CinaToken Docker 镜像构建 ==="

# 版本号
VERSION="v0.11.9-cinatoken.1"
echo "版本号：$VERSION"

# Docker Hub 用户名
DOCKER_USER="cinagroup"
IMAGE_NAME="${DOCKER_USER}/cinatoken"

echo "镜像名称：$IMAGE_NAME"
echo ""

# 检查 Docker 登录
if ! docker info 2>&1 | grep -q "Username"; then
    echo "错误：未登录 Docker Hub"
    echo "请先运行：docker login"
    exit 1
fi

# 构建镜像
echo "开始构建 Docker 镜像..."
echo "这可能需要 15-20 分钟，请耐心等待..."
echo ""

docker build \
    --progress=plain \
    --build-arg TARGETOS=linux \
    --build-arg TARGETARCH=amd64 \
    -t ${IMAGE_NAME}:${VERSION} \
    -t ${IMAGE_NAME}:latest \
    -t ${IMAGE_NAME}:v0.11.9 \
    .

echo ""
echo "=== 构建完成 ==="
echo ""
echo "本地镜像:"
docker images | grep cinatoken

echo ""
echo "开始推送到 Docker Hub..."
docker push ${IMAGE_NAME}:${VERSION}
docker push ${IMAGE_NAME}:latest
docker push ${IMAGE_NAME}:v0.11.9

echo ""
echo "=== 推送完成 ==="
echo ""
echo "镜像已推送到："
echo "  - https://hub.docker.com/r/${DOCKER_USER}/cinatoken/tags"
echo ""
echo "标签:"
echo "  - ${IMAGE_NAME}:${VERSION}"
echo "  - ${IMAGE_NAME}:latest"
echo "  - ${IMAGE_NAME}:v0.11.9"
