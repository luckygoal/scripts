#!/usr/bin/env bash
#
# xray-force-ipv4.sh
#
# 将 Xray freedom 直连出站策略设置为 UseIPv4。
# 本脚本不会关闭系统 IPv6，不会修改 IPv6 路由。
#
# 默认适用于 v2ray-agent 安装的 Xray：
#   Xray:   /etc/v2ray-agent/xray/xray
#   配置:   /etc/v2ray-agent/xray/conf
#   服务:   xray.service
#
# 用法：
#   sudo ./xray-force-ipv4.sh
#   sudo ./xray-force-ipv4.sh --check
#   sudo ./xray-force-ipv4.sh --restore /path/to/backup.json
#
# 可通过环境变量适配其他安装路径：
#   XRAY_BIN=/usr/local/bin/xray
#   CONF_DIR=/usr/local/etc/xray
#   DIRECT_CONF=/usr/local/etc/xray/z_direct_outbound.json
#   SERVICE=xray.service
#

set -Eeuo pipefail

XRAY_BIN="${XRAY_BIN:-/etc/v2ray-agent/xray/xray}"
CONF_DIR="${CONF_DIR:-/etc/v2ray-agent/xray/conf}"
DIRECT_CONF="${DIRECT_CONF:-${CONF_DIR}/z_direct_outbound.json}"
SERVICE="${SERVICE:-xray.service}"

BACKUP_FILE=""

info() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

error() {
    printf '[ERROR] %s\n' "$*" >&2
}

usage() {
    cat <<EOF
用法：

  $0
      将 Xray freedom 直连出站设置为 UseIPv4

  $0 --check
      只检查配置，不修改文件，不重启服务

  $0 --restore BACKUP_FILE
      从备份文件恢复配置并重启 Xray

环境变量：

  XRAY_BIN
      Xray 程序路径
      默认：${XRAY_BIN}

  CONF_DIR
      Xray 配置目录
      默认：${CONF_DIR}

  DIRECT_CONF
      freedom 直连出站配置文件
      默认：${DIRECT_CONF}

  SERVICE
      systemd 服务名
      默认：${SERVICE}
EOF
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "请使用 root 或 sudo 执行此脚本"
        exit 1
    fi
}

require_commands() {
    local cmd

    for cmd in python3 systemctl cp date; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            error "缺少必要命令：$cmd"
            exit 1
        fi
    done
}

check_files() {
    if [ ! -x "$XRAY_BIN" ]; then
        error "找不到或无法执行 Xray：$XRAY_BIN"
        exit 1
    fi

    if [ ! -d "$CONF_DIR" ]; then
        error "找不到配置目录：$CONF_DIR"
        exit 1
    fi

    if [ ! -f "$DIRECT_CONF" ]; then
        error "找不到直连配置文件：$DIRECT_CONF"
        exit 1
    fi
}

get_strategy() {
    python3 - "$DIRECT_CONF" <<'PY'
import json
import sys

path = sys.argv[1]

with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

found = False

for outbound in data.get("outbounds", []):
    if isinstance(outbound, dict) and outbound.get("protocol") == "freedom":
        found = True
        settings = outbound.get("settings", {})
        print(settings.get("domainStrategy", "<未设置>"))

if not found:
    print("<未找到 freedom 出站>")
PY
}

show_strategy() {
    info "当前 freedom 出站策略：$(get_strategy)"
}

validate_config() {
    info "正在校验 Xray 配置……"

    if ! "$XRAY_BIN" run -test -confdir "$CONF_DIR"; then
        error "Xray 配置校验失败"
        return 1
    fi

    info "Xray 配置校验通过"
}

modify_config() {
    python3 - "$DIRECT_CONF" <<'PY'
import json
import sys

path = sys.argv[1]

with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

outbounds = data.get("outbounds")

if not isinstance(outbounds, list):
    raise SystemExit("outbounds 不是数组")

found = False
changed = False

for outbound in outbounds:
    if not isinstance(outbound, dict):
        continue

    if outbound.get("protocol") != "freedom":
        continue

    found = True
    settings = outbound.setdefault("settings", {})

    if not isinstance(settings, dict):
        raise SystemExit("freedom 出站的 settings 不是对象")

    if settings.get("domainStrategy") != "UseIPv4":
        settings["domainStrategy"] = "UseIPv4"
        changed = True

if not found:
    raise SystemExit("未找到 protocol 为 freedom 的出站")

if changed:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=4)
        f.write("\n")
    print("配置已修改为 UseIPv4")
else:
    print("配置已经是 UseIPv4，无需修改")
PY
}

restart_xray() {
    info "正在重启 Xray 服务：$SERVICE"

    systemctl restart "$SERVICE"
    sleep 2

    if systemctl is-active --quiet "$SERVICE"; then
        info "Xray 服务运行正常"
        systemctl --no-pager --full status "$SERVICE" | sed -n '1,16p'
        return 0
    fi

    error "Xray 服务重启失败"
    systemctl --no-pager --full status "$SERVICE" || true
    return 1
}

restore_backup() {
    local backup="$1"

    if [ ! -f "$backup" ]; then
        error "备份文件不存在：$backup"
        exit 1
    fi

    cp -a "$backup" "$DIRECT_CONF"
    info "已恢复配置：$backup"

    validate_config

    systemctl restart "$SERVICE"
    sleep 2

    if systemctl is-active --quiet "$SERVICE"; then
        info "恢复完成，Xray 服务运行正常"
    else
        error "恢复后 Xray 服务未正常运行"
        systemctl --no-pager --full status "$SERVICE" || true
        exit 1
    fi
}

rollback() {
    if [ -z "$BACKUP_FILE" ] || [ ! -f "$BACKUP_FILE" ]; then
        error "没有可用备份，无法自动恢复"
        return 1
    fi

    warn "正在自动恢复原配置：$BACKUP_FILE"
    cp -a "$BACKUP_FILE" "$DIRECT_CONF"

    if "$XRAY_BIN" run -test -confdir "$CONF_DIR" >/dev/null 2>&1; then
        systemctl restart "$SERVICE" || true
        sleep 2

        if systemctl is-active --quiet "$SERVICE"; then
            warn "原配置已恢复，Xray 服务运行正常"
            return 0
        fi
    fi

    error "自动恢复后 Xray 仍未正常运行"
    return 1
}

main() {
    case "${1:-}" in
        -h|--help)
            usage
            exit 0
            ;;

        --check)
            require_root
            require_commands
            check_files
            show_strategy
            validate_config
            info "检查完成，未修改任何配置"
            exit 0
            ;;

        --restore)
            require_root
            require_commands
            check_files

            if [ -z "${2:-}" ]; then
                error "--restore 后必须指定备份文件"
                usage
                exit 1
            fi

            restore_backup "$2"
            exit 0
            ;;

        "")
            ;;
            
        *)
            error "未知参数：$1"
            usage
            exit 1
            ;;
    esac

    require_root
    require_commands
    check_files

    show_strategy

    if [ "$(get_strategy)" = "UseIPv4" ]; then
        info "当前已经是 UseIPv4，无需修改"
        exit 0
    fi

    BACKUP_FILE="${DIRECT_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$DIRECT_CONF" "$BACKUP_FILE"
    info "配置备份已保存：$BACKUP_FILE"

    trap 'error "执行失败，正在尝试恢复配置"; rollback' ERR

    modify_config
    show_strategy
    validate_config
    restart_xray

    trap - ERR

    info "操作完成"
    info "Xray 直连出站现在使用 IPv4"
    info "系统 IPv6 未被禁用"
    info "备份文件：$BACKUP_FILE"
}

main "$@"
