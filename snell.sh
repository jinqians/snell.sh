#!/bin/bash
# =========================================
# 作者: jinqians
# 日期: 2024年11月
# 网站：jinqians.com
# 描述: 这个脚本用于安装、卸载、查看和更新 Snell 代理
# =========================================

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

#当前版本号
current_version="2.2"

SNELL_CONF_DIR="/etc/snell"
SNELL_CONF_FILE="${SNELL_CONF_DIR}/snell-server.conf"
INSTALL_DIR="/usr/local/bin"
SYSTEMD_SERVICE_FILE="/lib/systemd/system/snell.service"
SNELL_VERSION="v4.0.1"  # 初始默认版本

# 等待其他 apt 进程完成
wait_for_apt() {
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
        echo -e "${YELLOW}等待其他 apt 进程完成...${RESET}"
        sleep 1
    done
}

# 检查是否以 root 权限运行
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请以 root 权限运行此脚本.${RESET}"
        exit 1
    fi
}
check_root

# 检查 jq 是否安装
check_jq() {
    if ! command -v jq &> /dev/null; then
        echo -e "${YELLOW}未检测到 jq，正在安装...${RESET}"
        # 根据系统类型安装 jq
        if [ -x "$(command -v apt)" ]; then
            wait_for_apt
            apt update && apt install -y jq
        elif [ -x "$(command -v yum)" ]; then
            yum install -y jq
        else
            echo -e "${RED}未支持的包管理器，无法安装 jq。请手动安装 jq。${RESET}"
            exit 1
        fi
    fi
}
check_jq

