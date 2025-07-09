#!/bin/bash
# =========================================
# 作者: jinqians
# 日期: 2025年5月
# 网站：jinqians.com
# 描述: 这个脚本用于在 CentOS/Red Hat/Fedora 系统上安装和管理 Snell 代理
# =========================================

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
RESET='\033[0m'

#当前版本号
current_version="2.2"

# 全局变量：选择的 Snell 版本
SNELL_VERSION_CHOICE=""
SNELL_VERSION=""

# 定义系统路径
INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/usr/lib/systemd/system"
SNELL_CONF_DIR="/etc/snell"
SNELL_CONF_FILE="${SNELL_CONF_DIR}/users/snell-main.conf"
SYSTEMD_SERVICE_FILE="${SYSTEMD_DIR}/snell.service"

# 检查是否以 root 权限运行
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请以 root 权限运行此脚本${RESET}"
        exit 1
    fi
}

# 检查系统类型
check_system() {
    if [[ -f /etc/redhat-release ]]; then
        echo -e "${GREEN}检测到 CentOS/Red Hat 系统${RESET}"
    else
        echo -e "${RED}错误: 此脚本仅适用于 CentOS/Red Hat 系统${RESET}"
        exit 1
    fi
}

# 安装依赖
install_dependencies() {
    echo -e "${CYAN}正在安装依赖...${RESET}"
    yum -y update
    yum -y install curl wget unzip net-tools systemd
}

# === 新增：版本选择函数 ===
# 选择 Snell 版本
select_snell_version() {
    echo -e "${CYAN}请选择要安装的 Snell 版本：${RESET}"
    echo -e "${GREEN}1.${RESET} Snell v4 (稳定版)"
    echo -e "${GREEN}2.${RESET} Snell v5 (测试版)"
    echo -e "${YELLOW}注意：v5 为测试版本，可能存在兼容性问题${RESET}"
    
    while true; do
        read -rp "请输入选项 [1-2]: " version_choice
        case "$version_choice" in
            1)
                SNELL_VERSION_CHOICE="v4"
                echo -e "${GREEN}已选择 Snell v4${RESET}"
                break
                ;;
            2)
                SNELL_VERSION_CHOICE="v5"
                echo -e "${GREEN}已选择 Snell v5${RESET}"
                break
                ;;
            *)
                echo -e "${RED}请输入正确的选项 [1-2]${RESET}"
                ;;
        esac
    done
}

# 获取 Snell v4 最新版本
get_latest_snell_v4_version() {
    latest_version=$(curl -s https://manual.nssurge.com/others/snell.html | grep -oP 'snell-server-v\K[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    if [ -n "$latest_version" ]; then
        echo "v${latest_version}"
    else
        # 如果无法获取，使用默认版本，但不输出错误信息到返回值
        echo "v4.1.1"
    fi
}

# 获取 Snell v5 最新版本
get_latest_snell_v5_version() {
    # 尝试从官方页面获取最新 v5 版本
    local v5_version=$(curl -s https://manual.nssurge.com/others/snell.html | grep -oP 'snell-server-v\K5\.[0-9]+\.[0-9]+[a-z0-9]*' | head -n 1)
    if [ -n "$v5_version" ]; then
        echo "v${v5_version}"
    else
        # 如果无法获取，使用最新的测试版本 v5.0.0b2
        echo "v5.0.0b2"
    fi
}

# 获取 Snell 最新版本（根据选择的版本）
get_latest_snell_version() {
    if [ "$SNELL_VERSION_CHOICE" = "v5" ]; then
        SNELL_VERSION=$(get_latest_snell_v5_version)
    else
        SNELL_VERSION=$(get_latest_snell_v4_version)
    fi
}

# 获取 Snell 下载 URL
get_snell_download_url() {
    local version=$1
    local arch=$(uname -m)
    
    if [ "$version" = "v5" ]; then
        # v5 版本自动拼接下载链接
        case ${arch} in
            "x86_64"|"amd64")
                echo "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-amd64.zip"
                ;;
            "i386"|"i686")
                echo "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-i386.zip"
                ;;
            "aarch64"|"arm64")
                echo "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-aarch64.zip"
                ;;
            "armv7l"|"armv7")
                echo "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-armv7l.zip"
                ;;
            *)
                echo -e "${RED}不支持的架构: ${arch}${RESET}"
                exit 1
                ;;
        esac
    else
        # v4 版本使用 zip 格式
        case ${arch} in
            "x86_64"|"amd64")
                echo "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-amd64.zip"
                ;;
            "i386"|"i686")
                echo "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-i386.zip"
                ;;
            "aarch64"|"arm64")
                echo "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-aarch64.zip"
                ;;
            "armv7l"|"armv7")
                echo "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-armv7l.zip"
                ;;
            *)
                echo -e "${RED}不支持的架构: ${arch}${RESET}"
                exit 1
                ;;
        esac
    fi
}

