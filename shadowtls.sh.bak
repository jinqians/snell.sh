#!/bin/bash
# =========================================
# 作者: jinqians
# 日期: 2024年11月
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

# 检查 Snell 是否已安装
check_snell() {
    if ! command -v snell-server &> /dev/null; then
        echo -e "${RED}未检测到 Snell V4，请先安装 Snell${RESET}"
        return 1
    fi
    return 0
}

# 获取 Snell 端口
get_snell_port() {
    local snell_conf="/etc/snell/snell-server.conf"
    if [ ! -f "$snell_conf" ]; then
        echo -e "${RED}Snell 配置文件不存在${RESET}"
        return 1
    fi
    
    # 获取端口并去掉前导零
    local snell_port=$(grep -E '^listen' "$snell_conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p' | sed 's/^0*//')
    if [ -z "$snell_port" ]; then
        echo -e "${RED}无法读取 Snell 端口配置${RESET}"
        return 1
    fi
    
    echo "$snell_port"
    return 0
}

# 获取 Snell PSK
get_snell_psk() {
    if [ ! -f "/etc/snell/snell-server.conf" ]; then
        echo -e "${RED}未找到 Snell 配置文件${RESET}"
        return 1
    fi
    
    local snell_psk=$(grep "psk" /etc/snell/snell-server.conf | cut -d'=' -f2 | tr -d ' ')
    if [ -z "$snell_psk" ]; then
        echo -e "${RED}无法读取 Snell PSK 配置${RESET}"
        return 1
    fi
    
    echo "$snell_psk"
    return 0
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

# 安装 ShadowTLS
install_shadowtls() {
    echo -e "${CYAN}正在安装 ShadowTLS...${RESET}"
    
    # 检查命令格式
    check_shadowtls_command
    
    # 检查 Snell 是否已安装
    if ! check_snell; then
        echo -e "${YELLOW}请先安装 Snell V4 再安装 ShadowTLS${RESET}"
        return 1
    fi
    
    # 获取 Snell 端口
    local snell_port=$(get_snell_port)
    if [ $? -ne 0 ]; then
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
    wget "$download_url" -O "$INSTALL_DIR/shadow-tls"
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载 ShadowTLS 失败${RESET}"
        exit 1
    fi
    
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
    
    # 获取服务器IP和Snell PSK
    local server_ip=$(get_server_ip)
    local snell_psk=$(get_snell_psk)
    
    # 获取 Snell 端口
    local snell_port=$(get_snell_port)
    snell_port=$(echo "$snell_port" | sed 's/^0*//')
    
    # 创建系统服务
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Shadow-TLS Server Service
Documentation=man:sstls-server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/shadow-tls --v3 server --listen ::0:${listen_port} --server 127.0.0.1:${snell_port} --tls ${tls_domain} --password ${password}
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=shadow-tls

[Install]
WantedBy=multi-user.target
EOF

    # 设置正确的权限
    chmod 644 "$SERVICE_FILE"
    
    # 不再需要单独的配置文件
    rm -f "$CONFIG_DIR/config.json" 2>/dev/null
    
    # 创建日志文件
    touch /var/log/shadowtls.log
    chmod 644 /var/log/shadowtls.log
    
    # 停止可能已存在的服务
    systemctl stop shadowtls 2>/dev/null
    
    # 重新加载服务
    systemctl daemon-reload
    
    # 启用并启动服务
    if ! systemctl enable shadowtls; then
        echo -e "${RED}启用 ShadowTLS 服务失败${RESET}"
        return 1
    fi
    
    if ! systemctl start shadowtls; then
        echo -e "${RED}启动 ShadowTLS 服务失败${RESET}"
        echo -e "${YELLOW}查看日志内容：${RESET}"
        tail -n 20 /var/log/shadowtls.log
        return 1
    fi
    
    # 验证服务状态
    if ! systemctl is-active shadowtls >/dev/null 2>&1; then
        echo -e "${RED}ShadowTLS 服务未能正常运行${RESET}"
        echo -e "${YELLOW}服务状态：${RESET}"
        systemctl status shadowtls
        echo -e "${YELLOW}日志内容：${RESET}"
        tail -n 20 /var/log/shadowtls.log
        return 1
    fi
    
    # 显示配置信息
    echo -e "\n${GREEN}=== ShadowTLS 安装成功 ===${RESET}"
    echo -e "\n${YELLOW}=== 服务器配置 ===${RESET}"
    echo -e "服务器IP：${server_ip}"
    echo -e "监听地址：::0:${listen_port}"
    echo -e "后端地址：127.0.0.1:${snell_port}"
    echo -e "TLS域名：${tls_domain}"
    echo -e "密码：${password}"
    echo -e "Snell PSK：${snell_psk}"
    
    echo -e "\n${YELLOW}=== Surge/Stash 配置参数 ===${RESET}"
    echo -e "shadow-tls-password=${password}"
    echo -e "shadow-tls-sni=${tls_domain}"
    echo -e "shadow-tls-version=3"
    
    echo -e "\n${YELLOW}=== 完整配置示例 ===${RESET}"
    echo -e "Snell + ShadowTLS = snell, ${server_ip}, ${listen_port}, psk=${snell_psk}, version=4, shadow-tls-password=${password}, shadow-tls-sni=${tls_domain}, shadow-tls-version=3"
    
    echo -e "\n${GREEN}服务已启动并设置为开机自启${RESET}"
}

# 卸载 ShadowTLS
uninstall_shadowtls() {
    echo -e "${YELLOW}正在卸载 ShadowTLS...${RESET}"
    
    systemctl stop shadowtls
    systemctl disable shadowtls
    
    rm -f "$SERVICE_FILE"
    rm -f "$INSTALL_DIR/shadow-tls"
    rm -rf "$CONFIG_DIR"
    
    systemctl daemon-reload
    
    echo -e "${GREEN}ShadowTLS 已成功卸载${RESET}"
}

# 查看配置
view_config() {
    if [ -f "$SERVICE_FILE" ]; then
        echo -e "${CYAN}ShadowTLS 配置信息：${RESET}"
        cat "$SERVICE_FILE"
        echo -e "\n${CYAN}服务状态：${RESET}"
        systemctl status shadowtls
    else
        echo -e "${RED}配置文件不存在${RESET}"
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
