#!/usr/bin/env bash

# Xray IPv4 出站策略管理脚本
#
# 功能：
#   1. 检测当前 Xray DNS 和出站 IPv4 策略
#   2. 强制 Xray DNS 使用 IPv4
#   3. 强制 Xray freedom 出站使用 IPv4
#   4. 自动备份修改前配置
#   5. 配置校验失败自动回滚
#   6. 恢复脚本修改前的配置
#   7. 检查系统 IPv6 地址和路由
#
# 适用配置目录：
#   /etc/v2ray-agent/xray/conf
#
# 使用：
#   chmod +x xray-ipv4-policy.sh
#   sudo ./xray-ipv4-policy.sh

set -Eeuo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly DEFAULT_CONFIG_DIR="/etc/v2ray-agent/xray/conf"
readonly BACKUP_ROOT="/var/backups/xray-ipv4-policy"

CONFIG_DIR=""
DNS_FILE=""
OUTBOUND_FILE=""
XRAY_BIN=""
XRAY_SERVICE=""

readonly RED='\033[31m'
readonly GREEN='\033[32m'
readonly YELLOW='\033[33m'
readonly BLUE='\033[34m'
readonly RESET='\033[0m'

info() {
    printf '%b\n' "${BLUE}[INFO]${RESET} $*"
}

ok() {
    printf '%b\n' "${GREEN}[OK]${RESET} $*"
}

warn() {
    printf '%b\n' "${YELLOW}[WARN]${RESET} $*"
}

fail() {
    printf '%b\n' "${RED}[ERROR]${RESET} $*" >&2
}

die() {
    fail "$*"
    exit 1
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "请使用 root 用户运行，或通过 sudo 执行。"
    fi
}

check_dependencies() {
    local commands=(
        awk
        cp
        date
        find
        grep
        ip
        mkdir
        mv
        python3
        readlink
        sed
        systemctl
    )

    local command_name

    for command_name in "${commands[@]}"; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            die "缺少依赖命令：$command_name"
        fi
    done
}

find_xray_binary() {
    local candidates=(
        "/etc/v2ray-agent/xray/xray"
        "/usr/local/bin/xray"
        "/usr/bin/xray"
    )

    local candidate

    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate" ]]; then
            XRAY_BIN="$candidate"
            break
        fi
    done

    if [[ -z "$XRAY_BIN" ]]; then
        XRAY_BIN="$(command -v xray 2>/dev/null || true)"
    fi

    [[ -n "$XRAY_BIN" ]] || die "没有找到 Xray 可执行文件。"
}

find_xray_service() {
    if systemctl list-unit-files xray.service 2>/dev/null |
        grep -q '^xray.service'; then
        XRAY_SERVICE="xray"
        return
    fi

    if systemctl list-unit-files v2ray.service 2>/dev/null |
        grep -q '^v2ray.service'; then
        XRAY_SERVICE="v2ray"
        return
    fi

    read -r -p "请输入 Xray systemd 服务名 [xray]: " XRAY_SERVICE
    XRAY_SERVICE="${XRAY_SERVICE:-xray}"
}

find_config_dir() {
    if [[ -d "$DEFAULT_CONFIG_DIR" ]]; then
        CONFIG_DIR="$DEFAULT_CONFIG_DIR"
    else
        read -r -p "请输入 Xray 配置目录: " CONFIG_DIR
    fi

    [[ -d "$CONFIG_DIR" ]] ||
        die "配置目录不存在：$CONFIG_DIR"

    DNS_FILE="$CONFIG_DIR/11_dns.json"
    OUTBOUND_FILE="$CONFIG_DIR/z_direct_outbound.json"

    [[ -f "$DNS_FILE" ]] ||
        die "找不到 DNS 配置文件：$DNS_FILE"

    [[ -f "$OUTBOUND_FILE" ]] ||
        die "找不到出站配置文件：$OUTBOUND_FILE"
}