# 生成 Surge 配置格式
generate_surge_config() {
    local ip_addr=$1
    local port=$2
    local psk=$3
    local version=$4
    local country=$5
    local installed_version=$6   # 新增参数

    if [ "$installed_version" = "v5" ]; then
        # v5 版本输出 v4 和 v5 两种配置
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 4, reuse = true, tfo = true${RESET}"
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 5, reuse = true, tfo = true${RESET}"
    else
        # v4 版本只输出 v4 配置
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 4, reuse = true, tfo = true${RESET}"
    fi
}

# 检测当前安装的 Snell 版本
detect_installed_snell_version() {
    if command -v snell-server &> /dev/null; then
        # 尝试获取版本信息
        local version_output=$(snell-server --v 2>&1)
        if echo "$version_output" | grep -q "v5"; then
            echo "v5"
        else
            echo "v4"
        fi
    else
        echo "unknown"
    fi
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
    read -rp "请输入 DNS 服务器地址 (直接回车使用系统DNS): " custom_dns
    if [ -z "$custom_dns" ]; then
        DNS="1.1.1.1,8.8.8.8"
        echo -e "${GREEN}使用默认 DNS 服务器: $DNS${RESET}"
    else
        DNS=$custom_dns
        echo -e "${GREEN}使用自定义 DNS 服务器: $DNS${RESET}"
    fi
}

# 开放端口
open_port() {
    local PORT=$1
    echo -e "${CYAN}正在配置防火墙...${RESET}"
    
    # 检查 firewalld
    if command -v firewall-cmd &> /dev/null && systemctl is-active firewalld &>/dev/null; then
        echo -e "${YELLOW}检测到 firewalld 正在运行，正在配置...${RESET}"
        firewall-cmd --permanent --add-port="$PORT"/tcp
        firewall-cmd --permanent --add-port="$PORT"/udp
        firewall-cmd --reload
        echo -e "${GREEN}firewalld 配置完成${RESET}"
    fi
    
    # 检查 iptables
    if command -v iptables &> /dev/null; then
        echo -e "${YELLOW}检测到 iptables，正在配置...${RESET}"
        # 检查规则是否已存在
        if ! iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT &>/dev/null; then
            iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
        fi
        if ! iptables -C INPUT -p udp --dport "$PORT" -j ACCEPT &>/dev/null; then
            iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT
        fi
        
        # 保存规则
        if command -v iptables-save &> /dev/null; then
            iptables-save > /etc/sysconfig/iptables
            echo -e "${GREEN}iptables 规则已保存${RESET}"
        fi
        echo -e "${GREEN}iptables 配置完成${RESET}"
    fi
    
    # 检查端口是否已开放
    if command -v netstat &> /dev/null; then
        echo -e "\n${YELLOW}端口状态检查:${RESET}"
        netstat -tuln | grep "$PORT"
    fi
    
    echo -e "${GREEN}防火墙配置完成${RESET}"
}

