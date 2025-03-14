#!/bin/bash
# =========================================
# 作者: jinqians
# 日期: 2025年3月
# 网站：jinqians.com
# 描述: 这个脚本用于安装和管理 ShadowTLS V3
# =========================================

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 安装目录和配置文件
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/shadowtls"
SERVICE_FILE="/etc/systemd/system/shadowtls.service"

# 检查是否以 root 权限运行
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请以 root 权限运行此脚本${RESET}"
        exit 1
    fi
}

# 安装必要的工具
install_requirements() {
    apt update
    apt install -y wget curl jq
}

# 获取最新版本
get_latest_version() {
    latest_version=$(curl -s "https://api.github.com/repos/ihciah/shadow-tls/releases/latest" | jq -r .tag_name)
    if [ -z "$latest_version" ]; then
        echo -e "${RED}获取最新版本失败${RESET}"
        exit 1
    fi
    echo "$latest_version"
}

# 检查 SS 是否已安装
check_ssrust() {
    if [ ! -f "/usr/local/bin/ss-rust" ]; then
        return 1
    fi
    return 0
}

# 检查 Snell 是否已安装
check_snell() {
    if [ ! -f "/usr/local/bin/snell-server" ]; then
        return 1
    fi
    return 0
}

# 获取 SS 端口
get_ssrust_port() {
    local ssrust_conf="/etc/ss-rust/config.json"
    if [ ! -f "$ssrust_conf" ]; then
        return 1
    fi
    local port=$(jq -r '.server_port' "$ssrust_conf" 2>/dev/null)
    echo "$port"
}

# 获取 SS 密码
get_ssrust_password() {
    local ssrust_conf="/etc/ss-rust/config.json"
    if [ ! -f "$ssrust_conf" ]; then
        return 1
    fi
    local password=$(jq -r '.password' "$ssrust_conf" 2>/dev/null)
    echo "$password"
}

# 获取 SS 加密方式
get_ssrust_method() {
    local ssrust_conf="/etc/ss-rust/config.json"
    if [ ! -f "$ssrust_conf" ]; then
        return 1
    fi
    local method=$(jq -r '.method' "$ssrust_conf" 2>/dev/null)
    echo "$method"
}