initialize() {
    require_root
    check_dependencies
    find_xray_binary
    find_xray_service
    find_config_dir

    mkdir -p "$BACKUP_ROOT"
}

json_value() {
    local file="$1"
    local expression="$2"

    python3 - "$file" "$expression" <<'PY'
import json
import sys

file_name = sys.argv[1]
expression = sys.argv[2]

try:
    with open(file_name, encoding="utf-8") as file:
        data = json.load(file)

    value = data

    for key in expression.split("."):
        if isinstance(value, dict):
            value = value.get(key)
        else:
            value = None
            break

    if value is None:
        print("<未设置>")
    elif isinstance(value, (dict, list)):
        print(json.dumps(value, ensure_ascii=False))
    else:
        print(value)

except Exception as exc:
    print(f"<读取失败: {exc}>")
    sys.exit(1)
PY
}

get_freedom_strategies() {
    python3 - "$OUTBOUND_FILE" <<'PY'
import json
import sys

file_name = sys.argv[1]

try:
    with open(file_name, encoding="utf-8") as file:
        data = json.load(file)

    outbounds = data.get("outbounds", [])
    found = False

    for index, outbound in enumerate(outbounds):
        if outbound.get("protocol") == "freedom":
            found = True
            strategy = outbound.get("settings", {}).get(
                "domainStrategy",
                "<未设置>"
            )
            print(f"outbounds[{index}].domainStrategy = {strategy}")

    if not found:
        print("<未找到 freedom 出站>")

except Exception as exc:
    print(f"<读取失败: {exc}>")
    sys.exit(1)
PY
}

all_freedom_outbounds_use_ipv4() {
    python3 - "$OUTBOUND_FILE" <<'PY'
import json
import sys

file_name = sys.argv[1]

with open(file_name, encoding="utf-8") as file:
    data = json.load(file)

outbounds = data.get("outbounds", [])
freedom_outbounds = [
    item for item in outbounds
    if item.get("protocol") == "freedom"
]

if not freedom_outbounds:
    sys.exit(1)

if all(
    item.get("settings", {}).get("domainStrategy") == "UseIPv4"
    for item in freedom_outbounds
):
    sys.exit(0)

sys.exit(1)
PY
}

show_ipv6_status() {
    echo
    echo "========== 系统 IPv6 检测 =========="

    local global_addresses
    local default_route

    global_addresses="$(
        ip -6 addr show scope global 2>/dev/null || true
    )"

    default_route="$(
        ip -6 route show default 2>/dev/null || true
    )"

    if [[ -n "$global_addresses" ]]; then
        warn "系统存在全局 IPv6 地址："
        echo "$global_addresses" | sed -n '1,20p'
    else
        ok "未发现全局 IPv6 地址。"
    fi

    if [[ -n "$default_route" ]]; then
        warn "系统存在 IPv6 默认路由："
        echo "$default_route"
    else
        ok "未发现 IPv6 默认路由。"
    fi
}

show_xray_service_status() {
    echo
    echo "========== Xray 服务状态 =========="

    if systemctl is-active --quiet "$XRAY_SERVICE"; then
        ok "$XRAY_SERVICE 服务状态：active"
    else
        warn "$XRAY_SERVICE 服务不是 active 状态。"
    fi

    systemctl --no-pager --full status "$XRAY_SERVICE" 2>/dev/null |
        sed -n '1,18p' || true
}

