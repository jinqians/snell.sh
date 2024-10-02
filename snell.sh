#!/bin/bash
# =========================================
# 作者: jinqian
# 日期: 2024年9月
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
current_version="1.0.1"

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

    RANDOM_PORT=$(shuf -i 30000-65000 -n 1)
    RANDOM_PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)

    mkdir -p ${SNELL_CONF_DIR}

    cat > ${SNELL_CONF_FILE} << EOF
[snell-server]
listen = ::0:${RANDOM_PORT}
psk = ${RANDOM_PSK}
ipv6 = true
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

    HOST_IP=$(curl -s http://checkip.amazonaws.com)
    IP_COUNTRY=$(curl -s http://ipinfo.io/${HOST_IP}/country)

    echo -e "${GREEN}Snell 安装成功${RESET}"
    echo "${IP_COUNTRY} = snell, ${HOST_IP}, ${RANDOM_PORT}, psk = ${RANDOM_PSK}, version = 4, reuse = true, tfo = true"
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

    echo -e "${GREEN}Snell 卸载成功${RESET}"
}

view_snell_config() {
    if [ -f "${SNELL_CONF_FILE}" ]; then
        echo -e "${GREEN}当前 Snell 配置:${RESET}"
        cat "${SNELL_CONF_FILE}"
        
        # 解析配置文件中的信息
        HOST_IP=$(curl -s http://checkip.amazonaws.com)
        IP_COUNTRY=$(curl -s http://ipinfo.io/${HOST_IP}/country)
        
        # 提取端口号 - 提取 "::0:" 后面的部分
        PORT=$(grep -E '^listen' "${SNELL_CONF_FILE}" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
        
        # 提取 PSK
        PSK=$(grep -E '^psk' "${SNELL_CONF_FILE}" | awk -F'=' '{print $2}' | tr -d ' ')
        
        echo -e "${GREEN}解析后的配置:${RESET}"
        echo "外网IP: ${HOST_IP}"
        echo "所在国家: ${IP_COUNTRY}"
        echo "端口: ${PORT}"
        echo "PSK: ${PSK}"
        
        # 检查端口号和 PSK 是否正确提取
        if [ -z "${PORT}" ]; then
            echo -e "${RED}端口解析失败，请检查配置文件。${RESET}"
        fi
        
        if [ -z "${PSK}" ]; then
            echo -e "${RED}PSK 解析失败，请检查配置文件。${RESET}"
        fi
        
        echo -e "${GREEN}${IP_COUNTRY} = snell, ${HOST_IP}, ${PORT}, psk = ${PSK}, version = 4, reuse = true, tfo = true${RESET}"
        
        # 等待用户按任意键返回主菜单
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


# 主菜单
while true; do
    echo -e "${RED} ========================================= ${RESET}"
    echo -e "${RED} 作者: jinqian ${RESET}"
    echo -e "${RED} 网站：https://jinqians.com ${RESET}"
    echo -e "${RED} 描述: 这个脚本用于安装、卸载、查看和更新 Snell 代理 ${RESET}"
    echo -e "${RED} ========================================= ${RESET}"


    echo -e "${CYAN} ============== Snell 管理工具 ============== ${RESET}"
    echo "1) 安装 Snell"
    echo "2) 卸载 Snell"
    echo "3) 查看 Snell 配置"
    echo "4) 检查 Snell 更新"
    echo "0) 退出"
    read -rp "请选择操作: " choice

    case "$choice" in
        1)
            install_snell
            ;;
        2)
            uninstall_snell
            ;;
        3)
            view_snell_config
            ;;
        4)
            check_snell_update
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项，请重试。${RESET}"
            ;;
    esac
done