# 获取 Snell 端口
get_snell_port() {
    local snell_conf="/etc/snell/snell-server.conf"
    if [ ! -f "$snell_conf" ]; then
        return 1
    fi
    local port=$(grep -E '^listen' "$snell_conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p' | sed 's/^0*//')
    echo "$port"
}

# 获取 Snell PSK
get_snell_psk() {
    local snell_conf="/etc/snell/snell-server.conf"
    if [ ! -f "$snell_conf" ]; then
        return 1
    fi
    local psk=$(grep -E '^psk' "$snell_conf" | sed 's/psk = //')
    echo "$psk"
}

# 获取 Snell 版本
get_snell_version() {
    if ! command -v snell-server &> /dev/null; then
        return 1
    fi
    local version=$(snell-server --version 2>&1 | grep -oP 'v\K\d+')
    if [ -z "$version" ]; then
        # 如果无法获取版本，则默认为 4
        echo "4"
    else
        echo "$version"
    fi
}

# 获取服务器IP
get_server_ip() {
    local ipv4
    local ipv6
    
    # 获取IPv4地址
    ipv4=$(curl -s -4 ip.sb 2>/dev/null)
    
    # 获取IPv6地址
    ipv6=$(curl -s -6 ip.sb 2>/dev/null)
    
    # 判断IP类型并返回
    if [ -n "$ipv4" ] && [ -n "$ipv6" ]; then
        # 双栈，优先返回IPv4
        echo "$ipv4"
    elif [ -n "$ipv4" ]; then
        # 仅IPv4
        echo "$ipv4"
    elif [ -n "$ipv6" ]; then
        # 仅IPv6
        echo "$ipv6"
    else
        echo -e "${RED}无法获取服务器 IP${RESET}"
        return 1
    fi
    
    return 0
}

# 检查 shadow-tls 命令格式
check_shadowtls_command() {
    local help_output
    help_output=$($INSTALL_DIR/shadow-tls --help 2>&1)
    echo -e "${YELLOW}Shadow-tls 帮助信息：${RESET}"
    echo "$help_output"
    return 0
}

# 生成安全的Base64编码
urlsafe_base64() {
    date=$(echo -n "$1"|base64|sed ':a;N;s/\n/ /g;ta'|sed 's/ //g;s/=//g;s/+/-/g;s/\//_/g')
    echo -e "${date}"
}

# 生成随机端口
generate_random_port() {
    local min_port=10000
    local max_port=65535
    echo $(shuf -i ${min_port}-${max_port} -n 1)
}

# 生成 SS 链接和配置
generate_ss_links() {
    local server_ip=$1
    local listen_port=$2
    local ssrust_password=$3
    local ssrust_method=$4
    local stls_password=$5
    local stls_sni=$6
    local backend_port=$7
    
    echo -e "\n${YELLOW}=== 服务器配置 ===${RESET}"
    echo -e "服务器IP：${server_ip}"
    echo -e "\nShadowsocks 配置："
    echo -e "  - 端口：${backend_port}"
    echo -e "  - 加密方式：${ssrust_method}"
    echo -e "  - 密码：${ssrust_password}"
    echo -e "\nShadowTLS 配置："
    echo -e "  - 端口：${listen_port}"
    echo -e "  - 密码：${stls_password}"
    echo -e "  - SNI：${stls_sni}"
    echo -e "  - 版本：3"
    
    # 生成 SS + ShadowTLS 合并链接
    local userinfo=$(echo -n "${ssrust_method}:${ssrust_password}" | base64 | tr -d '\n')
    local shadow_tls_config="{\"version\":\"3\",\"password\":\"${stls_password}\",\"host\":\"${stls_sni}\",\"port\":\"${listen_port}\",\"address\":\"${server_ip}\"}"
    local shadow_tls_base64=$(echo -n "${shadow_tls_config}" | base64 | tr -d '\n')
    local ss_url="ss://${userinfo}@${server_ip}:${backend_port}?shadow-tls=${shadow_tls_base64}#SS-${server_ip}"
    
    echo -e "\n${YELLOW}=== Surge 配置 ===${RESET}"
    echo -e "SS-${server_ip} = ss, ${server_ip}, ${listen_port}, encrypt-method=${ssrust_method}, password=${ssrust_password}, shadow-tls-password=${stls_password}, shadow-tls-sni=${stls_sni}, shadow-tls-version=3, udp-relay=true"
    
    echo -e "\n${YELLOW}=== Shadowrocket 配置说明 ===${RESET}"
    echo -e "1. 添加 Shadowsocks 节点："
    echo -e "   - 类型：Shadowsocks"
    echo -e "   - 地址：${server_ip}"
    echo -e "   - 端口：${backend_port}"
    echo -e "   - 加密方法：${ssrust_method}"
    echo -e "   - 密码：${ssrust_password}"
    
    echo -e "\n2. 添加 ShadowTLS 节点："
    echo -e "   - 类型：ShadowTLS"
    echo -e "   - 地址：${server_ip}"
    echo -e "   - 端口：${listen_port}"
    echo -e "   - 密码：${stls_password}"
    echo -e "   - SNI：${stls_sni}"
    echo -e "   - 版本：3"

    echo -e "\n${YELLOW}=== Shadowrocket分享链接 ===${RESET}"
    echo -e "${GREEN}SS + ShadowTLS 链接：${RESET}${ss_url}"
    
    echo -e "\n${YELLOW}=== Shadowrocket二维码 ===${RESET}"
    qrencode -t UTF8 "${ss_url}"
    
    echo -e "\n${YELLOW}=== Clash Meta 配置 ===${RESET}"
    echo -e "proxies:"
    echo -e "  - name: SS-${server_ip}"
    echo -e "    type: ss"
    echo -e "    server: ${server_ip}"
    echo -e "    port: ${listen_port}"
    echo -e "    cipher: ${ssrust_method}"
    echo -e "    password: \"${ssrust_password}\""
    echo -e "    plugin: shadow-tls"
    echo -e "    plugin-opts:"
    echo -e "      host: \"${stls_sni}\""
    echo -e "      password: \"${stls_password}\""
    echo -e "      version: 3"
}

# 生成 Snell 链接和配置
generate_snell_links() {
    local server_ip=$1
    local listen_port=$2
    local snell_psk=$3
    local stls_password=$4
    local stls_sni=$5
    local backend_port=$6
    
    # 获取 Snell 版本
    local snell_version=$(get_snell_version)
    
    echo -e "\n${YELLOW}=== 服务器配置 ===${RESET}"
    echo -e "服务器IP：${server_ip}"
    echo -e "\nSnell 配置："
    echo -e "  - 端口：${backend_port}"
    echo -e "  - PSK：${snell_psk}"
    echo -e "  - 版本：${snell_version}"
    echo -e "\nShadowTLS 配置："
    echo -e "  - 端口：${listen_port}"
    echo -e "  - 密码：${stls_password}"
    echo -e "  - SNI：${stls_sni}"
    echo -e "  - 版本：3"
    
    echo -e "\n${YELLOW}=== Surge 配置 ===${RESET}"
    echo -e "Snell + ShadowTLS = snell, ${server_ip}, ${listen_port}, psk = ${snell_psk}, version = ${snell_version}, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_sni}, shadow-tls-version = 3"
}

# 安装 ShadowTLS
install_shadowtls() {
    echo -e "${CYAN}正在安装 ShadowTLS...${RESET}"
    
    # 检测已安装的协议
    local has_ss=false
    local has_snell=false
    
    if check_ssrust; then
        has_ss=true
        echo -e "${GREEN}检测到已安装 Shadowsocks Rust${RESET}"
    fi
    
    if check_snell; then
        has_snell=true
        echo -e "${GREEN}检测到已安装 Snell${RESET}"
    fi
    
    if ! $has_ss && ! $has_snell; then
        echo -e "${RED}未检测到 Shadowsocks Rust 或 Snell，请先安装其中一个${RESET}"
        return 1
    fi
    
    # 获取系统架构
    arch=$(uname -m)
    case $arch in
        x86_64)
            arch="x86_64-unknown-linux-musl"
            ;;
        aarch64)
            arch="aarch64-unknown-linux-musl"
            ;;
        *)
            echo -e "${RED}不支持的系统架构: $arch${RESET}"
            exit 1
            ;;
    esac
    
    # 获取最新版本
    version=$(get_latest_version)
    
    # 下载并安装
    download_url="https://github.com/ihciah/shadow-tls/releases/download/${version}/shadow-tls-${arch}"
    
    # 如果服务正在运行，先停止
    if systemctl is-active shadowtls-ss >/dev/null 2>&1; then
        systemctl stop shadowtls-ss
        sleep 2
    fi
    if systemctl is-active shadowtls-snell >/dev/null 2>&1; then
        systemctl stop shadowtls-snell
        sleep 2
    fi
    
    # 使用临时文件下载
    wget "$download_url" -O "/tmp/shadow-tls.tmp"
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载 ShadowTLS 失败${RESET}"
        exit 1
    fi
    
    # 移动到最终位置并设置权限
    mv "/tmp/shadow-tls.tmp" "$INSTALL_DIR/shadow-tls"
    chmod +x "$INSTALL_DIR/shadow-tls"
    
    # 生成随机密码
    password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
    
    # 获取用户输入
    read -rp "请输入 ShadowTLS 监听端口 (1-65535): " listen_port
    read -rp "请输入 TLS 伪装域名 (直接回车默认为 www.microsoft.com): " tls_domain
    
    # 如果用户未输入域名，使用默认值
    if [ -z "$tls_domain" ]; then
        tls_domain="www.microsoft.com"
    fi
    
    # 为 SS 创建服务文件
    if $has_ss; then
        local ss_port=$(get_ssrust_port)
        cat > "/etc/systemd/system/shadowtls-ss.service" << EOF
