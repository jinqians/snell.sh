#!/bin/bash

# 颜色代码
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

# 检查系统类型
check_system() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" != "debian" ] && [ "$ID" != "ubuntu" ]; then
            echo -e "${RED}当前系统不支持，仅支持 Debian 和 Ubuntu。${RESET}"
            exit 1
        fi
    else
        echo -e "${RED}无法确定操作系统类型。${RESET}"
        exit 1
    fi
}

# 检查并添加交换空间
check_swap() {
    if [ "$(free -m | awk '/^Swap:/ {print $2}')" -eq "0" ]; then
        echo -e "${YELLOW}检测到系统无交换空间，正在添加...${RESET}"
        dd if=/dev/zero of=/swapfile bs=1M count=1024
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        echo -e "${GREEN}已添加 1GB 交换空间。${RESET}"
    fi
}

# 检查当前内核版本和 BBR 支持情况
check_bbr_support() {
    local kernel_version=$(uname -r)
    echo -e "${CYAN}当前内核版本: ${kernel_version}${RESET}"

    if lsmod | grep -q tcp_bbr; then
        echo -e "${GREEN}BBR 已经启用。${RESET}"
        return 0
    elif [[ $(echo $kernel_version | cut -d. -f1) -ge 4 && $(echo $kernel_version | cut -d. -f2) -ge 9 ]]; then
        echo -e "${GREEN}当前内核支持 BBR。${RESET}"
        return 0
    else
        echo -e "${YELLOW}当前内核版本不支持 BBR。需要 4.9 或更高版本。${RESET}"
        return 1
    fi
}

# 检查 BBR3 支持情况
check_bbr3_support() {
    if grep -q "bbr3" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        echo -e "${GREEN}当前内核支持 BBR3。${RESET}"
        return 0
    else
        echo -e "${YELLOW}当前内核不支持 BBR3。需要安装支持 BBR3 的内核。${RESET}"
        return 1
    fi
}

# 配置系统参数和启用 BBR/BBR3
configure_system_and_bbr() {
    local bbr_version=$1
    cat > /etc/sysctl.conf << EOF
fs.file-max = 6815744
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_frto=0
net.ipv4.tcp_mtu_probing=0
net.ipv4.tcp_rfc1337=0
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=1
net.ipv4.tcp_moderate_rcvbuf=1
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 16384 33554432
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
net.ipv4.ip_forward=1
net.ipv4.conf.all.route_localnet=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.default.forwarding=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
EOF

    sysctl -p

    if lsmod | grep -q tcp_bbr && sysctl net.ipv4.tcp_congestion_control | grep -q $bbr_version; then
        echo -e "${GREEN}$bbr_version 和系统参数已成功配置。${RESET}"
    else
        echo -e "${RED}$bbr_version 或系统参数配置失败。${RESET}"
    fi
}

# 安装 XanMod 内核
install_xanmod_kernel() {
    echo -e "${YELLOW}正在安装 XanMod 内核...${RESET}"
    
    # 添加 XanMod 仓库
    wget -qO - https://dl.xanmod.org/gpg.key | apt-key add -
    echo 'deb http://deb.xanmod.org releases main' | tee /etc/apt/sources.list.d/xanmod-kernel.list
    
    # 检测 CPU 兼容性版本
    local version=$(wget -qO- https://dl.xanmod.org/check_x86-64_psabi.sh | bash)
    
    # 更新包列表并安装 XanMod 内核
    apt update
    apt install -y linux-xanmod-x64v$version
    
    # 更新 GRUB
    update-grub
    
    echo -e "${GREEN}XanMod 内核安装完成。请重启系统后再次运行此脚本以启用 BBR3。${RESET}"
}

# 更新 XanMod 内核
update_xanmod_kernel() {
    echo -e "${YELLOW}正在更新 XanMod 内核...${RESET}"
    apt update
    apt upgrade -y 'linux-*xanmod*'
    update-grub
    echo -e "${GREEN}XanMod 内核已更新。请重启系统以使用新内核。${RESET}"
}

# 卸载 XanMod 内核
uninstall_xanmod_kernel() {
    echo -e "${YELLOW}正在卸载 XanMod 内核...${RESET}"
    apt purge -y 'linux-*xanmod*'
    update-grub
    echo -e "${GREEN}XanMod 内核已卸载。请重启系统以使用默认内核。${RESET}"
}

main_menu() {
    while true; do
        echo -e "${CYAN}BBR 管理脚本${RESET}"
        echo "------------------------"
        echo "1. 检查 BBR 支持状态"
        echo "2. 启用 BBR"
        echo "3. 安装 XanMod 内核并启用 BBR3"
        echo "4. 更新 XanMod 内核"
        echo "5. 卸载 XanMod 内核"
        echo "0. 返回上一级菜单"
        echo "------------------------"
        read -p "请输入选项 [0-5]: " choice

        case $choice in
            1)
                check_bbr_support
                check_bbr3_support
                ;;
            2)
                if check_bbr_support; then
                    configure_system_and_bbr "bbr"
                else
                    echo -e "${YELLOW}当前内核不支持 BBR，请先更新内核。${RESET}"
                fi
                ;;
            3)
                check_system
                check_swap
                install_xanmod_kernel
                configure_system_and_bbr "bbr3"
                echo -e "${YELLOW}请重启系统以应用更改。${RESET}"
                ;;
            4)
                if dpkg -l | grep -q 'linux-xanmod'; then
                    update_xanmod_kernel
                else
                    echo -e "${YELLOW}未检测到 XanMod 内核，请先安装。${RESET}"
                fi
                ;;
            5)
                if dpkg -l | grep -q 'linux-xanmod'; then
                    uninstall_xanmod_kernel
                else
                    echo -e "${YELLOW}未检测到 XanMod 内核，无需卸载。${RESET}"
                fi
                ;;
            0)
                echo -e "${GREEN}正在返回上一级菜单...${RESET}"
                return 0
                ;;
            *)
                echo -e "${RED}无效选项，请重新输入。${RESET}"
                ;;
        esac

        echo
        read -p "按回车键继续..."
    done
}

# 主函数
main() {
    check_system
    main_menu
    return 0
}

# 运行主函数
main