detect_config_status() {
    local dns_strategy

    echo
    echo "========== Xray 配置检测 =========="

    echo
    echo "--- DNS 配置 ---"
    echo "文件：$DNS_FILE"

    dns_strategy="$(json_value "$DNS_FILE" "dns.queryStrategy")"
    echo "dns.queryStrategy = $dns_strategy"

    echo
    echo "--- freedom 出站配置 ---"
    echo "文件：$OUTBOUND_FILE"
    get_freedom_strategies

    echo
    echo "--- IPv4 策略结论 ---"

    if [[ "$dns_strategy" == "UseIPv4" ]] &&
       all_freedom_outbounds_use_ipv4; then
        ok "Xray DNS 和 freedom 出站均已强制使用 IPv4。"
    elif all_freedom_outbounds_use_ipv4; then
        warn "freedom 出站已使用 IPv4，但 DNS 未设置 queryStrategy=UseIPv4。"
    else
        warn "Xray 尚未完整强制使用 IPv4。"
    fi
}

detect_all() {
    detect_config_status
    show_ipv6_status
    show_xray_service_status
}

create_backup() {
    local timestamp
    local backup_dir

    timestamp="$(date +%Y%m%d-%H%M%S)"
    backup_dir="$BACKUP_ROOT/$timestamp"

    mkdir -p "$backup_dir"

    cp -a "$DNS_FILE" "$backup_dir/11_dns.json"
    cp -a "$OUTBOUND_FILE" "$backup_dir/z_direct_outbound.json"

    printf '%s\n' "$backup_dir" > "$BACKUP_ROOT/LATEST"

    ok "配置备份完成：$backup_dir"
}

restore_backup_files() {
    local backup_dir="$1"

    [[ -f "$backup_dir/11_dns.json" ]] ||
        die "备份缺少 11_dns.json：$backup_dir"

    [[ -f "$backup_dir/z_direct_outbound.json" ]] ||
        die "备份缺少 z_direct_outbound.json：$backup_dir"

    cp -a "$backup_dir/11_dns.json" "$DNS_FILE"
    cp -a "$backup_dir/z_direct_outbound.json" "$OUTBOUND_FILE"
}

validate_xray_config() {
    info "正在验证 Xray 配置……"

    if "$XRAY_BIN" run -test -confdir "$CONFIG_DIR"; then
        ok "Xray 配置验证通过。"
        return 0
    fi

    fail "Xray 配置验证失败。"
    return 1
}

restart_xray() {
    info "正在重启 $XRAY_SERVICE 服务……"

    systemctl restart "$XRAY_SERVICE"
    sleep 1

    if systemctl is-active --quiet "$XRAY_SERVICE"; then
        ok "$XRAY_SERVICE 已正常运行。"
        return 0
    fi

    fail "$XRAY_SERVICE 重启后未正常运行。"
    echo
    echo "建议查看日志："
    echo "journalctl --no-pager -u $XRAY_SERVICE -n 80"
    return 1
}

apply_ipv4_policy() {
    local answer

    echo
    warn "此操作将修改以下文件："
    echo "  $DNS_FILE"
    echo "  $OUTBOUND_FILE"
    echo
    warn "操作完成后可以选择重启 Xray。"

    read -r -p "输入 YES 确认修改: " answer

    if [[ "$answer" != "YES" ]]; then
        echo "操作已取消。"
        return 0
    fi

    create_backup

    python3 - "$DNS_FILE" "$OUTBOUND_FILE" <<'PY'
import json
import sys

dns_file = sys.argv[1]
outbound_file = sys.argv[2]

# 修改 DNS 配置
with open(dns_file, encoding="utf-8") as file:
    dns_data = json.load(file)

dns_data.setdefault("dns", {})
dns_data["dns"]["queryStrategy"] = "UseIPv4"

with open(dns_file, "w", encoding="utf-8") as file:
    json.dump(dns_data, file, ensure_ascii=False, indent=2)
    file.write("\n")

# 修改所有 freedom 出站
with open(outbound_file, encoding="utf-8") as file:
    outbound_data = json.load(file)

outbounds = outbound_data.setdefault("outbounds", [])

freedom_count = 0

for outbound in outbounds:
    if outbound.get("protocol") == "freedom":
        outbound.setdefault("settings", {})
        outbound["settings"]["domainStrategy"] = "UseIPv4"
        freedom_count += 1

if freedom_count == 0:
    raise RuntimeError("没有找到 protocol=freedom 的出站。")

with open(outbound_file, "w", encoding="utf-8") as file:
    json.dump(outbound_data, file, ensure_ascii=False, indent=2)
    file.write("\n")

print(f"已修改 {freedom_count} 个 freedom 出站。")
PY

    if ! validate_xray_config; then
        fail "正在自动恢复修改前的配置……"
        local latest_backup
        latest_backup="$(cat "$BACKUP_ROOT/LATEST")"
        restore_backup_files "$latest_backup"
        die "配置未生效，已恢复原配置。"
    fi

    ok "IPv4 策略配置已写入。"

    echo
    read -r -p "是否现在重启 Xray？输入 YES 确认: " answer

    if [[ "$answer" == "YES" ]]; then
        if restart_xray; then
            detect_all
        fi
    else
        warn "配置已经修改，但 Xray 尚未重启。"
        warn "稍后请执行 systemctl restart $XRAY_SERVICE"
    fi
}