[Unit]
Description=Shadow-TLS Server Service for Shadowsocks
Documentation=man:sstls-server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/shadow-tls --v3 server --listen ::0:${listen_port} --server 127.0.0.1:${ss_port} --tls ${tls_domain} --password ${password}
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=shadow-tls-ss

[Install]
WantedBy=multi-user.target
EOF
    fi
    
    # 为 Snell 创建服务文件
    if $has_snell; then
        local snell_port=$(get_snell_port)
        cat > "/etc/systemd/system/shadowtls-snell.service" << EOF
[Unit]
Description=Shadow-TLS Server Service for Snell
Documentation=man:sstls-server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/shadow-tls --v3 server --listen ::0:$((listen_port + 1)) --server 127.0.0.1:${snell_port} --tls ${tls_domain} --password ${password}
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=shadow-tls-snell

[Install]
WantedBy=multi-user.target
EOF
    fi
    
    # 重新加载 systemd 配置
    systemctl daemon-reload
    
    # 启动服务
    if $has_ss; then
        systemctl start shadowtls-ss
        systemctl enable shadowtls-ss
    fi
    if $has_snell; then
        systemctl start shadowtls-snell
        systemctl enable shadowtls-snell
    fi
    
    # 获取服务器IP
    local server_ip=$(get_server_ip)
    
    # 验证服务状态
    if $has_ss && ! systemctl is-active shadowtls-ss >/dev/null 2>&1; then
        echo -e "${RED}ShadowTLS SS 服务未能正常运行${RESET}"
        echo -e "${YELLOW}服务状态：${RESET}"
        systemctl status shadowtls-ss
        echo -e "${YELLOW}日志内容：${RESET}"
        journalctl -u shadowtls-ss -n 20
        return 1
    fi
    
    if $has_snell && ! systemctl is-active shadowtls-snell >/dev/null 2>&1; then
        echo -e "${RED}ShadowTLS Snell 服务未能正常运行${RESET}"
        echo -e "${YELLOW}服务状态：${RESET}"
        systemctl status shadowtls-snell
        echo -e "${YELLOW}日志内容：${RESET}"
        journalctl -u shadowtls-snell -n 20
        return 1
    fi
    
    echo -e "\n${GREEN}=== ShadowTLS 安装成功 ===${RESET}"
    
    # 显示所有可用的配置
    if $has_ss; then
        local ssrust_password=$(get_ssrust_password)
        local ssrust_method=$(get_ssrust_method)
        local ss_port=$(get_ssrust_port)
        generate_ss_links "${server_ip}" "${listen_port}" "${ssrust_password}" "${ssrust_method}" "${password}" "${tls_domain}" "${ss_port}"
    fi
    
    if $has_snell; then
        local snell_psk=$(get_snell_psk)
        local snell_port=$(get_snell_port)
        generate_snell_links "${server_ip}" "$((listen_port + 1))" "${snell_psk}" "${password}" "${tls_domain}" "${snell_port}"
    fi

    echo -e "\n${GREEN}服务已启动并设置为开机自启${RESET}"
}

