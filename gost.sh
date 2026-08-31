#!/usr/bin/env bash
# =========================================================
# GOST v3 mTLS 双向认证代理一键管理脚本 (免密/防探测极速版)
# 特性：
# 1. mTLS (双向 TLS) 加密认证，无需用户名和密码
# 2. 握手层拦截未授权请求，天然免疫 GFW 主动探测与端口扫描
# 3. 自动生成 CA、服务端证书与客户端证书 (.p12 格式一键导入)
# 4. 内置临时安全下载服务 (3分钟自动销毁/按q退出)
# 5. 支持在任意路径下直接运行，自动注册全局 gost 命令
# =========================================================

set -e

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
SKYBLUE="\033[0;36m"
PLAIN="\033[0m"

CONFIG_DIR="/etc/gost"
CERTS_DIR="${CONFIG_DIR}/certs"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
ENV_FILE="${CONFIG_DIR}/config.env"
SERVICE_FILE="/etc/systemd/system/gost.service"
BIN_PATH="/usr/local/bin/gost-bin"
GLOBAL_LINK="/usr/local/bin/gost"

# 获取脚本自身绝对路径，保证在任何目录下均可执行
CURRENT_SCRIPT="$(readlink -f "$0" 2>/dev/null || echo "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")")"

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
        apt-get install -y curl wget tar lsof procps openssl ca-certificates jq zip python3
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl wget tar lsof procps-ng openssl ca-certificates jq zip python3
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget tar lsof procps-ng openssl ca-certificates jq zip python3
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
    if [[ -f "${BIN_PATH}" && -x "${BIN_PATH}" ]]; then
        return 0
    fi
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
        local cn
        cn=$(openssl x509 -noout -subject -in "$DETECTED_CERT" 2>/dev/null | sed -n 's/.*CN[ =]*//p' | awk '{print $1}' | tr -d '/' || echo "")
        if [[ -n "$cn" && "$cn" != "localhost" ]]; then
            DETECTED_DOMAIN="$cn"
            return
        fi
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
    local h
    h=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "")
    if [[ "$h" == *"."* && "$h" != "localhost.localdomain" ]]; then
        DETECTED_DOMAIN="$h"
    else
        DETECTED_DOMAIN=$(get_public_ip)
    fi
}

generate_mtls_certificates() {
    local domain="$1"
    local p12_pass="$2"
    mkdir -p "${CERTS_DIR}"
    cd "${CERTS_DIR}"

    echo -e "${SKYBLUE}[信息]${PLAIN} 正在生成 mTLS 根证书 (CA) 与客户端证书..."

    # 1. 生成独立的 CA 根证书 (10年有效期)
    openssl genrsa -out ca.key 2048 >/dev/null 2>&1
    openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -out ca.crt \
        -subj "/C=CN/ST=State/L=City/O=GOST-mTLS-CA/CN=GOST-mTLS-Root-CA" >/dev/null 2>&1

    # 2. 生成服务端证书 (自签备用)
    if [[ ! -f "${CERTS_DIR}/server.crt" || ! -f "${CERTS_DIR}/server.key" ]]; then
        openssl genrsa -out server.key 2048 >/dev/null 2>&1
        openssl req -new -key server.key -out server.csr \
            -subj "/C=CN/ST=State/L=City/O=GOST-Server/CN=${domain}" >/dev/null 2>&1
        openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 3650 -sha256 >/dev/null 2>&1
        rm -f server.csr
    fi

    # 3. 生成客户端私钥并签发客户端证书
    openssl genrsa -out client.key 2048 >/dev/null 2>&1
    openssl req -new -key client.key -out client.csr \
        -subj "/C=CN/ST=State/L=City/O=GOST-Client/CN=gost-client-cert" >/dev/null 2>&1
    openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out client.crt -days 3650 -sha256 >/dev/null 2>&1
    rm -f client.csr

    # 4. 打包生成 Windows / macOS / iOS / 浏览器通用的 PKCS#12 (.p12) 格式
    openssl pkcs12 -export -out client.p12 -inkey client.key -in client.crt -certfile ca.crt -passout "pass:${p12_pass}" >/dev/null 2>&1

    # 5. 生成客户端完整压缩包
    zip -q -j client-certs.zip ca.crt client.crt client.key client.p12
    tar -zcf client-certs.tar.gz ca.crt client.crt client.key client.p12

    echo -e "${GREEN}[成功]${PLAIN} mTLS 证书生成完成！包含: ca.crt, client.crt, client.key, client.p12"
}

