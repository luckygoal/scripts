#!/usr/bin/env bash
# =========================================================
# GOST v3 (go-gost/gost) 一键管理与探针防御部署脚本 (全自动自适应版)
# 支持 HTTP / HTTPS(TLS) 代理、证书/域名自动提取、本地伪装站挂载
# 兼容 Debian / Ubuntu / CentOS / AlmaLinux / RockyLinux
# =========================================================

set -e

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
SKYBLUE="\033[0;36m"
PLAIN="\033[0m"

CONFIG_DIR="/etc/gost"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
ENV_FILE="${CONFIG_DIR}/config.env"
DEFAULT_SITE_DIR="/var/www/gost_site"
SERVICE_FILE="/etc/systemd/system/gost.service"
BIN_PATH="/usr/local/bin/gost-bin"
SCRIPT_PATH="/usr/local/bin/gost.sh"
LINK_PATH="/usr/local/bin/gost"

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[错误]${PLAIN} 必须使用 root 权限运行此脚本！"
        exit 1
    fi
}

check_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) GOST_ARCH="linux_amd64" ;;
        aarch64|arm64) GOST_ARCH="linux_arm64" ;;
        *) echo -e "${RED}[错误]${PLAIN} 暂不支持当前架构: ${arch}"; exit 1 ;;
    esac
}

install_dependencies() {
    echo -e "${SKYBLUE}[信息]${PLAIN} 正在检查并安装必要依赖..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y
        apt-get install -y curl wget tar lsof procps openssl ca-certificates jq
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl wget tar lsof procps-ng openssl ca-certificates jq
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget tar lsof procps-ng openssl ca-certificates jq
    fi
}