# 安装 Snell
install_snell() {
    echo -e "${CYAN}正在安装 Snell${RESET}"

    # 检查系统
    check_root
    check_system

    # 选择 Snell 版本
    select_snell_version

    # 安装依赖
    install_dependencies

    # 获取最新版本
    get_latest_snell_version
    ARCH=$(uname -m)
    
    # 确定下载链接
    SNELL_URL=$(get_snell_download_url "$SNELL_VERSION_CHOICE")

    echo -e "${CYAN}正在下载 Snell ${SNELL_VERSION_CHOICE} (${SNELL_VERSION})...${RESET}"
    echo -e "${YELLOW}下载链接: ${SNELL_URL}${RESET}"

    # 创建安装目录
    mkdir -p ${INSTALL_DIR}
    mkdir -p ${SNELL_CONF_DIR}/users

    # 下载并解压
    wget ${SNELL_URL} -O snell-server.zip
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载 Snell ${SNELL_VERSION_CHOICE} 失败。${RESET}"
        exit 1
    fi

    unzip -o snell-server.zip -d ${INSTALL_DIR}
    if [ $? -ne 0 ]; then
        echo -e "${RED}解压缩 Snell 失败。${RESET}"
        exit 1
    fi

    rm snell-server.zip
    chmod +x ${INSTALL_DIR}/snell-server

    # 创建管理脚本
    cat > /usr/local/bin/snell << 'EOFSCRIPT'
#!/bin/bash

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 检查是否以 root 权限运行
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}请以 root 权限运行此脚本${RESET}"
    exit 1
fi

# 下载并执行最新版本的脚本
echo -e "${CYAN}正在获取最新版本的管理脚本...${RESET}"
TMP_SCRIPT=$(mktemp)
if curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/refs/heads/main/snell-centos.sh -o "$TMP_SCRIPT"; then
    bash "$TMP_SCRIPT"
    rm -f "$TMP_SCRIPT"
else
    echo -e "${RED}下载脚本失败，请检查网络连接。${RESET}"
    rm -f "$TMP_SCRIPT"
    exit 1
fi
EOFSCRIPT
    
    if [ $? -eq 0 ]; then
        chmod +x /usr/local/bin/snell
        if [ $? -eq 0 ]; then
            echo -e "\n${GREEN}管理脚本安装成功！${RESET}"
            echo -e "${YELLOW}您可以在终端输入 'snell' 进入管理菜单。${RESET}"
            echo -e "${YELLOW}注意：需要使用 sudo snell 或以 root 身份运行。${RESET}\n"
        else
            echo -e "\n${RED}设置脚本执行权限失败。${RESET}"
            echo -e "${YELLOW}您可以通过直接运行原脚本来管理 Snell。${RESET}\n"
        fi
    else
        echo -e "\n${RED}创建管理脚本失败。${RESET}"
        echo -e "${YELLOW}您可以通过直接运行原脚本来管理 Snell。${RESET}\n"
    fi

    # 生成配置
    get_user_port
    get_dns
    # 生成 PSK
    PSK=$(openssl rand -base64 16)
    # 确保 PSK 不为空
    if [ -z "$PSK" ]; then
        echo -e "${RED}PSK 生成失败${RESET}"
        exit 1
    fi

    # 创建配置文件
    cat > ${SNELL_CONF_FILE} << EOF
[snell-server]
listen = ::0:${PORT}
psk = ${PSK}
ipv6 = true
dns = ${DNS}
EOF

    # 验证配置文件
    if [ ! -f "${SNELL_CONF_FILE}" ]; then
        echo -e "${RED}配置文件创建失败${RESET}"
        exit 1
    fi

    # 验证 PSK 是否正确写入
    if ! grep -q "psk = ${PSK}" "${SNELL_CONF_FILE}"; then
        echo -e "${RED}PSK 写入配置文件失败${RESET}"
        exit 1
    fi

    echo -e "${GREEN}PSK 已生成并写入配置文件${RESET}"

    # 创建 systemd 服务
    cat > ${SYSTEMD_SERVICE_FILE} << EOF