# 卸载 ShadowTLS
uninstall_shadowtls() {
    echo -e "${CYAN}正在卸载 ShadowTLS...${RESET}"
    
    # 停止并禁用服务
    systemctl stop shadowtls-ss 2>/dev/null
    systemctl stop shadowtls-snell 2>/dev/null
    systemctl disable shadowtls-ss 2>/dev/null
    systemctl disable shadowtls-snell 2>/dev/null
    
    # 删除服务文件
    rm -f "/etc/systemd/system/shadowtls-ss.service"
    rm -f "/etc/systemd/system/shadowtls-snell.service"
    
    # 删除二进制文件
    rm -f "$INSTALL_DIR/shadow-tls"
    
    # 重新加载 systemd 配置
    systemctl daemon-reload
    
    echo -e "${GREEN}ShadowTLS 已成功卸载${RESET}"
}

# 查看配置
view_config() {
    echo -e "${CYAN}正在获取配置信息...${RESET}"
    
    # 检查服务是否安装
    if [ ! -f "/etc/systemd/system/shadowtls-ss.service" ] && [ ! -f "/etc/systemd/system/shadowtls-snell.service" ]; then
        echo -e "${RED}ShadowTLS 未安装${RESET}"
        return 1
    fi
    
    # 获取服务器IP
    local server_ip=$(get_server_ip)
    
    # 从服务文件中提取配置信息
    local ss_listen_port=""
    local snell_listen_port=""
    local tls_domain=""
    local password=""
    
    if [ -f "/etc/systemd/system/shadowtls-ss.service" ]; then
        ss_listen_port=$(grep -oP '(?<=--listen ::0:)\d+' "/etc/systemd/system/shadowtls-ss.service")
        tls_domain=$(grep -oP '(?<=--tls )[^ ]+' "/etc/systemd/system/shadowtls-ss.service")
        password=$(grep -oP '(?<=--password )[^ ]+' "/etc/systemd/system/shadowtls-ss.service")
    fi
    
    if [ -f "/etc/systemd/system/shadowtls-snell.service" ]; then
        snell_listen_port=$(grep -oP '(?<=--listen ::0:)\d+' "/etc/systemd/system/shadowtls-snell.service")
        if [ -z "$tls_domain" ]; then
            tls_domain=$(grep -oP '(?<=--tls )[^ ]+' "/etc/systemd/system/shadowtls-snell.service")
        fi
        if [ -z "$password" ]; then
            password=$(grep -oP '(?<=--password )[^ ]+' "/etc/systemd/system/shadowtls-snell.service")
        fi
    fi
    
    # 检查 SS 是否安装并获取配置
    if check_ssrust; then
        echo -e "\n${YELLOW}=== Shadowsocks + ShadowTLS 配置 ===${RESET}"
        local ss_port=$(get_ssrust_port)
        local ssrust_password=$(get_ssrust_password)
        local ssrust_method=$(get_ssrust_method)
        generate_ss_links "${server_ip}" "${ss_listen_port}" "${ssrust_password}" "${ssrust_method}" "${password}" "${tls_domain}" "${ss_port}"
    fi
    
    # 检查 Snell 是否安装并获取配置
    if check_snell; then
        echo -e "\n${YELLOW}=== Snell + ShadowTLS 配置 ===${RESET}"
        local snell_port=$(get_snell_port)
        local snell_psk=$(get_snell_psk)
        generate_snell_links "${server_ip}" "${snell_listen_port}" "${snell_psk}" "${password}" "${tls_domain}" "${snell_port}"
    fi
    
    if ! check_ssrust && ! check_snell; then
        echo -e "\n${YELLOW}未检测到 Shadowsocks 或 Snell 安装${RESET}"
    fi
    
    # 显示 ShadowTLS 服务状态
    echo -e "\n${YELLOW}=== ShadowTLS 服务状态 ===${RESET}"
    if [ -f "/etc/systemd/system/shadowtls-ss.service" ]; then
        echo -e "\n${YELLOW}SS 服务状态：${RESET}"
        systemctl status shadowtls-ss --no-pager
    fi
    if [ -f "/etc/systemd/system/shadowtls-snell.service" ]; then
        echo -e "\n${YELLOW}Snell 服务状态：${RESET}"
        systemctl status shadowtls-snell --no-pager
    fi
}

# 主菜单
main_menu() {
    while true; do
        echo -e "\n${CYAN}ShadowTLS 管理菜单${RESET}"
        echo -e "${YELLOW}1. 安装 ShadowTLS${RESET}"
        echo -e "${YELLOW}2. 卸载 ShadowTLS${RESET}"
        echo -e "${YELLOW}3. 查看配置${RESET}"
        echo -e "${YELLOW}4. 返回上级菜单${RESET}"
        echo -e "${YELLOW}0. 退出${RESET}"
        
        read -rp "请选择操作 [0-4]: " choice
        
        case "$choice" in
            1)
                install_shadowtls
                ;;
            2)
                uninstall_shadowtls
                ;;
            3)
                view_config
                ;;
            4)
                return 0
                ;;
            0)
                exit 0
                ;;
            *)
                echo -e "${RED}无效的选择${RESET}"
                ;;
        esac
    done
}

# 检查root权限
check_root

# 如果直接运行此脚本，则显示主菜单
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_menu
fi
