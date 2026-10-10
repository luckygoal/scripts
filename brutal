#!/usr/bin/env bash
set -Eeuo pipefail

# TCP Brutal 交互式管理脚本
# 菜单：
#   1. 检查环境
#   2. 安装 TCP Brutal
#   3. 设置客户端 IP/速率并启动（同时启用开机恢复）
#   4. 停止当前规则（保留开机恢复设置）
#   5. 禁用开机恢复并停止规则
#   6. 查看运行状态
#
# 保存为文件后以 root 执行：
#   chmod 700 /root/brutal-manager.sh
#   /root/brutal-manager.sh

readonly MANAGER="/usr/local/sbin/brutal-manager"
readonly CONFIG="/etc/tcp-brutal-manager.conf"
readonly UNIT="/etc/systemd/system/tcp-brutal-manager.service"
readonly INSTALLER_URL="https://tcp.hy2.sh/"

die() {
    echo "错误：$*" >&2
    exit 1
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "请以 root 运行。"
}

pause() {
    echo
    read -r -p "按 Enter 返回菜单……" _
}

read_os_id() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        printf '%s' "${ID:-unknown}"
    else
        printf 'unknown'
    fi
}

check_system() {
    echo "=== 系统与 Brutal 环境检查 ==="
    echo "系统：$(grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release 2>/dev/null | tr '\n' ' ' || true)"
    echo "内核：$(uname -r)"
    echo "架构：$(uname -m)"
    echo "默认拥塞控制：$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo 未知)"

    if [[ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]]; then
        echo "IPv4 可用拥塞控制：$(cat /proc/sys/net/ipv4/tcp_available_congestion_control)"
    fi

    if [[ -e "/lib/modules/$(uname -r)/build" ]]; then
        echo "当前内核 headers：已找到 /lib/modules/$(uname -r)/build"
    else
        echo "当前内核 headers：未找到 /lib/modules/$(uname -r)/build"
        echo "  官方安装器可能尝试安装对应 headers；云厂商定制内核不一定有匹配包。"
    fi

    if command -v dkms >/dev/null 2>&1; then
        echo "DKMS：$(dkms status 2>/dev/null | grep -i brutal || echo 未发现 Brutal DKMS 项)"
    else
        echo "DKMS：未安装"
    fi

    if command -v brutalctl >/dev/null 2>&1; then
        echo "brutalctl：$(command -v brutalctl)"
        brutalctl list 2>&1 || true
    else
        echo "brutalctl：未安装"
    fi

    if lsmod 2>/dev/null | grep -q '^brutal[[:space:]]'; then
        echo "内核模块：brutal 已加载"
    else
        echo "内核模块：当前未显示为已加载"
    fi

    if [[ -r /proc/net/tcp_brutal/rules ]]; then
        echo
        echo "内核规则："
        cat /proc/net/tcp_brutal/rules
    fi

    echo
    echo "Brutal 管理的路由（proto 233）："
    ip route show proto 233 2>/dev/null || true
    ip -6 route show proto 233 2>/dev/null || true

    if command -v systemctl >/dev/null 2>&1; then
        echo
        echo "管理服务："
        systemctl is-active tcp-brutal-manager.service 2>/dev/null || true
        echo "开机启用：$(systemctl is-enabled tcp-brutal-manager.service 2>/dev/null || echo 否)"
    fi

    if [[ -r "$CONFIG" ]]; then
        echo
        echo "当前保存的规则配置："
        sed -E 's/^(IP_CIDR|RATE_MBPS)=/\1=/' "$CONFIG"
    fi
}

install_brutal() {
    local os_id tmp answer

    os_id="$(read_os_id)"
    case "$os_id" in
        debian|ubuntu) ;;
        *) die "此脚本只允许在 Debian/Ubuntu 上调用官方安装器；检测到系统 ID：$os_id" ;;
    esac

    command -v curl >/dev/null 2>&1 || die "需要 curl。请先安装 curl 后重试。"

    echo "将从官方地址下载 TCP Brutal 安装器："
    echo "  $INSTALLER_URL"
    echo
    echo "注意：官方安装器可能安装系统依赖、DKMS 模块、brutalctl，并设置内核模块开机加载。"
    echo "当前内核 headers 不匹配或缺失时，安装可能失败。"
    read -r -p "现在下载并查看安装器？输入 yes 继续：" answer
    [[ "$answer" == "yes" ]] || { echo "已取消。"; return 0; }

    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' RETURN

    curl -fsSL "$INSTALLER_URL" -o "$tmp" || die "下载官方安装器失败。"

    echo
    echo "安装器 SHA-256："
    sha256sum "$tmp"
    echo
    echo "请先检查下载到的脚本。将打开 less；按 q 退出查看。"
    if command -v less >/dev/null 2>&1; then
        less "$tmp"
    else
        cat "$tmp"
    fi

    echo
    read -r -p "确认执行刚才下载的官方安装器？输入 INSTALL 执行：" answer
    [[ "$answer" == "INSTALL" ]] || { echo "已取消，未执行安装器。"; return 0; }

    bash "$tmp"
    echo
    echo "安装器已退出。请回到菜单运行“检查环境”确认模块和 brutalctl 状态。"
}

