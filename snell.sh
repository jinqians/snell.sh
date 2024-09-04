#!/bin/bash

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

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

# 获取当前安装的 Snell 版本
get_current_snell_version() {
    if command -v snell-server &> /dev/null; then
        CURRENT_VERSION=$(snell-server --version | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+')
    else
        CURRENT_VERSION="未安装"
    fi
}

# 获取最新 Snell 版本
get_latest_snell_version() {
    LATEST_VERSION=$(curl -s https://manual.nssurge.com/others/snell.html | grep -oP 'snell-server-v\K[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    LATEST_VERSION="v$LATEST_VERSION"
}

# 获取 Snell 的下载链接
get_snell_url() {
    ARCH=$(uname -m)
    if [[ ${ARCH} == "aarch64" ]]; then
        SNELL_URL="https://dl.nssurge.com/snell/snell-server-${LATEST_VERSION}-linux-aarch64.zip"
    else
        SNELL_URL="https://dl.nssurge.com/snell/snell-server-${LATEST_VERSION}-linux-amd64.zip"
    fi
}

# 安装 Snell
install_snell() {
    echo -e "${CYAN}正在安装 Snell${RESET}"

    wait_for_apt
    apt update && apt install -y wget unzip

    get_latest_snell_version
    get_snell_url

    wget ${SNELL_URL} -O snell-server.zip
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载 Snell 失败。${RESET}"
        exit 1
    fi

    unzip -o snell-server.zip -d /usr/local/bin/
    if [ $? -ne 0 ]; then
        echo -e "${RED}解压缩 Snell 失败。${RESET}"
        exit 1
    fi

    rm snell-server.zip
    chmod +x /usr/local/bin/snell-server

    RANDOM_PORT=$(shuf -i 30000-65000 -n 1)
    RANDOM_PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)

    CONF_DIR="/etc/snell"
    CONF_FILE="${CONF_DIR}/snell-server.conf"
    mkdir -p ${CONF_DIR}

    cat > ${CONF_FILE} << EOF
[snell-server]
listen = ::0:${RANDOM_PORT}
psk = ${RANDOM_PSK}
ipv6 = true
EOF

    cat > /lib/systemd/system/snell.service << EOF
[Unit]
Description=Snell Proxy Service
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
LimitNOFILE=32768
ExecStart=/usr/local/bin/snell-server -c ${CONF_FILE}
AmbientCapabilities=CAP_NET_BIND_SERVICE
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=snell-server

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable snell
    systemctl start snell

    HOST_IP=$(curl -s http://checkip.amazonaws.com)
    IP_COUNTRY=$(curl -s http://ipinfo.io/${HOST_IP}/country)

    echo -e "${GREEN}Snell 安装成功${RESET}"
    echo "${IP_COUNTRY} = snell, ${HOST_IP}, ${RANDOM_PORT}, psk = ${RANDOM_PSK}, version = ${LATEST_VERSION}, reuse = true, tfo = true"
}

# 升级 Snell
upgrade_snell() {
    get_current_snell_version
    get_latest_snell_version

    if [ "$CURRENT_VERSION" == "$LATEST_VERSION" ]; then
        echo -e "${GREEN}Snell 已是最新版本 ($CURRENT_VERSION)，无需升级。${RESET}"
    else
        echo -e "${CYAN}当前版本: $CURRENT_VERSION${RESET}"
        echo -e "${CYAN}最新版本: $LATEST_VERSION${RESET}"
        echo -e "${CYAN}正在升级 Snell...${RESET}"

        systemctl stop snell
        get_snell_url

        wget ${SNELL_URL} -O snell-server.zip
        if [ $? -ne 0 ]; then
            echo -e "${RED}下载 Snell 失败。${RESET}"
            exit 1
        fi

        unzip -o snell-server.zip -d /usr/local/bin/
        if [ $? -ne 0 ]; then
            echo -e "${RED}解压缩 Snell 失败。${RESET}"
            exit 1
        fi

        rm snell-server.zip
        chmod +x /usr/local/bin/snell-server

        systemctl start snell
        echo -e "${GREEN}Snell 升级成功至版本 $LATEST_VERSION${RESET}"
    fi
}

# 卸载 Snell
uninstall_snell() {
    echo -e "${CYAN}正在卸载 Snell${RESET}"

    systemctl stop snell
    systemctl disable snell
    rm /lib/systemd/system/snell.service
    rm /usr/local/bin/snell-server
    rm -rf /etc/snell

    echo -e "${GREEN}Snell 卸载成功${RESET}"
}

# 查看 Snell 配置
view_snell_config() {
    if [ -f /etc/snell/snell-server.conf ]; then
        CONF_CONTENT=$(cat /etc/snell/snell-server.conf)
        HOST_IP=$(curl -s http://checkip.amazonaws.com)
        IP_COUNTRY=$(curl -s http://ipinfo.io/${HOST_IP}/country)
        PORT=$(grep 'listen' /etc/snell/snell-server.conf | cut -d: -f3)
        PSK=$(grep 'psk' /etc/snell/snell-server.conf | cut -d' ' -f3)
        echo -e "${GREEN}当前 Snell 配置:${RESET}"
        echo "${CONF_CONTENT}"
        echo "${IP_COUNTRY} = snell, ${HOST_IP}, ${PORT}, psk = ${PSK}, version = 4, reuse = true, tfo = true"
    else
        echo -e "${RED}Snell 配置文件不存在。${RESET}"
    fi
}

# 显示菜单
show_menu() {
    clear
    get_current_snell_version
    check_snell_installed
    snell_status=$?
    echo -e "${GREEN}=================author: jinqian==================${RESET}"
    echo -e "${GREEN}=================website: https://jinqians.com==================${RESET}"
    echo -e "${GREEN}=== Snell 管理工具 ===${RESET}"
    echo -e "${GREEN}当前状态: $(if [ ${snell_status} -eq 0 ]; then echo "${GREEN}已安装${RESET}"; else echo "${RED}未安装${RESET}"; fi)${RESET}"
    echo "1. 安装 Snell"
    echo "2. 升级 Snell"
    echo "3. 卸载 Snell"
    echo "4. 查看 Snell 配置"
    echo "0. 退出"
    echo -e "${GREEN}======================${RESET}"
    read -p "请输入选项编号: " choice
    echo ""
}

# 主循环
while true; do
    show_menu
    case $choice in
        1)
            check_root
            install_snell
            ;;
        2)
            check_root
            upgrade_snell
            ;;
        3)
            check_root
            uninstall_snell
            ;;
        4)
            view_snell_config
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项，请重新输入.${RESET}"
            ;;
    esac
    read -p "按任意键返回菜单..."
done
