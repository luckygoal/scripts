#!/bin/bash

# 用法:
# ./clone.sh https://github.com/xxx/yyy.git

if [ -z "$1" ]; then
    echo "请提供 GitHub 仓库链接"
    exit 1
fi

SOURCE_URL="$1"
USER="luckygoal"

# 自动解析原仓库名
ORIGINAL_NAME=$(basename -s .git "$SOURCE_URL")

echo "检测到源仓库名: $ORIGINAL_NAME"
read -p "请输入要在你 GitHub 上创建的 private 仓库名（直接回车使用默认: $ORIGINAL_NAME）: " TARGET_NAME

# 如果用户没有输入，则使用默认名
TARGET_NAME="${TARGET_NAME:-$ORIGINAL_NAME}"

echo "最终仓库名: $TARGET_NAME"
read -p "确认创建并备份到该仓库？(y/n): " CONFIRM

if [ "$CONFIRM" != "y" ]; then
    echo "已取消操作"
    exit 0
fi

# 手动输入 Token（不会在脚本里保存）
read -p "请输入你的 GitHub Token（不会保存）: " TOKEN

# 1) 在 GitHub 创建 private 仓库
echo "正在 GitHub 创建 private 仓库..."
curl -H "Authorization: token $TOKEN" \
     -H "Accept: application/vnd.github+json" \
     https://api.github.com/user/repos \
     -d "{\"name\":\"$TARGET_NAME\", \"private\":true}"

# 2) clone 原仓库
echo "正在 clone 原仓库..."
git clone --mirror "$SOURCE_URL" "/tmp/$TARGET_NAME.git"

cd "/tmp/$TARGET_NAME.git"

# 3) 设置远程为你的 private 仓库
git remote set-url origin "https://$USER:$TOKEN@github.com/$USER/$TARGET_NAME.git"

# 4) 推送
echo "正在推送到你的 private 仓库..."
git push --mirror origin

# 5) 清理
cd /
rm -rf "/tmp/$TARGET_NAME.git"

echo "备份完成: https://github.com/$USER/$TARGET_NAME"