normalize_prefix() {
    local input="$1"

    command -v python3 >/dev/null 2>&1 || die "需要 python3 来校验 IP 地址。"

    python3 - "$input" <<'PY'
import ipaddress
import sys

value = sys.argv[1].strip()
try:
    if "/" in value:
        net = ipaddress.ip_network(value, strict=False)
    else:
        addr = ipaddress.ip_address(value)
        net = ipaddress.ip_network(
            f"{addr}/{32 if addr.version == 4 else 128}",
            strict=False
        )
    print(net.with_prefixlen)
except ValueError as exc:
    print(f"无效的 IP 地址或网段：{exc}", file=sys.stderr)
    sys.exit(1)
PY
}

install_manager_files() {
    local self_path

    self_path="$(readlink -f "$0" 2>/dev/null || true)"
    [[ -n "$self_path" && -f "$self_path" ]] ||
        die "请先把脚本保存为普通文件再运行，不能用 bash <(curl ...) 方式运行。"

    install -o root -g root -m 700 "$self_path" "$MANAGER"

    if [[ -e "$UNIT" ]] && ! grep -q 'Managed by brutal-manager' "$UNIT"; then
        die "$UNIT 已存在且不是本脚本创建的文件；为避免覆盖其他服务，已停止。"
    fi

    cat > "${UNIT}.tmp" <<'UNITFILE'
# Managed by brutal-manager
[Unit]
Description=TCP Brutal destination rule managed by brutal-manager
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/brutal-manager --apply
ExecStop=/usr/local/sbin/brutal-manager --remove

[Install]
WantedBy=multi-user.target
UNITFILE

    chmod 644 "${UNIT}.tmp"
    mv -f "${UNIT}.tmp" "$UNIT"
    systemctl daemon-reload
}

load_config() {
    [[ -r "$CONFIG" ]] || die "尚无配置文件，请先使用菜单设置 IP 和速率。"

    CONFIG_IP="$(sed -n 's/^IP_CIDR=//p' "$CONFIG" | head -n1)"
    CONFIG_RATE="$(sed -n 's/^RATE_MBPS=//p' "$CONFIG" | head -n1)"

    [[ -n "${CONFIG_IP:-}" && -n "${CONFIG_RATE:-}" ]] ||
        die "配置文件内容不完整：$CONFIG"
}

apply_rule() {
    require_root
    load_config

    command -v brutalctl >/dev/null 2>&1 ||
        die "未找到 brutalctl。请先从菜单安装 TCP Brutal。"

    modprobe brutal
    if [[ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]] &&
       ! grep -qw brutal /proc/sys/net/ipv4/tcp_available_congestion_control; then
        die "模块加载后仍未发现 Brutal 拥塞控制算法；未添加规则。"
    fi

    echo "正在添加规则：目标 $CONFIG_IP，总速率 $CONFIG_RATE Mbps"
    brutalctl add "$CONFIG_IP" "$CONFIG_RATE"

    echo
    echo "规则列表："
    brutalctl list
    echo
    echo "Brutal 管理的路由："
    ip route show proto 233 2>/dev/null || true
    ip -6 route show proto 233 2>/dev/null || true
}

remove_rule() {
    require_root
    load_config

    command -v brutalctl >/dev/null 2>&1 || {
        echo "未找到 brutalctl，无法删除规则。"
        exit 1
    }

    if [[ -r /proc/net/tcp_brutal/rules ]] &&
       grep -Fq "dst=$CONFIG_IP " /proc/net/tcp_brutal/rules; then
        echo "正在删除规则：$CONFIG_IP"
        brutalctl del "$CONFIG_IP"
    else
        echo "内核规则中没有发现 $CONFIG_IP，跳过删除。"
    fi

    echo "规则删除操作完成。"
    echo "注意：已建立的连接可能继续使用旧速率，直到连接关闭。"
}