restore_latest_backup() {
    local answer
    local latest_backup

    if [[ ! -f "$BACKUP_ROOT/LATEST" ]]; then
        die "没有找到可恢复的备份。"
    fi

    latest_backup="$(cat "$BACKUP_ROOT/LATEST")"

    [[ -d "$latest_backup" ]] ||
        die "备份目录不存在：$latest_backup"

    echo
    echo "准备恢复备份："
    echo "$latest_backup"
    echo

    read -r -p "输入 YES 确认恢复: " answer

    if [[ "$answer" != "YES" ]]; then
        echo "恢复操作已取消。"
        return 0
    fi

    restore_backup_files "$latest_backup"

    if ! validate_xray_config; then
        die "恢复后的配置验证失败，请手动检查。"
    fi

    ok "配置已恢复到脚本修改前的状态。"

    echo
    read -r -p "是否现在重启 Xray？输入 YES 确认: " answer

    if [[ "$answer" == "YES" ]]; then
        if restart_xray; then
            detect_all
        fi
    else
        warn "配置已恢复，但 Xray 尚未重启。"
    fi
}

list_backups() {
    echo
    echo "========== 配置备份列表 =========="

    if [[ ! -d "$BACKUP_ROOT" ]]; then
        echo "暂无备份。"
        return 0
    fi

    local count=0
    local directory

    while IFS= read -r directory; do
        count=$((count + 1))
        echo "$directory"
    done < <(
        find "$BACKUP_ROOT" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            -printf '%f\n' 2>/dev/null |
            sort
    )

    if [[ "$count" -eq 0 ]]; then
        echo "暂无备份。"
    fi

    if [[ -f "$BACKUP_ROOT/LATEST" ]]; then
        echo
        echo "最近一次备份："
        cat "$BACKUP_ROOT/LATEST"
    fi
}

show_menu() {
    while true; do
        echo
        echo "=========================================="
        echo "       Xray IPv4 出站策略管理工具"
        echo "=========================================="
        echo "配置目录：$CONFIG_DIR"
        echo "Xray 程序：$XRAY_BIN"
        echo "Xray 服务：$XRAY_SERVICE"
        echo
        echo "1) 检测当前状态"
        echo "2) 强制 Xray 使用 IPv4 出站"
        echo "3) 恢复脚本修改前的配置"
        echo "4) 查看配置备份"
        echo "0) 退出"
        echo

        local choice
        read -r -p "请选择操作 [0-4]: " choice

        case "$choice" in
            1)
                detect_all
                ;;
            2)
                apply_ipv4_policy
                ;;
            3)
                restore_latest_backup
                ;;
            4)
                list_backups
                ;;
            0)
                echo "已退出。"
                exit 0
                ;;
            *)
                warn "无效选项，请输入 0、1、2、3 或 4。"
                ;;
        esac
    done
}

main() {
    initialize
    show_menu
}

main "$@"