[Unit]
Description=Snell Proxy Service
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/snell-server -c ${SNELL_CONF_FILE}
Restart=on-failure
RestartSec=5
LimitNOFILE=16384
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

    # 创建 systemd preset 文件
    cat > /usr/lib/systemd/system-preset/90-snell.preset << EOF
enable snell.service
EOF

    # 设置权限
    chmod 644 ${SYSTEMD_SERVICE_FILE}
    chmod 644 /usr/lib/systemd/system-preset/90-snell.preset
    chmod -R 755 ${SNELL_CONF_DIR}
    chmod 755 ${INSTALL_DIR}/snell-server

    # 重载并启动服务
    systemctl daemon-reload
    systemctl preset snell
    systemctl enable snell
    systemctl start snell

    # 检查服务状态
    if ! systemctl is-active snell &>/dev/null; then
        echo -e "${RED}Snell 服务启动失败${RESET}"
        echo -e "${YELLOW}请检查服务状态：systemctl status snell${RESET}"
        echo -e "${YELLOW}请检查日志：journalctl -u snell -n 50${RESET}"
        exit 1
    fi

    # 开放端口
    open_port "$PORT"

    # 显示安装信息
    show_information
}

# 显示安装信息
show_information() {
    echo -e "\n${BLUE}============================================${RESET}"
    echo -e "${GREEN}Snell 安装成功!${RESET}"
    echo -e "${BLUE}============================================${RESET}"
    
    # 检测当前安装的 Snell 版本
    local installed_version=$(detect_installed_snell_version)
    if [ "$installed_version" != "unknown" ]; then
        echo -e "${YELLOW}当前安装版本: Snell ${installed_version}${RESET}"
    fi
    
    # 读取配置文件
    if [ -f "${SNELL_CONF_FILE}" ]; then
        # 直接从配置文件读取信息
        PORT=$(grep -oP 'listen\s*=\s*::0:\K\d+' ${SNELL_CONF_FILE})
        PSK=$(grep -oP 'psk\s*=\s*\K.*' ${SNELL_CONF_FILE})
    else
        echo -e "${RED}错误: 配置文件不存在${RESET}"
        exit 1
    fi
    
    IPV4_ADDR=$(curl -s4 https://api.ipify.org)
    IPV6_ADDR=$(curl -s6 https://api64.ipify.org)
    
    echo -e "${YELLOW}服务器信息:${RESET}"
    if [ ! -z "$IPV4_ADDR" ]; then
        IP_COUNTRY_IPV4=$(curl -s http://ipinfo.io/${IPV4_ADDR}/country)
        echo -e "${YELLOW}IPv4 地址: ${RESET}${IPV4_ADDR} ${GREEN}所在国家: ${RESET}${IP_COUNTRY_IPV4}"
    fi
    if [ ! -z "$IPV6_ADDR" ]; then
        IP_COUNTRY_IPV6=$(curl -s https://ipapi.co/${IPV6_ADDR}/country/)
        echo -e "${YELLOW}IPv6 地址: ${RESET}${IPV6_ADDR} ${GREEN}所在国家: ${RESET}${IP_COUNTRY_IPV6}"
    fi
    echo -e "${YELLOW}服务器端口: ${RESET}${PORT}"
    echo -e "${YELLOW}PSK 密钥: ${RESET}${PSK}"
    echo -e "${YELLOW}版本: ${RESET}${SNELL_VERSION}"
    echo -e "${YELLOW}服务状态: ${RESET}$(systemctl is-active snell)"
    
    # 显示 Surge 配置格式
    echo -e "\n${GREEN}Surge 配置格式:${RESET}"
    local installed_version=$(detect_installed_snell_version)
    if [ ! -z "$IPV4_ADDR" ]; then
        generate_surge_config "$IPV4_ADDR" "$PORT" "$PSK" "$installed_version" "$IP_COUNTRY_IPV4" "$installed_version"
    fi
    if [ ! -z "$IPV6_ADDR" ]; then
        generate_surge_config "$IPV6_ADDR" "$PORT" "$PSK" "$installed_version" "$IP_COUNTRY_IPV6" "$installed_version"
    fi
    
    echo -e "\n${GREEN}使用以下命令管理服务:${RESET}"
    echo -e "  ${BLUE}systemctl start snell${RESET} - 启动服务"
    echo -e "  ${BLUE}systemctl stop snell${RESET} - 停止服务"
    echo -e "  ${BLUE}systemctl restart snell${RESET} - 重启服务"
    echo -e "  ${BLUE}systemctl status snell${RESET} - 查看服务状态"
    echo -e "  ${BLUE}journalctl -u snell -f${RESET} - 实时查看日志"
    
    echo -e "\n${GREEN}配置文件位置:${RESET} ${BLUE}${SNELL_CONF_FILE}${RESET}"
    echo -e "${BLUE}============================================${RESET}"
}

# 卸载 Snell
uninstall_snell() {
    echo -e "${CYAN}正在卸载 Snell${RESET}"

    # 停止并禁用服务
    systemctl stop snell
    systemctl disable snell

    # 删除服务文件
    rm -f ${SYSTEMD_SERVICE_FILE}

    # 删除安装目录
    rm -f ${INSTALL_DIR}/snell-server
    rm -rf ${SNELL_CONF_DIR}
    
    # 删除软链接
    if [ -L "/usr/bin/snell" ]; then
        rm -f /usr/bin/snell
        echo -e "${GREEN}已删除 snell 命令软链接${RESET}"
    fi
    
    # 获取端口号
    if [ -f "${SNELL_CONF_FILE}" ]; then
        PORT=$(grep "listen" ${SNELL_CONF_FILE} | cut -d ":" -f 2)
        # 关闭防火墙端口
        if command -v firewall-cmd &> /dev/null; then
            firewall-cmd --permanent --remove-port="$PORT"/tcp
            firewall-cmd --permanent --remove-port="$PORT"/udp
            firewall-cmd --reload
        fi
        if command -v iptables &> /dev/null; then
            iptables -D INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null
            iptables -D INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null
            if command -v iptables-save &> /dev/null; then
                iptables-save > /etc/sysconfig/iptables
            fi
        fi
    fi
    
    # 重载 systemd 配置
    systemctl daemon-reload
    
    echo -e "${GREEN}Snell 已成功卸载${RESET}"
}

# 重启 Snell
restart_snell() {
    echo -e "${YELLOW}正在重启 Snell 服务...${RESET}"
    systemctl restart snell
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Snell 服务已成功重启。${RESET}"
    else
        echo -e "${RED}重启 Snell 服务失败。${RESET}"
    fi
}

# 检查服务状态并显示
check_and_show_status() {
    echo -e "\n${CYAN}=============== 服务状态检查 ===============${RESET}"
    
    if systemctl is-active snell &>/dev/null; then
        echo -e "${GREEN}Snell 服务状态: 运行中${RESET}"
    
    else
        echo -e "${RED}Snell 服务状态: 未运行${RESET}"
    fi
    
    echo -e "${CYAN}============================================${RESET}\n"
}

# === 新增：备份和还原配置函数 ===
# 备份 Snell 配置
backup_snell_config() {
    local backup_dir="/etc/snell/backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    cp -a /etc/snell/users/*.conf "$backup_dir"/ 2>/dev/null
    echo "$backup_dir"
}

# 恢复 Snell 配置
restore_snell_config() {
    local backup_dir="$1"
    if [ -d "$backup_dir" ]; then
        cp -a "$backup_dir"/*.conf /etc/snell/users/
        echo -e "${GREEN}配置已从备份恢复。${RESET}"
    else
        echo -e "${RED}未找到备份目录，无法恢复配置。${RESET}"
    fi
}

# 获取当前 Snell 版本
get_current_snell_version() {
    if [ -f "${INSTALL_DIR}/snell-server" ]; then
        CURRENT_VERSION=$(${INSTALL_DIR}/snell-server -v 2>&1 | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+')
        if [ -z "$CURRENT_VERSION" ]; then
            echo -e "${RED}无法获取当前 Snell 版本。${RESET}"
            return 1
        fi
    else
        echo -e "${RED}错误: Snell 未安装${RESET}"
        return 1
    fi
}

# 比较版本号
version_greater_equal() {
    local ver1=$1
    local ver2=$2
    
    # 移除 'v' 或 'V' 前缀，并转换为小写
    ver1=$(echo "${ver1#[vV]}" | tr '[:upper:]' '[:lower:]')
    ver2=$(echo "${ver2#[vV]}" | tr '[:upper:]' '[:lower:]')
    
    # 处理 beta 版本号（如 5.0.0b1, 5.0.0b2）
    # 将 beta 版本转换为可比较的格式
    ver1=$(echo "$ver1" | sed 's/b\([0-9]*\)/\.999\1/g')
    ver2=$(echo "$ver2" | sed 's/b\([0-9]*\)/\.999\1/g')
    
    # 将版本号分割为数组
    IFS='.' read -ra VER1 <<< "$ver1"
    IFS='.' read -ra VER2 <<< "$ver2"
    
    # 确保数组长度相等
    while [ ${#VER1[@]} -lt 4 ]; do
        VER1+=("0")
    done
    while [ ${#VER2[@]} -lt 4 ]; do
        VER2+=("0")
    done
    
    # 比较版本号
    for i in {0..3}; do
        local val1=${VER1[i]:-0}
        local val2=${VER2[i]:-0}
        
        # 如果是数字，直接比较
        if [[ "$val1" =~ ^[0-9]+$ ]] && [[ "$val2" =~ ^[0-9]+$ ]]; then
            if [ "$val1" -gt "$val2" ]; then
                return 0
            elif [ "$val1" -lt "$val2" ]; then
                return 1
            fi
        else
            # 如果是字符串（如 beta 版本），按字典序比较
            if [[ "$val1" > "$val2" ]]; then
                return 0
            elif [[ "$val1" < "$val2" ]]; then
                return 1
            fi
        fi
    done
    return 0
}

# 只更新 Snell 二进制文件，不覆盖配置
update_snell_binary() {
    echo -e "${CYAN}=============== Snell 更新 ===============${RESET}"
    echo -e "${YELLOW}注意：这是更新操作，不是重新安装${RESET}"
    echo -e "${GREEN}✓ 所有现有配置将被保留${RESET}"
    echo -e "${GREEN}✓ 端口、密码、用户配置都不会改变${RESET}"
    echo -e "${GREEN}✓ 服务会自动重启${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    
    echo -e "${CYAN}正在备份当前配置...${RESET}"
    local backup_dir
    backup_dir=$(backup_snell_config)
    echo -e "${GREEN}配置已备份到: $backup_dir${RESET}"

    echo -e "${CYAN}正在更新 Snell 二进制文件...${RESET}"
    
    # 获取最新版本信息（版本已在 check_snell_update 中确定）
    get_latest_snell_version
    ARCH=$(uname -m)
    SNELL_URL=$(get_snell_download_url "$SNELL_VERSION_CHOICE")

    echo -e "${CYAN}正在下载 Snell ${SNELL_VERSION_CHOICE} (${SNELL_VERSION})...${RESET}"
    
    # v4 和 v5 版本都使用 zip 格式，统一处理
    wget ${SNELL_URL} -O snell-server.zip
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载 Snell ${SNELL_VERSION_CHOICE} 失败。${RESET}"
        restore_snell_config "$backup_dir"
        exit 1
    fi

    echo -e "${CYAN}正在替换 Snell 二进制文件...${RESET}"
    unzip -o snell-server.zip -d ${INSTALL_DIR}
    if [ $? -ne 0 ]; then
        echo -e "${RED}解压缩 Snell 失败。${RESET}"
        restore_snell_config "$backup_dir"
        exit 1
    fi

    rm snell-server.zip
    chmod +x ${INSTALL_DIR}/snell-server

    echo -e "${CYAN}正在重启 Snell 服务...${RESET}"
    # 重启主服务
    systemctl restart snell
    if [ $? -ne 0 ]; then
        echo -e "${RED}主服务重启失败，尝试恢复配置...${RESET}"
        restore_snell_config "$backup_dir"
        systemctl restart snell
    fi

    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}✅ Snell 更新完成！${RESET}"
    echo -e "${GREEN}✓ 版本已更新到: ${SNELL_VERSION_CHOICE} (${SNELL_VERSION})${RESET}"
    echo -e "${GREEN}✓ 所有配置已保留${RESET}"
    echo -e "${GREEN}✓ 服务已重启${RESET}"
    echo -e "${YELLOW}配置备份目录: $backup_dir${RESET}"
    echo -e "${CYAN}============================================${RESET}"
}

# 检查 Snell 更新
check_snell_update() {
    echo -e "\n${CYAN}=============== 检查 Snell 更新 ===============${RESET}"
    
    # 检测当前安装的 Snell 版本
    local current_installed_version=$(detect_installed_snell_version)
    if [ "$current_installed_version" = "unknown" ]; then
        echo -e "${RED}无法检测当前 Snell 版本${RESET}"
        return 1
    fi
    
    echo -e "${YELLOW}当前安装版本: Snell ${current_installed_version}${RESET}"
    
    # 根据当前版本确定更新策略
    if [ "$current_installed_version" = "v4" ]; then
        # v4 用户：询问是否升级到 v5
        echo -e "\n${CYAN}检测到您当前使用的是 Snell v4，是否要升级到 v5？${RESET}"
        echo -e "${YELLOW}注意：v5 为测试版本，可能存在兼容性问题${RESET}"
        echo -e "${GREEN}1.${RESET} 升级到 Snell v5"
        echo -e "${GREEN}2.${RESET} 继续使用 Snell v4（检查 v4 更新）"
        echo -e "${GREEN}3.${RESET} 取消更新"
        
        while true; do
            read -rp "请选择 [1-3]: " upgrade_choice
            case "$upgrade_choice" in
                1)
                    SNELL_VERSION_CHOICE="v5"
                    echo -e "${GREEN}已选择升级到 Snell v5${RESET}"
                    break
                    ;;
                2)
                    SNELL_VERSION_CHOICE="v4"
                    echo -e "${GREEN}已选择继续使用 Snell v4${RESET}"
                    break
                    ;;
                3)
                    echo -e "${CYAN}已取消更新${RESET}"
                    return 0
                    ;;
                *)
                    echo -e "${RED}请输入正确的选项 [1-3]${RESET}"
                    ;;
            esac
        done
    else
        # v5 用户：直接检查 v5 更新，无需用户选择
        SNELL_VERSION_CHOICE="v5"
        echo -e "${GREEN}当前为 Snell v5，将检查 v5 更新${RESET}"
    fi
    
    # 获取最新版本信息
    get_latest_snell_version
    get_current_snell_version
    if [ $? -ne 0 ]; then
        return 1
    fi

    echo -e "${YELLOW}当前 Snell 版本: ${CURRENT_VERSION}${RESET}"
    echo -e "${YELLOW}最新 Snell 版本: ${SNELL_VERSION}${RESET}"

    # 检查是否需要更新
    if ! version_greater_equal "$CURRENT_VERSION" "$SNELL_VERSION"; then
        echo -e "\n${CYAN}发现新版本，更新说明：${RESET}"
        echo -e "${GREEN}✓ 这是更新操作，不是重新安装${RESET}"
        echo -e "${GREEN}✓ 所有现有配置将被保留（端口、密码、用户配置）${RESET}"
        echo -e "${GREEN}✓ 服务会自动重启${RESET}"
        echo -e "${GREEN}✓ 配置文件会自动备份${RESET}"
        echo -e "${CYAN}是否更新 Snell? [y/N]${RESET}"
        read -r choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            update_snell_binary
        else
            echo -e "${CYAN}已取消更新。${RESET}"
        fi
    else
        echo -e "${GREEN}当前已是最新版本 (${CURRENT_VERSION})。${RESET}"
    fi
}

# 更新脚本
update_script() {
    echo -e "${CYAN}正在检查脚本更新...${RESET}"
    
    # 创建临时文件
    TMP_SCRIPT=$(mktemp)
    
    # 下载最新版本
    if curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/refs/heads/main/snell-centos.sh -o "$TMP_SCRIPT"; then
        # 获取新版本号
        new_version=$(grep "current_version=" "$TMP_SCRIPT" | cut -d'"' -f2)
        
        if [ -z "$new_version" ]; then
            echo -e "${RED}无法获取新版本信息${RESET}"
            rm -f "$TMP_SCRIPT"
            return 1
        fi
        
        echo -e "${YELLOW}当前版本：${current_version}${RESET}"
        echo -e "${YELLOW}最新版本：${new_version}${RESET}"
        
        # 比较版本号
        if [ "$new_version" != "$current_version" ]; then
            echo -e "${CYAN}是否更新到新版本？[y/N]${RESET}"
            read -r choice
            if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
                # 获取当前脚本的完整路径
                SCRIPT_PATH=$(readlink -f "$0")
                
                # 备份当前脚本
                cp "$SCRIPT_PATH" "${SCRIPT_PATH}.backup"
                
                # 更新脚本
                mv "$TMP_SCRIPT" "$SCRIPT_PATH"
                chmod +x "$SCRIPT_PATH"
                
                echo -e "${GREEN}脚本已更新到最新版本${RESET}"
                echo -e "${YELLOW}已备份原脚本到：${SCRIPT_PATH}.backup${RESET}"
                echo -e "${CYAN}请重新运行脚本以使用新版本${RESET}"
                exit 0
            else
                echo -e "${YELLOW}已取消更新${RESET}"
                rm -f "$TMP_SCRIPT"
            fi
        else
            echo -e "${GREEN}当前已是最新版本${RESET}"
            rm -f "$TMP_SCRIPT"
        fi
    else
        echo -e "${RED}下载新版本失败，请检查网络连接${RESET}"
        rm -f "$TMP_SCRIPT"
    fi
}

# 主菜单
show_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}          Snell 管理脚本 v${current_version}${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}作者: jinqians${RESET}"
    echo -e "${GREEN}网站：https://jinqians.com${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    
    # 显示服务状态
    check_and_show_status
    
    echo -e "${YELLOW}=== 基础功能 ===${RESET}"
    echo -e "${GREEN}1.${RESET} 安装 Snell"
    echo -e "${GREEN}2.${RESET} 卸载 Snell"
    echo -e "${GREEN}3.${RESET} 查看配置"
    echo -e "${GREEN}4.${RESET} 重启服务"
    
    echo -e "\n${YELLOW}=== 系统功能 ===${RESET}"
    echo -e "${GREEN}5.${RESET} 更新Snell"
    echo -e "${GREEN}6.${RESET} 更新脚本"
    echo -e "${GREEN}7.${RESET} 查看服务状态"
    echo -e "${GREEN}0.${RESET} 退出脚本"
    
    echo -e "${CYAN}============================================${RESET}"
    read -rp "请输入选项 [0-7]: " num
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
            show_information
            ;;
        4)
            restart_snell
            ;;
        5)
            check_snell_update
            ;;
        6)
            update_script
            ;;
        7)
            check_and_show_status
            read -p "按任意键继续..."
            ;;
        0)
            echo -e "${GREEN}感谢使用，再见！${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}请输入正确的选项 [0-7]${RESET}"
            ;;
    esac
    echo -e "\n${CYAN}按任意键返回主菜单...${RESET}"
    read -n 1 -s -r
done 
