#!/bin/bash

# 自动读取 Token
TOKEN=$(cat ~/.github_token)
if [ -z "$TOKEN" ]; then
    echo "错误：未找到 Token，请运行：echo \"你的token\" > ~/.github_token"
    exit 1
fi

# 必须提供仓库链接
if [ -z "$1" ]; then
    echo "用法：clone.sh https://github.com/xxx/yyy.git"
    exit 1
fi

SRC_URL="$1"

# 自动识别仓库名
REPO=$(basename "$SRC_URL" .git)

echo "源仓库：$SRC_URL"
echo "仓库名：$REPO"

# 自动识别你的 GitHub 用户名
USERNAME=$(curl -s -H "Authorization: token $TOKEN" https://api.github.com/user | grep '"login"' | awk -F '"' '{print $4}')

echo "你的 GitHub 用户名：$USERNAME"

# 创建 Private 仓库
echo "创建 Private 仓库：$REPO"
curl -s -H "Authorization: token $TOKEN" \
     -H "Accept: application/vnd.github+json" \
     https://api.github.com/user/repos \
     -d "{\"name\":\"$REPO\", \"private\":true}"

# clone 原仓库
echo "正在 clone 原仓库..."
git clone --mirror "$SRC_URL" "/tmp/$REPO.git"

cd "/tmp/$REPO.git"

# 清理 GitHub 不允许推送的 hidden refs
git for-each-ref --format="%(refname)" refs/pull | while read ref; do
    git update-ref -d "$ref"
done

# 推送到你的 Private 仓库
echo "推送到 Private 仓库：$REPO"
git remote set-url origin "https://$USERNAME:$TOKEN@github.com/$USERNAME/$REPO.git"
git push --mirror origin

cd /
rm -rf "/tmp/$REPO.git"

echo "备份完成：$REPO"
