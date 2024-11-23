#!/bin/bash
# =========================================
# 作者: jinqians
# 日期: 2024年11月
# 网站：jinqians.com
# 描述: 这个脚本用于配置bbr
# =========================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 检查是否以 root 权限运行
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}请以 root 权限运行此脚本。${RESET}"
    exit 1
fi

# 配置系统参数和启用 BBR
configure_system_and_bbr() {
    echo -e "${YELLOW}配置系统参数和BBR...${RESET}"
    
    cat > /etc/sysctl.conf << EOF
fs.file-max = 6815744
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_frto = 0
net.ipv4.tcp_mtu_probing = 0
net.ipv4.tcp_rfc1337 = 0
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.ip_forward = 1
net.ipv4.conf.all.route_localnet = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
EOF

    sysctl -p

    if lsmod | grep -q tcp_bbr && sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        echo -e "${GREEN}BBR 和系统参数已成功配置。${RESET}"
    else
        echo -e "${YELLOW}BBR 或系统参数配置可能需要重启系统才能生效。${RESET}"
    fi
}

# 启用标准BBR
enable_bbr() {
    echo -e "${YELLOW}正在启用标准BBR...${RESET}"
    
    # 检查是否已启用
    if lsmod | grep -q "^tcp_bbr" && sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        echo -e "${GREEN}BBR 已经启用。${RESET}"
        return 0
    fi
    
    configure_system_and_bbr
}

# 安装 XanMod BBR v3
install_xanmod_bbr() {
    echo -e "${YELLOW}准备安装 XanMod 内核...${RESET}"
    
    # 检查架构
    if [ "$(uname -m)" != "x86_64" ]; then
        echo -e "${RED}错误: 仅支持x86_64架构${RESET}"
        return 1
    fi
    
    # 检查系统
    if ! grep -Eqi "debian|ubuntu" /etc/os-release; then
        echo -e "${RED}错误: 仅支持Debian/Ubuntu系统${RESET}"
        return 1
    fi
    
    # 注册PGP密钥
    wget -qO - https://dl.xanmod.org/archive.key | gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg --yes
    
    # 添加存储库
    echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' | tee /etc/apt/sources.list.d/xanmod-release.list
    
    # 更新包列表
    apt update -y
    
    # 尝试安装最新版本
    echo -e "${YELLOW}尝试安装最新版本内核...${RESET}"
    if apt install -y linux-xanmod-x64v4; then
        echo -e "${GREEN}成功安装最新版本内核${RESET}"
    else
        echo -e "${YELLOW}最新版本安装失败，尝试安装较低版本...${RESET}"
        if apt install -y linux-xanmod-x64v2; then
            echo -e "${GREEN}成功安装兼容版本内核${RESET}"
        else
            echo -e "${RED}内核安装失败${RESET}"
            return 1
        fi
    fi
    
    configure_system_and_bbr
    
    echo -e "${GREEN}XanMod内核安装完成，请重启系统以使用新内核${RESET}"
    read -p "是否现在重启系统？[y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        reboot
    fi
}

# 手动编译安装BBR v3
install_bbr3_manual() {
    echo -e "${YELLOW}准备手动编译安装BBR v3...${RESET}"
    
    # 安装编译依赖
    apt update
    apt install -y build-essential git
    
    # 克隆源码
    git clone -b v3 https://github.com/google/bbr.git
    cd bbr
    
    # 编译安装
    make
    make install
    
    configure_system_and_bbr
    
    echo -e "${GREEN}BBR v3 编译安装完成${RESET}"
    read -p "是否现在重启系统？[y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        reboot
    fi
}

# 主菜单
main_menu() {
    while true; do
        echo -e "\n${CYAN}BBR 管理菜单${RESET}"
        echo -e "${YELLOW}1. 启用标准 BBR${RESET}"
        echo -e "${YELLOW}2. 安装 BBR v3 (XanMod版本)${RESET}"
        echo -e "${YELLOW}3. 安装 BBR v3 (手动编译)${RESET}"
        echo -e "${YELLOW}4. 返回上级菜单${RESET}"
        echo -e "${YELLOW}5. 退出脚本${RESET}"
        read -p "请选择操作 [1-5]: " choice

        case "$choice" in
            1)
                enable_bbr
                ;;
            2)
                install_xanmod_bbr
                ;;
            3)
                install_bbr3_manual
                ;;
            4)
                return 0
                ;;
            5)
                exit 0
                ;;
            *)
                echo -e "${RED}无效的选择${RESET}"
                ;;
        esac
    done
}

# 运行主菜单
main_menu
