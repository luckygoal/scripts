#!/bin/bash

echo "请输入要备份的 GitHub 仓库链接（例如：https://github.com/newbietan/CloudSSH.git）:"
read SOURCE_URL

if [ -z "$SOURCE_URL" ]; then
    echo "错误：仓库链接不能为空"
    exit 1
fi

# 自动解析原仓库名
ORIGINAL_NAME=$(basename -s .git "$SOURCE_URL")

echo "检测到源仓库名：$ORIGINAL_NAME"
echo "请输入你希望在自己 GitHub 上创建的 private 仓库名（直接回车使用默认：$ORIGINAL_NAME）:"
read TARGET_NAME

TARGET_NAME="${TARGET_NAME:-$ORIGINAL_NAME}"

echo "最终仓库名：$TARGET_NAME"
echo "确认创建并备份到该仓库？(y/n):"
read CONFIRM

if [ "$CONFIRM" != "y" ]; then
    echo "已取消操作"
    exit 0
fi

echo "请输入你的 GitHub 用户名（例如：luckygoal）:"
read USERNAME

echo "请输入你的 GitHub 密码或 Token（输入时不会显示）:"
read -s PASSWORD

echo ""
echo "正在 GitHub 创建 private 仓库..."

curl -u "$USERNAME:$PASSWORD" \
     -H "Accept: application/vnd.github+json" \
     https://api.github.com/user/repos \
     -d "{\"name\":\"$TARGET_NAME\", \"private\":true}"

echo "正在 clone 原仓库..."
git clone --mirror "$SOURCE_URL" "/tmp/$TARGET_NAME.git"

cd "/tmp/$TARGET_NAME.git"

echo "正在推送到你的 private 仓库..."
git remote set-url origin "https://$USERNAME:$PASSWORD@github.com/$USERNAME/$TARGET_NAME.git"
git push --mirror origin

cd /
rm -rf "/tmp/$TARGET_NAME.git"

echo "备份完成： https://github.com/$USERNAME/$TARGET_NAME"