get_public_ip() {
    local ip
    ip=$(curl -s4m 4 https://api.ipify.org || curl -s4m 4 https://ip.sb || curl -s4m 4 https://ifconfig.me || echo "127.0.0.1")
    echo "$ip"
}

get_latest_version() {
    local tag
    tag=$(curl -s https://api.github.com/repos/go-gost/gost/releases/latest | jq -r .tag_name 2>/dev/null || echo "")
    if [[ -z "$tag" || "$tag" == "null" ]]; then
        tag="v3.3.0"
    fi
    echo "$tag"
}

install_gost_bin() {
    check_arch
    local tag version_num tar_file download_url
    tag=$(get_latest_version)
    version_num="${tag#v}"
    tar_file="gost_${version_num}_${GOST_ARCH}.tar.gz"
    download_url="https://github.com/go-gost/gost/releases/download/${tag}/${tar_file}"

    echo -e "${SKYBLUE}[信息]${PLAIN} 正在从 GitHub 下载 GOST v3 (${tag})..."
    local temp_dir
    temp_dir=$(mktemp -d)
    cd "${temp_dir}"

    if ! wget --no-check-certificate -q -O gost.tar.gz "${download_url}"; then
        echo -e "${YELLOW}[提示]${PLAIN} 直连下载失败，尝试使用加速代理..."
        wget --no-check-certificate -q -O gost.tar.gz "https://ghproxy.net/${download_url}" || {
            echo -e "${RED}[错误]${PLAIN} GOST 二进制包下载失败，请检查网络！"
            rm -rf "${temp_dir}"
            exit 1
        }
    fi

    tar -zxf gost.tar.gz
    if [[ ! -f "gost" ]]; then
        echo -e "${RED}[错误]${PLAIN} 解压失败，未找到 gost 二进制！"
        rm -rf "${temp_dir}"
        exit 1
    fi

    chmod +x gost
    mv gost "${BIN_PATH}"
    rm -rf "${temp_dir}"
    echo -e "${GREEN}[成功]${PLAIN} GOST 二进制安装完成: $(${BIN_PATH} -V)"
}

detect_existing_certs() {
    DETECTED_CERT=""
    DETECTED_KEY=""
    for f in /etc/v2ray-agent/tls/*.crt; do
        if [[ -f "$f" ]]; then
            DETECTED_CERT="$f"
            local base="${f%.crt}"
            if [[ -f "${base}.key" ]]; then
                DETECTED_KEY="${base}.key"
            fi
            return
        fi
    done
    for d in /etc/letsencrypt/live/*; do
        if [[ -f "$d/fullchain.pem" && -f "$d/privkey.pem" ]]; then
            DETECTED_CERT="$d/fullchain.pem"
            DETECTED_KEY="$d/privkey.pem"
            return
        fi
    done
    for d in /root/.acme.sh/*_ecc; do
        if [[ -f "$d/fullchain.cer" && -f "$d/*.key" ]]; then
            DETECTED_CERT="$d/fullchain.cer"
            DETECTED_KEY=$(ls "$d"/*.key | head -n 1)
            return
        fi
    done
}

detect_existing_domain() {
    DETECTED_DOMAIN=""
    if [[ -n "$DETECTED_CERT" && -f "$DETECTED_CERT" ]]; then
        # 优先使用 openssl 解析证书 CN (Common Name)
        local cn
        cn=$(openssl x509 -noout -subject -in "$DETECTED_CERT" 2>/dev/null | sed -n 's/.*CN[ =]*//p' | awk '{print $1}' | tr -d '/' || echo "")
        if [[ -n "$cn" && "$cn" != "localhost" ]]; then
            DETECTED_DOMAIN="$cn"
            return
        fi
        # 备选：从证书文件名提取
        local base
        base=$(basename "$DETECTED_CERT")
        base="${base%.crt}"
        base="${base%.cer}"
        base="${base%.fullchain.pem}"
        base="${base%.pem}"
        if [[ -n "$base" && "$base" != "fullchain" && "$base" != "cert" ]]; then
            DETECTED_DOMAIN="$base"
            return
        fi
    fi
    # 若无法从证书获取，尝试获取系统 hostname
    local h
    h=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "")
    if [[ "$h" == *"."* && "$h" != "localhost.localdomain" ]]; then
        DETECTED_DOMAIN="$h"
    else
        DETECTED_DOMAIN="example.com"
    fi
}

detect_existing_site_file() {
    DETECTED_SITE_FILE=""
    if [[ -f "/usr/share/nginx/html/index.html" ]]; then
        DETECTED_SITE_FILE="/usr/share/nginx/html/index.html"
    elif [[ -f "/var/www/html/index.html" ]]; then
        DETECTED_SITE_FILE="/var/www/html/index.html"
    else
        DETECTED_SITE_FILE="${DEFAULT_SITE_DIR}/index.html"
    fi
}

create_default_camouflage_site() {
    local domain="$1"
    mkdir -p "${DEFAULT_SITE_DIR}"
    cat << EOF > "${DEFAULT_SITE_DIR}/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome to ${domain:-Default Site}</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; background: #0f172a; color: #f8fafc; display: flex; align-items: center; justify-content: center; min-height: 100vh; padding: 20px; }
        .card { max-width: 540px; width: 100%; background: #1e293b; border: 1px solid #334155; border-radius: 16px; padding: 40px; text-align: center; box-shadow: 0 10px 25px -5px rgba(0,0,0,0.3); }
        .icon { width: 56px; height: 56px; margin: 0 auto 20px; background: rgba(34, 197, 94, 0.15); border-radius: 50%; display: flex; align-items: center; justify-content: center; color: #22c55e; font-size: 28px; }
        h1 { font-size: 24px; font-weight: 600; margin-bottom: 12px; color: #ffffff; }
        p { font-size: 14px; line-height: 1.6; color: #94a3b8; margin-bottom: 24px; }
        .badge { display: inline-block; padding: 6px 14px; background: #0f172a; border: 1px solid #334155; border-radius: 9999px; font-size: 12px; color: #38bdf8; letter-spacing: 0.5px; }
    </style>
</head>
<body>
    <div class="card">
        <div class="icon">✓</div>
        <h1>Service Active</h1>
        <p>The web application gateway is running smoothly and all systems are fully operational.</p>
        <span class="badge">Host: ${domain:-example.com}</span>
    </div>
</body>
</html>
EOF
}

generate_gost_config() {
    local proto="$1"
    local port="$2"
    local u="$3"
    local p="$4"
    local probe="$5"
    local site_file="$6"
    local cert_file="$7"
    local key_file="$8"
    local domain="$9"

    mkdir -p "${CONFIG_DIR}"

    if [[ -d "$site_file" ]]; then
        site_file="${site_file}/index.html"
    fi

    local probe_yaml=""
    if [[ "$probe" == "on" && -n "$site_file" && -f "$site_file" ]]; then
        probe_yaml="metadata:
        probeResist: \"file:${site_file}\""
    fi

    if [[ "$proto" == "https" && -n "$cert_file" && -n "$key_file" ]]; then
        cat << EOF > "${CONFIG_FILE}"
services:
  - name: gost-proxy
    addr: ":${port}"
    handler:
      type: http
      auth:
        username: "${u}"
        password: "${p}"
      ${probe_yaml}
    listener:
      type: tls
      tls:
        certFile: "${cert_file}"
        keyFile: "${key_file}"
EOF
    else
        cat << EOF > "${CONFIG_FILE}"
services:
  - name: gost-proxy
    addr: ":${port}"
    handler:
      type: http
      auth:
        username: "${u}"
        password: "${p}"
      ${probe_yaml}
    listener:
      type: tcp
EOF
    fi

    cat << EOF > "${ENV_FILE}"
PROTO="${proto}"
PORT="${port}"
USER="${u}"
PASS="${p}"
PROBE_RESISTANT="${probe}"
SITE_FILE="${site_file}"
CERT_FILE="${cert_file}"
KEY_FILE="${key_file}"
CAMOUFLAGE_DOMAIN="${domain}"
EOF
}

setup_systemd() {
    cat << EOF > "${SERVICE_FILE}"
[Unit]
Description=GOST v3 Proxy Service
After=network.target network-online.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=${BIN_PATH} -C ${CONFIG_FILE}
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gost.service >/dev/null 2>&1
    systemctl restart gost.service
    sleep 1
}

show_proxy_info() {
    if [[ ! -f "${ENV_FILE}" ]]; then
        echo -e "${RED}[错误]${PLAIN} 未检测到已保存的配置信息！"
        return 1
    fi

    source "${ENV_FILE}"
    local server_ip
    server_ip=$(get_public_ip)
    local host_str="${CAMOUFLAGE_DOMAIN:-$server_ip}"

    echo -e ""
    echo -e "${GREEN}=========================================${PLAIN}"
    echo -e "${GREEN}          GOST v3 代理连接信息           ${PLAIN}"
    echo -e "${GREEN}=========================================${PLAIN}"
    echo -e "  ${SKYBLUE}服务器 IP  :${PLAIN} ${server_ip}"
    echo -e "  ${SKYBLUE}代理端口   :${PLAIN} ${PORT}"
    echo -e "  ${SKYBLUE}传输协议   :${PLAIN} $([[ "$PROTO" == "https" ]] && echo -e "${GREEN}HTTPS (TLS 加密)${PLAIN}" || echo -e "HTTP (标准明文)")"
    echo -e "  ${SKYBLUE}认证用户   :${PLAIN} ${USER}"
    echo -e "  ${SKYBLUE}认证密码   :${PLAIN} ${PASS}"
    echo -e "  ${SKYBLUE}探针防御   :${PLAIN} $([[ "$PROBE_RESISTANT" == "on" ]] && echo -e "${GREEN}已开启 (未认证直接展示伪装网站)${PLAIN}" || echo -e "${YELLOW}已关闭 (未认证返回 HTTP 407)${PLAIN}")"
    echo -e "  ${SKYBLUE}伪装网页   :${PLAIN} ${SITE_FILE}"
    if [[ "$PROTO" == "https" ]]; then
        echo -e "  ${SKYBLUE}SSL 证书   :${PLAIN} ${CERT_FILE}"
    fi
    echo -e "${GREEN}=========================================${PLAIN}"
    echo -e "  ${SKYBLUE}标准代理 URL 格式:${PLAIN}"
    if [[ "$PROTO" == "https" ]]; then
        echo -e "  https://${USER}:${PASS}@${host_str}:${PORT}"
    else
        echo -e "  http://${USER}:${PASS}@${server_ip}:${PORT}"
    fi
    echo -e "${GREEN}=========================================${PLAIN}"
    echo -e "  ${SKYBLUE}终端连通性测试命令:${PLAIN}"
    if [[ "$PROTO" == "https" ]]; then
        echo -e "  curl -x https://${USER}:${PASS}@${host_str}:${PORT} https://api.ipify.org"
    else
        echo -e "  curl -x http://${USER}:${PASS}@${server_ip}:${PORT} https://api.ipify.org"
    fi
    echo -e "${GREEN}=========================================${PLAIN}"
    echo -e ""
}

test_proxy() {
    if [[ ! -f "${ENV_FILE}" ]]; then
        echo -e "${RED}[错误]${PLAIN} 未找到配置文件，请先安装 GOST！"
        return 1
    fi

    source "${ENV_FILE}"
    echo -e "${SKYBLUE}[测试]${PLAIN} 正在通过本地代理测试外网访问..."

    local proxy_url=""
    if [[ "$PROTO" == "https" ]]; then
        local host_str="${CAMOUFLAGE_DOMAIN:-127.0.0.1}"
        proxy_url="https://${USER}:${PASS}@${host_str}:${PORT}"
    else
        proxy_url="http://${USER}:${PASS}@127.0.0.1:${PORT}"
    fi

    local res
    res=$(curl -s4m 6 -x "${proxy_url}" https://api.ipify.org 2>/dev/null || echo "")
    if [[ -z "$res" && "$PROTO" == "https" ]]; then
        res=$(curl -k -s4m 6 -x "https://${USER}:${PASS}@127.0.0.1:${PORT}" https://api.ipify.org 2>/dev/null || echo "")
    fi

    if [[ -n "$res" ]]; then
        echo -e "${GREEN}[成功]${PLAIN} 代理测试成功！获取到的公网出口 IP 为: ${GREEN}${res}${PLAIN}"
    else
        echo -e "${RED}[失败]${PLAIN} 代理连接测试失败，请检查端口或日志！"
    fi
}

toggle_probe() {
    local target_state="$1"
    if [[ ! -f "${ENV_FILE}" ]]; then
        echo -e "${RED}[错误]${PLAIN} 请先安装 GOST 再调整探针防御！"
        return 1
    fi

    source "${ENV_FILE}"

    if [[ "$target_state" == "on" ]]; then
        generate_gost_config "${PROTO}" "${PORT}" "${USER}" "${PASS}" "on" "${SITE_FILE}" "${CERT_FILE}" "${KEY_FILE}" "${CAMOUFLAGE_DOMAIN}"
        systemctl restart gost.service
        sleep 1
        echo -e "${GREEN}[成功]${PLAIN} Probe Resistant 已开启！未认证探测将直接展示伪装网站。"
    elif [[ "$target_state" == "off" ]]; then
        generate_gost_config "${PROTO}" "${PORT}" "${USER}" "${PASS}" "off" "${SITE_FILE}" "${CERT_FILE}" "${KEY_FILE}" "${CAMOUFLAGE_DOMAIN}"
        systemctl restart gost.service
        sleep 1
        echo -e "${YELLOW}[成功]${PLAIN} Probe Resistant 已关闭！未认证探测将返回标准 HTTP 407 Proxy Authentication Required。"
    fi
}

interactive_install() {
    echo -e ""
    echo -e "${SKYBLUE}=========================================${PLAIN}"
    echo -e "${SKYBLUE}     GOST v3 代理配置向导 (智能检测版)    ${PLAIN}"
    echo -e "${SKYBLUE}=========================================${PLAIN}"

    detect_existing_certs
    detect_existing_domain
    detect_existing_site_file

    echo -e "请选择代理协议类型:"
    echo -e "  1) HTTP 代理 (明文传输，客户端配置最简单)"
    echo -e "  2) HTTPS 代理 (TLS 加密传输，配合证书伪装性极高)"
    read -r -p "请选择 [默认: 1]: " proto_choice
    local proto="http"
    if [[ "$proto_choice" == "2" ]]; then
        proto="https"
    fi

    local cert_file=""
    local key_file=""
    if [[ "$proto" == "https" ]]; then
        if [[ -n "$DETECTED_CERT" ]]; then
            echo -e "${GREEN}[检测到系统已有 SSL 证书]${PLAIN} 证书: ${DETECTED_CERT}"
        fi
        read -r -p "请输入 SSL 证书 CRT/PEM 完整路径 [默认: ${DETECTED_CERT}]: " input_cert
        cert_file="${input_cert:-$DETECTED_CERT}"

        read -r -p "请输入 SSL 证书 KEY 完整私钥路径 [默认: ${DETECTED_KEY}]: " input_key
        key_file="${input_key:-$DETECTED_KEY}"

        if [[ ! -f "$cert_file" || ! -f "$key_file" ]]; then
            echo -e "${RED}[错误]${PLAIN} 证书或私钥文件不存在，请检查路径！"
            return 1
        fi
    fi

    local default_port="8080"
    if [[ "$proto" == "https" ]]; then
        default_port="8443"
    fi
    read -r -p "请输入 GOST 代理监听端口 [默认: ${default_port}]: " input_port
    local port="${input_port:-$default_port}"

    local default_user="admin"
    read -r -p "请输入代理认证用户名 [默认: ${default_user}]: " input_user
    local user="${input_user:-$default_user}"

    local default_pass
    default_pass=$(openssl rand -base64 12 | tr -dc "a-zA-Z0-9" | head -c 12)
    read -r -p "请输入代理认证密码 [默认随机: ${default_pass}]: " input_pass
    local pass="${input_pass:-$default_pass}"

    local default_domain="${DETECTED_DOMAIN:-example.com}"
    read -r -p "请输入伪装站点域名 [默认: ${default_domain}]: " input_domain
    local domain="${input_domain:-$default_domain}"

    echo -e ""
    if [[ -n "$DETECTED_SITE_FILE" ]]; then
        echo -e "${GREEN}[检测到系统已有伪装网站]${PLAIN}: ${DETECTED_SITE_FILE}"
    fi
    read -r -p "请输入伪装站点 HTML 文件路径 [默认: ${DETECTED_SITE_FILE}]: " input_site
    local site_file="${input_site:-$DETECTED_SITE_FILE}"

    if [[ -d "$site_file" ]]; then
        site_file="${site_file}/index.html"
    fi

    if [[ ! -f "$site_file" ]]; then
        echo -e "${YELLOW}[提示]${PLAIN} 文件不存在，脚本将为您自动创建默认伪装网页..."
        create_default_camouflage_site "${domain}"
        site_file="${DEFAULT_SITE_DIR}/index.html"
    fi

    echo -e ""
    echo -e "请选择探针防御模式 (Probe Resistant):"
    echo -e "  1) 开启探针防御: 未认证访问时直接展示伪装网站 (${site_file}) [推荐]"
    echo -e "  2) 关闭探针防御: 未认证访问时返回 HTTP 407 Proxy Authentication Required"
    read -r -p "请选择 [默认: 1]: " probe_choice
    local probe="on"
    if [[ "$probe_choice" == "2" ]]; then
        probe="off"
    fi

    echo -e ""
    echo -e "${SKYBLUE}[1/4] 检查系统依赖...${PLAIN}"
    install_dependencies

    echo -e "${SKYBLUE}[2/4] 安装 GOST v3 核心组件...${PLAIN}"
    install_gost_bin

    echo -e "${SKYBLUE}[3/4] 写入配置文件...${PLAIN}"
    generate_gost_config "${proto}" "${port}" "${user}" "${pass}" "${probe}" "${site_file}" "${cert_file}" "${key_file}" "${domain}"

    echo -e "${SKYBLUE}[4/4] 配置并启动 Systemd 服务...${PLAIN}"
    setup_systemd

    if [[ -f "${SCRIPT_PATH}" ]]; then
        chmod +x "${SCRIPT_PATH}"
        ln -sf "${SCRIPT_PATH}" "${LINK_PATH}"
    fi

    echo -e "${GREEN}[完成] GOST v3 部署成功并已开启自启！${PLAIN}"
    show_proxy_info
    test_proxy
}

uninstall_gost() {
    echo -e "${YELLOW}[警告]${PLAIN} 正在彻底卸载 GOST 服务及所有配置..."
    systemctl stop gost.service >/dev/null 2>&1 || true
    systemctl disable gost.service >/dev/null 2>&1 || true
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload
    rm -f "${BIN_PATH}"
    rm -rf "${CONFIG_DIR}"
    echo -e "${GREEN}[成功]${PLAIN} GOST 已彻底卸载清理完成！"
}

get_status() {
    if systemctl is-active --quiet gost.service; then
        echo -e "${GREEN}● 运行中${PLAIN}"
    else
        echo -e "${RED}○ 未运行${PLAIN}"
    fi
}

main_menu() {
    while true; do
        clear
        echo -e "${GREEN}=========================================${PLAIN}"
        echo -e "${GREEN}     GOST v3 (go-gost/gost) 一键管理     ${PLAIN}"
        echo -e "${GREEN}=========================================${PLAIN}"
        echo -e " ${GREEN}1)${PLAIN} 安装 / 重新配置 GOST"
        echo -e " ${GREEN}2)${PLAIN} 启动 GOST 服务"
        echo -e " ${GREEN}3)${PLAIN} 停止 GOST 服务"
        echo -e " ${GREEN}4)${PLAIN} 重启 GOST 服务"
        echo -e " ${GREEN}5)${PLAIN} 查看 GOST 运行状态与连接信息"
        echo -e " ${GREEN}6)${PLAIN} 查看 GOST 运行日志"
        echo -e " ${GREEN}7)${PLAIN} 开启 Probe Resistant (防探测/展示伪装网站)"
        echo -e " ${GREEN}8)${PLAIN} 关闭 Probe Resistant (未认证返回 HTTP 407)"
        echo -e " ${GREEN}9)${PLAIN} 测试代理连通性"
        echo -e " ${GREEN}10)${PLAIN} 彻底卸载 GOST"
        echo -e " ${GREEN}0)${PLAIN} 退出脚本"
        echo -e "${GREEN}=========================================${PLAIN}"
        echo -e " 当前运行状态: $(get_status)"
        echo -e "${GREEN}=========================================${PLAIN}"
        read -r -p "请输入选项 [0-10]: " choice

        case "$choice" in
            1) interactive_install; break ;;
            2) systemctl start gost.service; echo -e "${GREEN}服务已启动！${PLAIN}"; sleep 1 ;;
            3) systemctl stop gost.service; echo -e "${YELLOW}服务已停止！${PLAIN}"; sleep 1 ;;
            4) systemctl restart gost.service; echo -e "${GREEN}服务已重启！${PLAIN}"; sleep 1 ;;
            5) show_proxy_info; read -r -p "按回车键继续..." ;;
            6) journalctl -u gost.service -n 50 --no-pager; read -r -p "按回车键继续..." ;;
            7) toggle_probe "on"; read -r -p "按回车键继续..." ;;
            8) toggle_probe "off"; read -r -p "按回车键继续..." ;;
            9) test_proxy; read -r -p "按回车键继续..." ;;
            10) uninstall_gost; break ;;
            0) exit 0 ;;
            *) echo -e "${RED}输入错误，请输入有效选项！${PLAIN}"; sleep 1 ;;
        esac
    done
}

check_root

case "$1" in
    start)
        systemctl start gost.service
        echo -e "${GREEN}[成功] GOST 服务已启动${PLAIN}"
        ;;
    stop)
        systemctl stop gost.service
        echo -e "${YELLOW}[成功] GOST 服务已停止${PLAIN}"
        ;;
    restart)
        systemctl restart gost.service
        echo -e "${GREEN}[成功] GOST 服务已重启${PLAIN}"
        ;;
    status|info)
        show_proxy_info
        ;;
    test)
        test_proxy
        ;;
    log)
        journalctl -u gost.service -n 50 --no-pager
        ;;
    probe)
        if [[ "$2" == "on" || "$2" == "off" ]]; then
            toggle_probe "$2"
        else
            echo "用法: gost probe on|off"
        fi
        ;;
    uninstall)
        uninstall_gost
        ;;
    install)
        interactive_install
        ;;
    *)
        main_menu
        ;;
esac
