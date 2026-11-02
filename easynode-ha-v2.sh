#!/bin/bash

set -e

VERSION="2.0"

EASYNODE_DATA="/opt/1panel/apps/local/easynode/easynode/data"
SYNC_KEY="/root/.ssh/easynode_sync"
SYNC_LOG="/var/log/easynode_sync.log"
BACKUP_DIR="/root/easynode-backup"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
NC="\033[0m"

msg() {
    echo -e "${GREEN}[OK]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

err() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

########################################
# 环境检查
########################################

[ "$(id -u)" -eq 0 ] || err "请使用root运行"

echo
echo "========================================="
echo " EasyNode HA Deploy v2.0"
echo "========================================="
echo

########################################
# 安装依赖
########################################

install_if_missing() {

    if ! command -v "$1" >/dev/null 2>&1; then
        echo "安装缺失组件: $1"

        apt update

        case "$1" in
            rsync)
                apt install -y rsync
                ;;
            sshpass)
                apt install -y sshpass
                ;;
            ssh)
                apt install -y openssh-client
                ;;
            crontab)
                apt install -y cron
                ;;
        esac
    fi
}

install_if_missing rsync
install_if_missing sshpass
install_if_missing ssh
install_if_missing crontab

########################################
# EasyNode检查
########################################

[ -d "$EASYNODE_DATA" ] || err "未发现EasyNode目录"

msg "发现EasyNode"

########################################
# 时区
########################################

TIMEZONE=$(timedatectl | grep "Time zone" | awk '{print $3}')

echo
echo "当前系统时区:"
echo "$TIMEZONE"
echo

########################################
# 用户输入
########################################

read -p "备用节点IP: " BACKUP_IP

read -p "SSH端口[22]: " BACKUP_PORT
BACKUP_PORT=${BACKUP_PORT:-22}

read -p "SSH用户[root]: " BACKUP_USER
BACKUP_USER=${BACKUP_USER:-root}

read -s -p "SSH密码: " BACKUP_PASS
echo

echo
echo "同步时间依据当前时区: $TIMEZONE"
read -p "每日同步时间(HH:MM): " SYNC_TIME

HOUR=$(echo "$SYNC_TIME" | cut -d: -f1)
MIN=$(echo "$SYNC_TIME" | cut -d: -f2)

########################################
# 验证远程环境
########################################

msg "检查备用节点"

sshpass -p "$BACKUP_PASS" ssh \
-o StrictHostKeyChecking=no \
-p "$BACKUP_PORT" \
${BACKUP_USER}@${BACKUP_IP} \
"test -d $EASYNODE_DATA"

msg "备用节点EasyNode存在"

########################################
# SSH统计
########################################

HOST_COUNT=$(grep -c "_id" ${EASYNODE_DATA}/host.db || true)
SCRIPT_COUNT=$(grep -c "_id" ${EASYNODE_DATA}/scripts.db || true)
KEY_COUNT=$(grep -c "_id" ${EASYNODE_DATA}/key.db || true)

########################################
# 创建同步密钥
########################################

mkdir -p ~/.ssh
chmod 700 ~/.ssh

if [ ! -f "$SYNC_KEY" ]; then

    ssh-keygen \
        -t ed25519 \
        -N "" \
        -f "$SYNC_KEY"

    msg "创建同步密钥"

else

    warn "同步密钥已存在，直接复用"

fi

########################################
# 推送公钥
########################################

msg "部署公钥"

sshpass -p "$BACKUP_PASS" ssh-copy-id \
-i ${SYNC_KEY}.pub \
-o StrictHostKeyChecking=no \
-p "$BACKUP_PORT" \
${BACKUP_USER}@${BACKUP_IP}

########################################
# 测试免密
########################################

ssh \
-i "$SYNC_KEY" \
-p "$BACKUP_PORT" \
${BACKUP_USER}@${BACKUP_IP} \
"hostname" >/dev/null

msg "免密登录成功"

########################################
# 创建备份
########################################

mkdir -p "$BACKUP_DIR"

BACKUP_FILE="$BACKUP_DIR/easynode-data-$(date +%F-%H%M).tar.gz"

tar czf "$BACKUP_FILE" "$EASYNODE_DATA"

msg "已备份:"
msg "$BACKUP_FILE"

########################################
# 停止备用EasyNode
########################################

msg "停止备用EasyNode"

ssh \
-i "$SYNC_KEY" \
-p "$BACKUP_PORT" \
${BACKUP_USER}@${BACKUP_IP} \
"docker ps -a --format '{{.Names}}' | grep easynode | xargs -r docker stop"

########################################
# 数据同步
########################################

msg "同步EasyNode数据"

rsync -az --delete \
-e "ssh -i $SYNC_KEY -p $BACKUP_PORT" \
${EASYNODE_DATA}/ \
${BACKUP_USER}@${BACKUP_IP}:${EASYNODE_DATA}/

########################################
# 启动备用EasyNode
########################################

msg "启动备用EasyNode"

ssh \
-i "$SYNC_KEY" \
-p "$BACKUP_PORT" \
${BACKUP_USER}@${BACKUP_IP} \
"docker ps -a --format '{{.Names}}' | grep easynode | xargs -r docker start"

########################################
# 创建同步脚本
########################################

cat >/root/easynode_sync.sh <<EOF
#!/bin/bash

LOG=/var/log/easynode_sync.log

echo "===== \$(date '+%F %T') =====" >> \$LOG

/usr/bin/rsync -azv --delete \
-e "ssh -i ${SYNC_KEY} -p ${BACKUP_PORT}" \
${EASYNODE_DATA}/ \
${BACKUP_USER}@${BACKUP_IP}:${EASYNODE_DATA}/ \
>> \$LOG 2>&1

echo "" >> \$LOG
EOF

chmod 700 /root/easynode_sync.sh

########################################
# 创建同步任务
########################################

(
crontab -l 2>/dev/null | grep -v easynode_sync.sh
echo "${MIN} ${HOUR} * * * /root/easynode_sync.sh"
) | crontab -

########################################
# 创建周备份任务
########################################

(
crontab -l 2>/dev/null | grep -v easynode_weekly_backup.sh
echo "0 2 * * 0 tar czf /root/easynode-backup/easynode-\$(date +\\\\%F).tar.gz ${EASYNODE_DATA}"
) | crontab -

########################################
# 首次同步验证
########################################

/root/easynode_sync.sh

########################################
# 输出结果
########################################

echo
echo "======================================"
echo " EasyNode HA 部署完成"
echo "======================================"
echo

echo "主节点 | awk '{print $1}'

echo
echo "备用节点:"
echo "$BACKUP_IP"

echo
echo "时区:"
echo "$TIMEZONE"

echo
echo "同步时间:"
echo "$SYNC_TIME"

echo
echo "同步密钥:"
echo "$SYNC_KEY"

echo
echo "同步日志:"
echo "$SYNC_LOG"

echo
echo "SSH主机数量:"
echo "$HOST_COUNT"

echo
echo "脚本数量:"
echo "$SCRIPT_COUNT"

echo
echo "SSH密钥数量:"
echo "$KEY_COUNT"

echo
echo "当前Crontab:"
crontab -l

echo
msg "部署成功"