write_config() {
    local prefix="$1"
    local rate="$2"
    local tmp

    tmp="$(mktemp /etc/tcp-brutal-manager.conf.XXXXXX)"
    {
        printf 'IP_CIDR=%s\n' "$prefix"
        printf 'RATE_MBPS=%s\n' "$rate"
    } > "$tmp"
    chown root:root "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$CONFIG"
}

configure_and_start() {
    local input prefix rate answer

    command -v systemctl >/dev/null 2>&1 || die "此系统未找到 systemctl。"

    input="${DEFAULT_CLIENT_IP:-116.232.32.221}"
    read -r -p "客户端公网 IP 或 CIDR [$input]：" answer
    [[ -n "$answer" ]] && input="$answer"
    prefix="$(normalize_prefix "$input")" || return 1

    rate="${DEFAULT_RATE_MBPS:-70}"
    read -r -p "目标总速率 Mbps [$rate]：" answer
    [[ -n "$answer" ]] && rate="$answer"

    [[ "$rate" =~ ^[1-9][0-9]*$ ]] ||
        die "速率必须是正整数，单位 Mbps。"

    if (( rate > 100 )); then
        echo "警告：你此前说明 VPS 上行是共享 100 Mbps。"
        echo "设置高于 100 Mbps 不会增加线路容量，可能引起丢包、重传或影响其他用户。"
        read -r -p "仍要继续？输入 yes 确认：" answer
        [[ "$answer" == "yes" ]] || { echo "已取消。"; return 0; }
    fi

    command -v brutalctl >/dev/null 2>&1 ||
        die "未找到 brutalctl；请先从菜单安装 TCP Brutal。"

    echo
    echo "即将配置："
    echo "  目标前缀：$prefix"
    echo "  总速率：  $rate Mbps"
    echo "  说明：    匹配此目标的多条连接共享该速率"
    echo "  持久化：  启用 systemd 开机恢复"
    read -r -p "确认配置并启动？输入 yes 继续：" answer
    [[ "$answer" == "yes" ]] || { echo "已取消。"; return 0; }

    # 如果旧服务正在运行，先用旧配置停掉旧规则，再保存新配置。
    if systemctl is-active --quiet tcp-brutal-manager.service 2>/dev/null; then
        echo "检测到管理服务正在运行，先停止旧规则……"
        systemctl stop tcp-brutal-manager.service
    fi

    install_manager_files
    write_config "$prefix" "$rate"

    systemctl enable --now tcp-brutal-manager.service
    echo
    echo "服务已启动，并已设置开机恢复。"
    echo "让客户端重新连接，使新连接匹配 Brutal 规则。"
    echo "注意：规则不会让已建立连接自动切换到 Brutal。"
}

stop_now() {
    if ! systemctl list-unit-files tcp-brutal-manager.service >/dev/null 2>&1; then
        echo "尚未安装管理服务。"
        return 0
    fi

    systemctl stop tcp-brutal-manager.service
    echo "当前规则已停止；开机启用状态保留，重启后会自动恢复。"
}

disable_and_stop() {
    local answer
    read -r -p "停止规则并取消开机恢复？输入 yes 确认：" answer
    [[ "$answer" == "yes" ]] || { echo "已取消。"; return 0; }

    systemctl disable --now tcp-brutal-manager.service
    echo "规则已停止，开机自动恢复已禁用。"
    echo "配置文件和 Brutal 内核模块仍保留。"
}

show_menu() {
    cat <<'MENU'

TCP Brutal 管理菜单
  1) 检查环境
  2) 安装 TCP Brutal（官方安装器）
  3) 设置客户端 IP/速率并启动（启用开机恢复）
  4) 停止当前规则（保留开机恢复设置）
  5) 禁用开机恢复并停止规则
  6) 查看详细状态
  0) 退出
MENU
}

main_menu() {
    require_root

    while true; do
        show_menu
        read -r -p "请选择：" choice
        case "$choice" in
            1) check_system; pause ;;
            2) install_brutal; pause ;;
            3) configure_and_start; pause ;;
            4) stop_now; pause ;;
            5) disable_and_stop; pause ;;
            6) systemctl status tcp-brutal-manager.service --no-pager 2>/dev/null || true
               check_system
               pause ;;
            0) exit 0 ;;
            *) echo "无效选项。" ;;
        esac
    done
}

case "${1:-}" in
    --apply) apply_rule ;;
    --remove) remove_rule ;;
    "") main_menu ;;
    *) echo "用法：$0 [--apply|--remove]" >&2; exit 2 ;;
esac