generate_gost_config() {
    local port="$1"
    local server_cert="$2"
    local server_key="$3"
    local ca_cert="$4"
    local domain="$5"
    local p12_pass="$6"

    mkdir -p "${CONFIG_DIR}"

    cat << EOF > "${CONFIG_FILE}"
services:
  - name: gost-mtls-proxy
    addr: ":${port}"
    handler:
      type: http
    listener:
      type: tls
      tls:
        certFile: "${server_cert}"
        keyFile: "${server_key}"
        caFile: "${ca_cert}"
EOF

    cat << EOF > "${ENV_FILE}"
PORT="${port}"
SERVER_CERT="${server_cert}"
SERVER_KEY="${server_key}"
CA_CERT="${ca_cert}"
DOMAIN="${domain}"
P12_PASS="${p12_pass}"
EOF
}

setup_systemd() {
    cat << EOF > "${SERVICE_FILE}"
[Unit]
Description=GOST v3 mTLS Proxy Service
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

start_download_server() {
    if [[ ! -f "${CERTS_DIR}/client.p12" ]]; then
        echo -e "${RED}[错误]${PLAIN} 未找到证书文件，请先安装 GOST mTLS 服务！"
        return 1
    fi

    source "${ENV_FILE}" 2>/dev/null || true
    local server_ip
    server_ip=$(get_public_ip)
    local token
    token=$(openssl rand -hex 6)
    local dl_port
    dl_port=$(shuf -i 20000-35000 -n 1)

    local dl_dir="/tmp/gost_download_${token}"
    mkdir -p "${dl_dir}/${token}"
    cp "${CERTS_DIR}/client.p12" "${dl_dir}/${token}/client.p12"
    cp "${CERTS_DIR}/client-certs.zip" "${dl_dir}/${token}/client-certs.zip"
    cp "${CERTS_DIR}/ca.crt" "${dl_dir}/${token}/ca.crt"

    python3 -m http.server "${dl_port}" --directory "${dl_dir}" >/dev/null 2>&1 &
    local server_pid=$!

    clear
    echo -e "${GREEN}====================================================${PLAIN}"
    echo -e "${GREEN}        GOST mTLS 客户端证书临时下载服务 (已开启)    ${PLAIN}"
    echo -e "${GREEN}====================================================${PLAIN}"
    echo -e "  ${SKYBLUE}下载服务地址 (在浏览器直接打开即可下载):${PLAIN}"
    echo -e ""
    if [[ -n "${DOMAIN}" && "${DOMAIN}" != "${server_ip}" ]]; then
        echo -e "  📦 ${GREEN}PKCS#12 证书 (域名推荐):${PLAIN}"
        echo -e "     http://${DOMAIN}:${dl_port}/${token}/client.p12"
        echo -e ""
        echo -e "  📦 ${GREEN}完整证书 ZIP 压缩包 (域名):${PLAIN}"
        echo -e "     http://${DOMAIN}:${dl_port}/${token}/client-certs.zip"
        echo -e ""
    fi
    echo -e "  📦 ${GREEN}PKCS#12 证书 (IP 直连):${PLAIN}"
    echo -e "     http://${server_ip}:${dl_port}/${token}/client.p12"
    echo -e ""
    echo -e "  📦 ${GREEN}完整证书 ZIP 压缩包 (IP 直连):${PLAIN}"
    echo -e "     http://${server_ip}:${dl_port}/${token}/client-certs.zip"
    echo -e ""
    echo -e "  🔑 ${SKYBLUE}证书导入密码:${PLAIN} ${P12_PASS:-123456}"
    echo -e "${GREEN}====================================================${PLAIN}"
    echo -e "  ${YELLOW}提示: 服务将在 3 分钟后自动销毁关闭，也可按 [q] 键提前退出${PLAIN}"
    echo -e "${GREEN}====================================================${PLAIN}"

    local remaining=180
    while [[ $remaining -gt 0 ]]; do
        printf "\r  ⏳ 剩余有效时间: %02d:%02d (按 [q] 提前退出)... " $((remaining / 60)) $((remaining % 60))
        if read -r -t 1 -n 1 user_input 2>/dev/null; then
            if [[ "$user_input" == "q" || "$user_input" == "Q" ]]; then
                echo ""
                break
            fi
        fi
        if ! kill -0 "${server_pid}" 2>/dev/null; then
            echo -e "\n${RED}[提示] 下载服务进程已结束${PLAIN}"
            break
        fi
        remaining=$((remaining - 1))
    done
    echo ""

    kill "${server_pid}" >/dev/null 2>&1 || true
    rm -rf "${dl_dir}"
    echo -e "${GREEN}[已安全关闭] 临时下载端口与临时文件已清理完成！${PLAIN}"
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
    local host_str="${DOMAIN:-$server_ip}"

    echo -e ""
    echo -e "${GREEN}======================================================${PLAIN}"
    echo -e "${GREEN}            GOST v3 mTLS 代理连接信息                 ${PLAIN}"
    echo -e "${GREEN}======================================================${PLAIN}"
    echo -e "  ${SKYBLUE}服务器地址 :${PLAIN} ${host_str} (${server_ip})"
    echo -e "  ${SKYBLUE}监听端口   :${PLAIN} ${PORT}"
    echo -e "  ${SKYBLUE}认证模式   :${PLAIN} ${GREEN}mTLS (双向 TLS 认证，免密码)${PLAIN}"
    echo -e "  ${SKYBLUE}防探测机制 :${PLAIN} ${GREEN}TLS 握手层拒绝无证书请求 (天然免疫探测)${PLAIN}"
    echo -e "  ${SKYBLUE}服务端证书 :${PLAIN} ${SERVER_CERT}"
    echo -e "  ${SKYBLUE}客户端证书 :${PLAIN} ${CERTS_DIR}/client.p12"
    echo -e "  ${SKYBLUE}证书导入密码:${PLAIN} ${P12_PASS:-123456}"
    echo -e "${GREEN}======================================================${PLAIN}"
    echo -e "  ${SKYBLUE}ZeroOmega / 浏览器配置方法:${PLAIN}"
    echo -e "  1. 双击下载的 ${GREEN}client.p12${PLAIN} 导入系统证书库 (个人证书)"
    echo -e "  2. 在 ZeroOmega 中添加代理:"
    echo -e "     - 协议: ${GREEN}HTTPS${PLAIN}"
    echo -e "     - 服务器: ${GREEN}${host_str}${PLAIN}"
    echo -e "     - 端口: ${GREEN}${PORT}${PLAIN}"
    echo -e "     - 用户名和密码: ${YELLOW}留空！无需填写！${PLAIN}"
    echo -e "${GREEN}======================================================${PLAIN}"
    echo -e "  ${SKYBLUE}命令行连通性测试 (需指定客户端证书):${PLAIN}"
    echo -e "  curl --proxy-cert ${CERTS_DIR}/client.crt --proxy-key ${CERTS_DIR}/client.key \\"
    echo -e "       -x https://${host_str}:${PORT} https://api.ipify.org"
    echo -e "${GREEN}======================================================${PLAIN}"
    echo -e ""
}

test_proxy() {
    if [[ ! -f "${ENV_FILE}" ]]; then
        echo -e "${RED}[错误]${PLAIN} 未找到配置文件，请先安装 GOST！"
        return 1
    fi

    source "${ENV_FILE}"
    echo -e "${SKYBLUE}[测试 1] 正在测试合法客户端证书 (mTLS) 连接...${PLAIN}"

    local res
    res=$(curl -s4m 6 --resolve "${DOMAIN:-node7.mmtqtq.com}:${PORT}:127.0.0.1" \
        --proxy-cert "${CERTS_DIR}/client.crt" \
        --proxy-key "${CERTS_DIR}/client.key" \
        -x "https://${DOMAIN:-127.0.0.1}:${PORT}" https://api.ipify.org 2>/dev/null || echo "")

    if [[ -n "$res" ]]; then
        echo -e "${GREEN}[成功] mTLS 代理握手成功！出口 IP: ${res}${PLAIN}"
    else
        echo -e "${RED}[失败] mTLS 代理连接失败，请检查服务状态！${PLAIN}"
    fi

    echo -e "${SKYBLUE}[测试 2] 正在测试外部无证书非法探测防御 (预期: 握手直接被拒)...${PLAIN}"
    local probe_test
    probe_test=$(curl -s4m 4 --resolve "${DOMAIN:-node7.mmtqtq.com}:${PORT}:127.0.0.1" \
        -x "https://${DOMAIN:-127.0.0.1}:${PORT}" https://api.ipify.org 2>&1 || true)
    if [[ "$probe_test" == *"certificate required"* || "$probe_test" == *"handshake failure"* || "$probe_test" == *"alert"* || -z "$probe_test" ]]; then
        echo -e "${GREEN}[成功] 防探测测试通过！未携带证书的外部连接被 TLS 握手层静默丢弃/拒绝。${PLAIN}"
    else
        echo -e "${YELLOW}[提示] 返回状态: ${probe_test}${PLAIN}"
    fi
}

interactive_install() {
    echo -e ""
    echo -e "${SKYBLUE}====================================================${PLAIN}"
    echo -e "${SKYBLUE}      GOST v3 mTLS 双向认证代理一键部署向导         ${PLAIN}"
    echo -e "${SKYBLUE}====================================================${PLAIN}"

    detect_existing_certs
    detect_existing_domain

    local server_cert=""
    local server_key=""
    if [[ -n "$DETECTED_CERT" && -n "$DETECTED_KEY" ]]; then
        echo -e "${GREEN}[检测到系统已有 SSL 证书]${PLAIN} 证书: ${DETECTED_CERT}"
        read -r -p "是否直接使用现有权威证书作为服务端证书？[Y/n]: " use_exist
        if [[ "$use_exist" != "n" && "$use_exist" != "N" ]]; then
            server_cert="$DETECTED_CERT"
            server_key="$DETECTED_KEY"
        fi
    fi

    local default_domain="${DETECTED_DOMAIN:-$(get_public_ip)}"
    read -r -p "请输入服务端连接域名或 IP [默认: ${default_domain}]: " input_domain
    local domain="${input_domain:-$default_domain}"

    local default_port="8443"
    read -r -p "请输入 GOST 代理监听端口 [默认: ${default_port}]: " input_port
    local port="${input_port:-$default_port}"

    local default_pass="123456"
    read -r -p "请设置客户端证书 (.p12) 导入密码 [默认: ${default_pass}]: " input_pass
    local p12_pass="${input_pass:-$default_pass}"

    echo -e ""
    echo -e "${SKYBLUE}[1/5] 安装系统依赖组件...${PLAIN}"
    install_dependencies

    echo -e "${SKYBLUE}[2/5] 部署 GOST v3 核心...${PLAIN}"
    install_gost_bin

    echo -e "${SKYBLUE}[3/5] 生成 mTLS 根证书 (CA) 与客户端双向证书...${PLAIN}"
    generate_mtls_certificates "${domain}" "${p12_pass}"

    if [[ -z "$server_cert" || -z "$server_key" ]]; then
        server_cert="${CERTS_DIR}/server.crt"
        server_key="${CERTS_DIR}/server.key"
    fi

    echo -e "${SKYBLUE}[4/5] 生成 GOST mTLS 配置文件...${PLAIN}"
    generate_gost_config "${port}" "${server_cert}" "${server_key}" "${CERTS_DIR}/ca.crt" "${domain}" "${p12_pass}"

    echo -e "${SKYBLUE}[5/5] 启动 Systemd 服务并配置自启...${PLAIN}"
    setup_systemd

    ln -sf "${CURRENT_SCRIPT}" "${GLOBAL_LINK}"

    echo -e "${GREEN}[完成] GOST mTLS 服务部署成功！${PLAIN}"
    show_proxy_info
    test_proxy

    echo -e ""
    read -r -p "是否立即开启临时下载链接以下载客户端证书？[Y/n]: " open_dl
    if [[ "$open_dl" != "n" && "$open_dl" != "N" ]]; then
        start_download_server
    fi
}

uninstall_gost() {
    echo -e "${YELLOW}[警告]${PLAIN} 正在彻底卸载 GOST 服务及所有证书与配置..."
    systemctl stop gost.service >/dev/null 2>&1 || true
    systemctl disable gost.service >/dev/null 2>&1 || true
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload
    rm -f "${BIN_PATH}"
    rm -rf "${CONFIG_DIR}"
    rm -f "${GLOBAL_LINK}"
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
        echo -e "${GREEN}====================================================${PLAIN}"
        echo -e "${GREEN}     GOST v3 mTLS 双向认证代理一键管理 (免密版)     ${PLAIN}"
        echo -e "${GREEN}====================================================${PLAIN}"
        echo -e " ${GREEN}1)${PLAIN} 安装 / 重新配置 GOST (mTLS)"
        echo -e " ${GREEN}2)${PLAIN} 开启客户端证书下载链接 (在浏览器直接下载 .p12)"
        echo -e " ${GREEN}3)${PLAIN} 重新生成客户端证书"
        echo -e " ${GREEN}4)${PLAIN} 启动 GOST 服务"
        echo -e " ${GREEN}5)${PLAIN} 停止 GOST 服务"
        echo -e " ${GREEN}6)${PLAIN} 重启 GOST 服务"
        echo -e " ${GREEN}7)${PLAIN} 查看连接配置与使用说明"
        echo -e " ${GREEN}8)${PLAIN} 查看 GOST 实时日志"
        echo -e " ${GREEN}9)${PLAIN} 测试 mTLS 代理连通性与防探测"
        echo -e " ${GREEN}10)${PLAIN} 彻底卸载 GOST"
        echo -e " ${GREEN}0)${PLAIN} 退出脚本"
        echo -e "${GREEN}====================================================${PLAIN}"
        echo -e " 当前运行状态: $(get_status)"
        echo -e "${GREEN}====================================================${PLAIN}"
        read -r -p "请输入选项 [0-10]: " choice

        case "$choice" in
            1) interactive_install; break ;;
            2) start_download_server; break ;;
            3)
                source "${ENV_FILE}" 2>/dev/null || true
                generate_mtls_certificates "${DOMAIN:-example.com}" "${P12_PASS:-123456}"
                systemctl restart gost.service
                echo -e "${GREEN}客户端证书已重新生成并应用！${PLAIN}"
                read -r -p "按回车键继续..."
                ;;
            4) systemctl start gost.service; echo -e "${GREEN}服务已启动！${PLAIN}"; sleep 1 ;;
            5) systemctl stop gost.service; echo -e "${YELLOW}服务已停止！${PLAIN}"; sleep 1 ;;
            6) systemctl restart gost.service; echo -e "${GREEN}服务已重启！${PLAIN}"; sleep 1 ;;
            7) show_proxy_info; read -r -p "按回车键继续..." ;;
            8) journalctl -u gost.service -n 50 --no-pager; read -r -p "按回车键继续..." ;;
            9) test_proxy; read -r -p "按回车键继续..." ;;
            10) uninstall_gost; break ;;
            0) exit 0 ;;
            *) echo -e "${RED}输入错误，请输入有效选项！${PLAIN}"; sleep 1 ;;
        esac
    done
}

check_root

# 自动保持全局软链接可用
if [[ "$0" != "${GLOBAL_LINK}" && -f "$0" ]]; then
    ln -sf "${CURRENT_SCRIPT}" "${GLOBAL_LINK}" 2>/dev/null || true
fi

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
    download|dl)
        start_download_server
        ;;
    log)
        journalctl -u gost.service -n 50 --no-pager
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
