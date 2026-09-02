#!/bin/bash

# 强制从真实终端读取输入，避免 WebSSH 自动回车问题
read_tty() {
    read "$@" < /dev/tty
}

echo "请输入你的 GitHub 用户名（例如：lu******l）:"
read_tty USERNAME

echo "请输入你的 GitHub 密码或 Token（输入时不会显示）:"
read_tty -s TOKEN
echo ""

echo "正在读取你的 GitHub Public 仓库列表..."

REPOS=$(curl -s -u "$USERNAME:$TOKEN" "https://api.github.com/users/$USERNAME/repos?per_page=200" | \
        grep '"name"' | awk -F '"' '{print $4}')

if [ -z "$REPOS" ]; then
    echo "未找到任何 Public 仓库，或 Token 权限不足。"
    exit 1
fi

echo "找到以下 Public 仓库："
echo "$REPOS"
echo ""
echo "开始自动备份..."

for REPO in $REPOS; do
    echo "----------------------------------------"
    echo "处理仓库：$REPO"

    # 检查 private 仓库是否已存在
    CHECK=$(curl -s -u "$USERNAME:$TOKEN" "https://api.github.com/repos/$USERNAME/$REPO")

    if echo "$CHECK" | grep -q '"full_name"'; then
        echo "仓库 $REPO 已存在，跳过创建步骤。"
    else
        echo "创建 private 仓库：$REPO"
        curl -s -u "$USERNAME:$TOKEN" \
             -H "Accept: application/vnd.github+json" \
             https://api.github.com/user/repos \
             -d "{\"name\":\"$REPO\", \"private\":true}"
    fi

    # clone 原仓库
    echo "正在 clone 原仓库：$REPO"
    git clone --mirror "https://github.com/$USERNAME/$REPO.git" "/tmp/$REPO.git"

    cd "/tmp/$REPO.git"

    echo "清理 GitHub 不允许推送的 hidden refs..."
    git for-each-ref --format="%(refname)" refs/pull | while read ref; do
        git update-ref -d "$ref"
    done

    echo "推送到 private 仓库：$REPO"
    git remote set-url origin "https://$USERNAME:$TOKEN@github.com/$USERNAME/$REPO.git"
    git push --mirror origin

    cd /
    rm -rf "/tmp/$REPO.git"

    echo "完成备份：$REPO"
done

echo "----------------------------------------"
echo "全部 Public 仓库已备份完成！"
