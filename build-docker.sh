#!/bin/bash
# CinaToken Docker 镜像构建脚本

set -e

echo "=== CinaToken Docker 镜像构建 ==="

# 检查 Docker
if ! command -v docker &> /dev/null; then
    echo "错误：Docker 未安装"
    exit 1
fi

# 获取版本号
VERSION=$(cat VERSION 2>/dev/null || echo "0.1.0")
echo "版本号：$VERSION"

# 构建镜像
echo "开始构建 Docker 镜像..."
docker build -t cinagroup/cinatoken:$VERSION -t cinagroup/cinatoken:latest .

echo ""
echo "=== 构建完成 ==="
echo "镜像列表:"
docker images | grep cinatoken

echo ""
echo "推送镜像到 Docker Hub (可选):"
echo "  docker push cinagroup/cinatoken:$VERSION"
echo "  docker push cinagroup/cinatoken:latest"