# 检查 Snell 是否已安装
check_snell_installed() {
    if command -v snell-server &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# 获取 Snell 最新版本
get_latest_snell_version() {
    latest_version=$(curl -s https://manual.nssurge.com/others/snell.html | grep -oP 'snell-server-v\K[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    if [ -n "$latest_version" ]; then
        SNELL_VERSION="v${latest_version}"
    else
        echo -e "${RED}获取 Snell 最新版本失败，使用默认版本 ${SNELL_VERSION}${RESET}"
    fi
}

# 比较版本号
version_greater_equal() {
    # 拆分版本号
    local ver1="$1"
    local ver2="$2"

    # 去除 'v' 前缀
    ver1=${ver1#v}
    ver2=${ver2#v}

    # 将版本号用 '.' 分割
    IFS='.' read -r -a ver1_arr <<< "$ver1"
    IFS='.' read -r -a ver2_arr <<< "$ver2"

    # 比较主版本、次版本和修订版本
    for i in {0..2}; do
        if (( ver1_arr[i] > ver2_arr[i] )); then
            return 0
        elif (( ver1_arr[i] < ver2_arr[i] )); then
            return 1
        fi
    done
    return 0
}

# 用户输入端口号，范围 1-65535
get_user_port() {
    while true; do
        read -rp "请输入要使用的端口号 (1-65535): " PORT
        if [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
            echo -e "${GREEN}已选择端口: $PORT${RESET}"
            break
        else
            echo -e "${RED}无效端口号，请输入 1 到 65535 之间的数字。${RESET}"
        fi
    done
}

# 获取用户输入的 DNS 服务器
get_dns() {
    read -rp "请输入 DNS 服务器地址 (直接回车使用默认 1.1.1.1,8.8.8.8): " custom_dns
    if [ -z "$custom_dns" ]; then
        DNS="1.1.1.1,8.8.8.8"
        echo -e "${GREEN}使用默认 DNS 服务器: $DNS${RESET}"
    else
        DNS=$custom_dns
        echo -e "${GREEN}使用自定义 DNS 服务器: $DNS${RESET}"
    fi
}

# 开放端口 (ufw 和 iptables)
open_port() {
    local PORT=$1
    # 检查 ufw 是否已安装
    if command -v ufw &> /dev/null; then
        echo -e "${CYAN}在 UFW 中开放端口 $PORT${RESET}"
        ufw allow "$PORT"/tcp
    fi

    # 检查 iptables 是否已安装
    if command -v iptables &> /dev/null; then
        echo -e "${CYAN}在 iptables 中开放端口 $PORT${RESET}"
        iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
        iptables-save > /etc/iptables/rules.v4
    fi
}

# 安装 Snell
install_snell() {
    echo -e "${CYAN}正在安装 Snell${RESET}"

    wait_for_apt
    apt update && apt install -y wget unzip

    get_latest_snell_version
    ARCH=$(uname -m)
    SNELL_URL=""
    
    if [[ ${ARCH} == "aarch64" ]]; then
        SNELL_URL="https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-aarch64.zip"
    else
        SNELL_URL="https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-amd64.zip"
    fi

    wget ${SNELL_URL} -O snell-server.zip
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载 Snell 失败。${RESET}"
        exit 1
    fi

    unzip -o snell-server.zip -d ${INSTALL_DIR}
    if [ $? -ne 0 ]; then
        echo -e "${RED}解压缩 Snell 失败。${RESET}"
        exit 1
    fi

    rm snell-server.zip
    chmod +x ${INSTALL_DIR}/snell-server

    get_user_port  # 获取用户输入的端口
    get_dns # 获取用户输入的 DNS 服务器
    PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)

    mkdir -p ${SNELL_CONF_DIR}

    cat > ${SNELL_CONF_FILE} << EOF
[snell-server]
listen = ::0:${PORT}
psk = ${PSK}
ipv6 = true
dns = ${DNS}
EOF

    cat > ${SYSTEMD_SERVICE_FILE} << EOF
[Unit]
Description=Snell Proxy Service
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
LimitNOFILE=32768
ExecStart=${INSTALL_DIR}/snell-server -c ${SNELL_CONF_FILE}
AmbientCapabilities=CAP_NET_BIND_SERVICE
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=snell-server

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    if [ $? -ne 0 ]; then
        echo -e "${RED}重载 Systemd 配置失败。${RESET}"
        exit 1
    fi

    systemctl enable snell
    if [ $? -ne 0 ]; then
        echo -e "${RED}开机自启动 Snell 失败。${RESET}"
        exit 1
    fi

    systemctl start snell
    if [ $? -ne 0 ]; then
        echo -e "${RED}启动 Snell 服务失败。${RESET}"
        exit 1
    fi

    # 开放端口
    open_port "$PORT"

    # 解析配置文件中的信息
    # 获取 IPv4 地址
    IPV4_ADDR=$(curl -s -4 ip.sb)
    
    # 获取 IPv6 地址
    IPV6_ADDR=$(curl -s -6 ip.sb)
    
    # 检查是否获取到 IPv4 和 IPv6 地址
    if [ -z "$IPV4_ADDR" ] && [ -z "$IPV6_ADDR" ]; then
        echo -e "${RED}无法获取到公网 IP 地址，请检查网络连接。${RESET}"
        return
    fi

    echo -e "\n公网 IP 地址信息："
    
    # 如果有 IPv4 地址
    if [ ! -z "$IPV4_ADDR" ]; then
        IP_COUNTRY_IPV4=$(curl -s http://ipinfo.io/${IPV4_ADDR}/country)
        echo -e "${GREEN}IPv4 地址: ${RESET}${IPV4_ADDR} ${GREEN}所在国家: ${RESET}${IP_COUNTRY_IPV4}"
    fi

    # 如果有 IPv6 地址
    if [ ! -z "$IPV6_ADDR" ]; then
        IP_COUNTRY_IPV6=$(curl -s https://ipapi.co/${IPV6_ADDR}/country/)
        echo -e "${GREEN}IPv6 地址: ${RESET}${IPV6_ADDR} ${GREEN}所在国家: ${RESET}${IP_COUNTRY_IPV6}"
    fi

    echo -e "${GREEN}Snell 安装成功${RESET}"
    if [ ! -z "$IPV4_ADDR" ]; then
        echo -e "${GREEN}${IP_COUNTRY_IPV4} = snell, ${IPV4_ADDR}, ${PORT}, psk = ${PSK}, version = 4, reuse = true, tfo = true"
    fi
    
    if [ ! -z "$IPV6_ADDR" ]; then
        echo -e "${GREEN}${IP_COUNTRY_IPV6} = snell, ${IPV6_ADDR}, ${PORT}, psk = ${PSK}, version = 4, reuse = true, tfo = true"
    fi

    ln -sf "$(realpath "$0")" /usr/local/bin/snell
    chmod +x /usr/local/bin/snell
    
    echo -e "\n${YELLOW}安装完成！您可以在终端输入 'snell' 进入管理菜单。${RESET}\n"
}

# 卸载 Snell
uninstall_snell() {
    echo -e "${CYAN}正在卸载 Snell${RESET}"

    systemctl stop snell
    if [ $? -ne 0 ]; then
        echo -e "${RED}停止 Snell 服务失败。${RESET}"
        exit 1
    fi

    systemctl disable snell
    if [ $? -ne 0 ]; then
        echo -e "${RED}禁用开机自启动失败。${RESET}"
        exit 1
    fi

    rm /lib/systemd/system/snell.service
    if [ $? -ne 0 ];then
        echo -e "${RED}删除 Systemd 服务文件失败。${RESET}"
        exit 1
    fi

    rm /usr/local/bin/snell-server
    rm -rf ${SNELL_CONF_DIR}
    rm -f /usr/local/bin/snell
    
    echo -e "${GREEN}Snell 卸载成功${RESET}"
}

# 重启 Snell
restart_snell() {
    echo -e "${YELLOW}正在重启 Snell...${RESET}"
    systemctl restart snell 2>/dev/null || (pkill -x snell-server && nohup snell-server &)
    echo -e "${GREEN}Snell 已成功重启。${RESET}"
}

view_snell_config() {
    if [ -f "${SNELL_CONF_FILE}" ]; then
        echo -e "${GREEN}Snell 配置信息:${RESET}"
        echo -e "${CYAN}--------------------------------${RESET}"
        echo -e "${YELLOW}监听地址: $(grep "listen" ${SNELL_CONF_FILE} | cut -d= -f2 | tr -d ' ')${RESET}"
        echo -e "${YELLOW}PSK 密钥: $(grep "psk" ${SNELL_CONF_FILE} | cut -d= -f2 | tr -d ' ')${RESET}"
        echo -e "${YELLOW}IPv6: $(grep "ipv6" ${SNELL_CONF_FILE} | cut -d= -f2 | tr -d ' ')${RESET}"
        echo -e "${YELLOW}DNS 服务器: $(grep "dns" ${SNELL_CONF_FILE} | cut -d= -f2 | tr -d ' ')${RESET}"
        echo -e "${CYAN}--------------------------------${RESET}"
        
        # 获取 IPv4 地址
        IPV4_ADDR=$(curl -s -4 ip.sb)
        
        # 获取 IPv6 地址
        IPV6_ADDR=$(curl -s -6 ip.sb)
        
        # 检查是否获取到 IPv4 和 IPv6 地址
        if [ -z "$IPV4_ADDR" ] && [ -z "$IPV6_ADDR" ]; then
            echo -e "${RED}无法获取到公网 IP 地址，请检查网络连接。${RESET}"
            return
        fi

        echo -e "\n公网 IP 地址信息："
        
        # 如果有 IPv4 地址
        if [ ! -z "$IPV4_ADDR" ]; then
            IP_COUNTRY_IPV4=$(curl -s http://ipinfo.io/${IPV4_ADDR}/country)
            echo -e "${GREEN}IPv4 地址: ${RESET}${IPV4_ADDR} ${GREEN}所在国家: ${RESET}${IP_COUNTRY_IPV4}"
        fi

        # 如果有 IPv6 地址
        if [ ! -z "$IPV6_ADDR" ]; then
            IP_COUNTRY_IPV6=$(curl -s https://ipapi.co/${IPV6_ADDR}/country/)
            echo -e "${GREEN}IPv6 地址: ${RESET}${IPV6_ADDR} ${GREEN}所在国家: ${RESET}${IP_COUNTRY_IPV6}"
        fi
        
        PORT=$(grep -E '^listen' "${SNELL_CONF_FILE}" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
        PSK=$(grep -E '^psk' "${SNELL_CONF_FILE}" | awk -F'=' '{print $2}' | tr -d ' ')
        
        echo -e "${GREEN}解析后的配置:${RESET}"
        echo "端口: ${PORT}"
        echo "PSK: ${PSK}"
        
        if [ -z "${PORT}" ]; then
            echo -e "${RED}端口解析失败，请检查配置文件。${RESET}"
        fi
        
        if [ -z "${PSK}" ]; then
            echo -e "${RED}PSK 解析失败，请检查配置文件。${RESET}"
        fi
        
        echo -e "\n${GREEN}配置信息:${RESET}"
        
        # 输出原始 Snell 配置
        if [ ! -z "$IPV4_ADDR" ]; then
            echo -e "${GREEN}${IP_COUNTRY_IPV4} = snell, ${IPV4_ADDR}, ${PORT}, psk = ${PSK}, version = 4, reuse = true, tfo = true${RESET}"
        fi
        
        if [ ! -z "$IPV6_ADDR" ]; then
            echo -e "${GREEN}${IP_COUNTRY_IPV6} = snell, ${IPV6_ADDR}, ${PORT}, psk = ${PSK}, version = 4, reuse = true, tfo = true${RESET}"
        fi
        
        # 获取 ShadowTLS 配置并输出带 ShadowTLS 的配置
        local shadowtls_config
        if shadowtls_config=$(get_shadowtls_config); then
            IFS='|' read -r stls_psk stls_domain stls_port <<< "$shadowtls_config"
            
            if [ ! -z "$IPV4_ADDR" ]; then
                IP_COUNTRY_IPV4=$(curl -s http://ipinfo.io/${IPV4_ADDR}/country)
                echo -e "${GREEN}${IP_COUNTRY_IPV4} = snell, ${IPV4_ADDR}, ${stls_port}, psk = ${PSK}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_psk}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
            fi
            
            if [ ! -z "$IPV6_ADDR" ]; then
                IP_COUNTRY_IPV6=$(curl -s https://ipapi.co/${IPV6_ADDR}/country/)
                echo -e "${GREEN}${IP_COUNTRY_IPV6} = snell, ${IPV6_ADDR}, ${stls_port}, psk = ${PSK}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_psk}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
            fi
        fi

        read -p "按任意键返回主菜单..."
    else
        echo -e "${RED}Snell 配置文件不存在。${RESET}"
    fi
}

# 获取当前安装的 Snell 版本
get_current_snell_version() {
    CURRENT_VERSION=$(snell-server --v 2>&1 | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+')
    if [ -z "$CURRENT_VERSION" ]; then
        echo -e "${RED}无法获取当前 Snell 版本。${RESET}"
        exit 1
    fi
}

# 检查 Snell 更新
check_snell_update() {
    get_latest_snell_version
    get_current_snell_version

    if ! version_greater_equal "$CURRENT_VERSION" "$SNELL_VERSION"; then
        echo -e "${YELLOW}当前 Snell 版本: ${CURRENT_VERSION}，最新版本: ${SNELL_VERSION}${RESET}"
        echo -e "${CYAN}是否更新 Snell? [y/N]${RESET}"
        read -r choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            install_snell
        else
            echo -e "${CYAN}已取消更新。${RESET}"
        fi
    else
        echo -e "${GREEN}当前已是最新版本 (${CURRENT_VERSION})。${RESET}"
    fi
}

# 获取最新 GitHub 版本
get_latest_github_version() {
    GITHUB_VERSION_INFO=$(curl -s https://api.github.com/repos/jinqians/snell.sh/releases/latest)
    if [ $? -ne 0 ]; then
        echo -e "${RED}无法获取 GitHub 上的最新版本信息。${RESET}"
        exit 1
    fi

    GITHUB_VERSION=$(echo "$GITHUB_VERSION_INFO" | jq -r '.name' | awk '{print $NF}')
    if [ -z "$GITHUB_VERSION" ]; then
        echo -e "${RED}获取 GitHub 版本失败。${RESET}"
        exit 1
    fi
}

# 更新脚本
update_script() {
    get_latest_github_version

    if version_greater_equal "$current_version" "$GITHUB_VERSION"; then
        echo -e "${GREEN}当前版本 (${current_version}) 已是最新，无需更新。${RESET}"
    else
        echo -e "${YELLOW}发现新版本：${GITHUB_VERSION}，当前版本：${current_version}${RESET}"
        # 使用 curl 下载脚本并覆盖当前脚本
        curl -s -o "$0" "https://raw.githubusercontent.com/jinqians/snell.sh/main/snell.sh"
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}脚本更新成功！已更新至 GitHub 上的版本: ${GITHUB_VERSION}${RESET}"
            echo -e "${YELLOW}请重新执行脚本以应用更新。${RESET}"
            exec "$0"  # 重新执行当前脚本
        else
            echo -e "${RED}脚本更新失败！${RESET}"
        fi
    fi
}

# 检查服务状态的函数
check_service_status() {
    local service=$1
    if systemctl is-active --quiet "$service"; then
        echo -e "${GREEN}运行中${RESET}"
    else
        echo -e "${RED}未运行${RESET}"
    fi
}

# 检查是否安装的函数
check_installation() {
    local service=$1
    if systemctl list-unit-files | grep -q "^$service.service"; then
        echo -e "${GREEN}已安装${RESET}"
    else
        echo -e "${RED}未安装${RESET}"
    fi
}

# 获取 ShadowTLS 配置
get_shadowtls_config() {
    if ! systemctl is-active --quiet shadowtls.service; then
        return 1
    fi
    
    local service_file="/etc/systemd/system/shadowtls.service"
    if [ ! -f "$service_file" ]; then
        return 1
    fi
    
    # 从服务文件中读取配置行
    local exec_line=$(grep "ExecStart=" "$service_file")
    if [ -z "$exec_line" ]; then
        return 1
    fi
    
    # 提取配置信息
    local tls_domain=$(echo "$exec_line" | grep -o -- "--tls [^ ]*" | cut -d' ' -f2)
    local password=$(echo "$exec_line" | grep -o -- "--password [^ ]*" | cut -d' ' -f2)
    local listen_part=$(echo "$exec_line" | grep -o -- "--listen [^ ]*" | cut -d' ' -f2)
    local listen_port=$(echo "$listen_part" | grep -o '[0-9]*$')
    
    if [ -z "$tls_domain" ] || [ -z "$password" ] || [ -z "$listen_port" ]; then
        return 1
    fi
    
    echo "${password}|${tls_domain}|${listen_port}"
    return 0
}

# 显示服务状态
show_status() {
    echo -e "\n${YELLOW}=== 服务状态 ===${RESET}"
    echo -e "Snell 安装状态: $(check_installation snell)"
    echo -e "Snell 运行状态: $(check_service_status snell)"
    echo -e "ShadowTLS 安装状态: $(check_installation shadowtls)"
    echo -e "ShadowTLS 运行状态: $(check_service_status shadowtls)"
    echo
}

# 显示配置信息
show_config() {
    local snell_port=$(grep -oP 'listen = \K[0-9]+' /etc/snell/snell-server.conf)
    local psk=$(grep -oP 'psk = \K[^[:space:]]+' /etc/snell/snell-server.conf)
    
    echo -e "\n${YELLOW}=== 配置信息 ===${RESET}"
    
    # 基础 Snell 配置
    echo -e "\n${GREEN}Snell 配置：${RESET}"
    echo -e "snell = snell, [服务器IP], ${snell_port}, psk=${psk}, version=4"
    
    # 如果 ShadowTLS 已安装，显示组合配置
    if shadowtls_config=$(get_shadowtls_config); then
        IFS='|' read -r tls_port tls_password tls_domain <<< "$shadowtls_config"
        
        echo -e "\n${GREEN}Snell + ShadowTLS 配置：${RESET}"
        echo -e "snell = snell, [服务器IP], ${tls_port}, psk=${psk}, version=4, reuse = true, tfo = true, shadow-tls-password=${tls_password}, shadow-tls-sni=${tls_domain}, shadow-tls-version=3"
    fi
    
    echo -e "\n${YELLOW}注意：请将 [服务器IP] 替换为实际的服务器IP地址${RESET}"
}

# 检查服务状态并显示
check_and_show_status() {
    echo -e "\n${CYAN}=== 服务状态检查 ===${RESET}"
    
    # 检查 Snell 状态
    if command -v snell-server &> /dev/null; then
        echo -e "${GREEN}Snell 已安装${RESET}"
        if systemctl is-active snell &> /dev/null; then
            echo -e "${GREEN}Snell 服务运行中${RESET}"
        else
            echo -e "${RED}Snell 服务未运行${RESET}"
        fi
    else
        echo -e "${YELLOW}Snell 未安装${RESET}"
    fi
    
    # 检查 ShadowTLS 状态
    if [ -f "/usr/local/bin/shadow-tls" ]; then
        echo -e "${GREEN}ShadowTLS 已安装${RESET}"
        if systemctl is-active shadowtls &> /dev/null; then
            echo -e "${GREEN}ShadowTLS 服务运行中${RESET}"
        else
            echo -e "${RED}ShadowTLS 服务未运行${RESET}"
        fi
    else
        echo -e "${YELLOW}ShadowTLS 未安装${RESET}"
    fi
    
    echo -e "${CYAN}====================${RESET}\n"
}

# 检查是否以 root 权限运行
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请以 root 权限运行此脚本${RESET}"
        exit 1
    fi
}

# 初始检查
initial_check() {
    check_root
    check_and_show_status
}

# 运行初始检查
initial_check

# 主菜单
show_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}          Snell 管理脚本 v${current_version}${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}作者: jinqian${RESET}"
    echo -e "${GREEN}网站：https://jinqians.com${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    
    # 显示服务状态
    check_and_show_status
    
    echo -e "${YELLOW}=== 基础功能 ===${RESET}"
    echo -e "${GREEN}1.${RESET} 安装 Snell"
    echo -e "${GREEN}2.${RESET} 卸载 Snell"
    echo -e "${GREEN}3.${RESET} 重启 Snell"
    echo -e "${GREEN}4.${RESET} 查看配置"
    
    echo -e "\n${YELLOW}=== 增强功能 ===${RESET}"
    echo -e "${GREEN}5.${RESET} ShadowTLS 管理"
    echo -e "${GREEN}6.${RESET} BBR 管理"
    
    echo -e "\n${YELLOW}=== 系统功能 ===${RESET}"
    echo -e "${GREEN}7.${RESET} 检查更新"
    echo -e "${GREEN}8.${RESET} 更新脚本"
    echo -e "${GREEN}9.${RESET} 查看服务状态"
    echo -e "${GREEN}0.${RESET} 退出脚本"
    
    echo -e "${CYAN}============================================${RESET}"
    read -rp "请输入选项 [0-9]: " num
}

#开启bbr
setup_bbr() {
    echo -e "${CYAN}正在获取并执行 BBR 管理脚本...${RESET}"
    
    # 直接从远程执行BBR脚本
    bash <(curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/main/bbr.sh)
    
    # BBR 脚本执行完毕后会自动返回这里
    echo -e "${GREEN}BBR 管理操作完成${RESET}"
    sleep 1  # 给用户一点时间看到提示
}

# ShadowTLS管理
setup_shadowtls() {
    echo -e "${CYAN}正在执行 ShadowTLS 管理脚本...${RESET}"
    bash <(curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/main/shadowtls.sh)
    
    # ShadowTLS 脚本执行完毕后会自动返回这里
    echo -e "${GREEN}ShadowTLS 管理操作完成${RESET}"
    sleep 1  # 给用户一点时间看到提示
}

# 主循环
while true; do
    show_menu
    case "$num" in
        1)
            install_snell
            ;;
        2)
            uninstall_snell
            ;;
        3)
            restart_snell
            ;;
        4)
            view_snell_config
            ;;
        5)
            setup_shadowtls
            ;;
        6)
            setup_bbr
            ;;
        7)
            check_snell_update
            ;;
        8)
            update_script
            ;;
        9)
            check_and_show_status
            read -p "按任意键继续..."
            ;;
        0)
            echo -e "${GREEN}感谢使用，再见！${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}请输入正确的选项 [0-9]${RESET}"
            ;;
    esac
    echo -e "\n${CYAN}按任意键返回主菜单...${RESET}"
    read -n 1 -s -r
done
