#!/bin/bash

# 如果不是手动执行（stdin 不是 tty），自动退出
if ! [ -t 0 ]; then
    echo "请手动执行： clone.sh"
    exit 0
fi

echo "请输入要备份的 GitHub 仓库链接（例如：https://github.com/xxx/yyy.git）:"
read SRC_URL

if [ -z "$SRC_URL" ]; then
    echo "错误：仓库链接不能为空"
    exit 1
fi

REPO=$(basename "$SRC_URL" .git)

echo "源仓库：$SRC_URL"
echo "仓库名：$REPO"

# 手动输入 Token
read -p "请输入你的 GitHub Token: " TOKEN

# 自动识别你的 GitHub 用户名
USERNAME=$(curl -s -H "Authorization: token $TOKEN" https://api.github.com/user | grep '"login"' | awk -F '"' '{print $4}')

if [ -z "$USERNAME" ]; then
    echo "Token 无效，请检查后重试。"
    exit 1
fi

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
