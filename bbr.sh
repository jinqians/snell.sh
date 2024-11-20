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

# 检查并安装 sudo
check_and_install_sudo() {
    if ! command -v sudo &> /dev/null; then
        echo -e "${YELLOW}sudo 未安装，正在尝试安装...${RESET}"
        apt update
        apt install -y sudo
        if ! command -v sudo &> /dev/null; then
            echo -e "${RED}sudo 安装失败。脚本将以 root 权限继续执行。${RESET}"
            return 1
        else
            echo -e "${GREEN}sudo 安装成功。${RESET}"
            return 0
        fi
    else
        return 0
    fi
}
check_and_install_sudo

# 检查并安装必要的包
check_and_install_packages() {
    local packages=("wget" "gnupg" "software-properties-common")
    for package in "${packages[@]}"; do
        if ! command -v $package &> /dev/null; then
            echo -e "${YELLOW}$package 未安装，正在尝试安装...${RESET}"
            sudo apt update
            sudo apt install -y $package
            if ! command -v $package &> /dev/null; then
                echo -e "${RED}$package 安装失败。${RESET}"
                return 1
            else
                echo -e "${GREEN}$package 安装成功。${RESET}"
            fi
        fi
    done
    return 0
}
check_and_install_packages

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

check_and_enable_bbr() {
    local kernel_version=$(uname -r | cut -d'-' -f1)
    echo -e "${CYAN}当前内核版本: ${kernel_version}${RESET}"

    if [[ $(echo -e "4.9\n$kernel_version" | sort -V | head -n1) == "4.9" ]]; then
        if lsmod | grep -q tcp_bbr && sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
            echo -e "${GREEN}BBR 已经启用，无需进一步操作。${RESET}"
        else
            echo -e "${YELLOW}当前内核支持 BBR，但未启用。正在启用 BBR...${RESET}"
            configure_system_and_bbr
        fi
    else
        echo -e "${YELLOW}当前内核版本不支持 BBR。需要 4.9 或更高版本。${RESET}"
        read -p "是否要更新内核以支持 BBR？(y/n): " update_choice
        if [[ $update_choice == "y" || $update_choice == "Y" ]]; then
            update_kernel_for_bbr
        else
            echo -e "${YELLOW}已取消更新内核，BBR 将无法启用。${RESET}"
        fi
    fi
}

update_kernel_for_bbr() {
    echo -e "${YELLOW}正在更新内核以支持 BBR...${RESET}"
    # 这里添加更新内核的具体步骤
    apt update
    apt install -y linux-generic
    update-grub
    echo -e "${GREEN}内核已更新。请重启系统后再次运行此脚本以启用 BBR。${RESET}"
}

# 检查 BBR v3 支持
check_bbr3_support() {
    local kernel_version=$(uname -r)
    if [[ $(echo $kernel_version | cut -d. -f1) -ge 6 && $(echo $kernel_version | cut -d. -f2) -ge 4 ]]; then
        if lsmod | grep -q tcp_bbr && sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
            echo -e "${GREEN}当前内核已支持 BBR v3。${RESET}"
            return 0
        fi
    fi
    echo -e "${YELLOW}当前内核不支持 BBR v3。需要 6.4 或更高版本的内核。${RESET}"
    return 1
}

# 安装支持 BBR v3 的最新 XanMod 内核
install_xanmod_kernel() {
    echo -e "${YELLOW}正在安装支持 BBR v3 的最新 XanMod 内核...${RESET}"
    
    # 添加 XanMod 仓库的 GPG 密钥
    if ! wget -qO - https://dl.xanmod.org/gpg.key | sudo gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg; then
        echo -e "${RED}下载或导入 XanMod GPG 密钥失败。${RESET}"
        return 1
    fi

    # 添加 XanMod 仓库
    if ! echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' | sudo tee /etc/apt/sources.list.d/xanmod-release.list > /dev/null; then
        echo -e "${RED}添加 XanMod 仓库失败。${RESET}"
        return 1
    fi

    # 手动添加 XanMod 的 GPG 密钥
    if ! sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 86F7D09EE734E623; then
        echo -e "${RED}手动添加 XanMod GPG 密钥失败。${RESET}"
        return 1
    fi
    
    # 更新包列表
    if ! sudo apt update; then
        echo -e "${RED}更新包列表失败。${RESET}"
        return 1
    fi

    # 安装最新的 XanMod 内核
    if ! sudo apt install -y linux-xanmod-x64v4; then
        echo -e "${RED}安装 XanMod 内核失败。${RESET}"
        return 1
    fi
    
    # 更新 GRUB
    if ! sudo update-grub; then
        echo -e "${RED}更新 GRUB 失败。${RESET}"
        return 1
    fi
    
    echo -e "${GREEN}支持 BBR v3 的 XanMod 内核安装完成。${RESET}"
    echo -e "${YELLOW}请重启系统后，BBR v3 将可以启用。${RESET}"
    return 0
}

# 配置系统参数和启用 BBR/BBR3
configure_system_and_bbr() {
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

# 启用 BBR3
# 启用 BBR v3
enable_bbr3() {
    if check_bbr3_support; then
        configure_system_and_bbr
        echo -e "${GREEN}BBR v3 已启用，请重启系统以使更改生效。${RESET}"
    else
        echo -e "${YELLOW}当前内核不支持 BBR v3，需要安装支持 BBR v3 的最新 XanMod 内核。${RESET}"
        read -p "是否安装支持 BBR v3 的最新 XanMod 内核？(y/n): " install_choice
        if [[ $install_choice == "y" || $install_choice == "Y" ]]; then
            check_system
            check_swap
            install_xanmod_kernel
            configure_system_and_bbr
            echo -e "${YELLOW}支持 BBR v3 的 XanMod 内核已安装并配置。${RESET}"
            
            read -p "是否立即重启系统以应用更改？(y/n): " reboot_choice
            if [[ $reboot_choice == "y" || $reboot_choice == "Y" ]]; then
                echo -e "${GREEN}系统将在 3 秒后重启...${RESET}"
                sleep 3
                reboot
            else
                echo -e "${YELLOW}请记得稍后手动重启系统以使 BBR v3 生效。${RESET}"
            fi
        else
            echo -e "${YELLOW}已取消安装 XanMod 内核。${RESET}"
        fi
    fi
}

# 主菜单
# 主菜单
main_menu() {
    while true; do
        echo -e "${CYAN}BBR 管理脚本${RESET}"
        echo "------------------------"
        echo "1. 启用 BBR"
        echo "2. 启用 BBR v3"
        echo "0. 返回上一级菜单"
        echo "------------------------"
        read -p "请输入选项 [0-2]: " choice

        case $choice in
            1)
                check_and_enable_bbr
                ;;
            2)
                enable_bbr3
                ;;
            0)
                echo -e "${GREEN}正在返回上一级菜单...${RESET}"
                return 0
                ;;
            *)
                echo -e "${RED}无效选项，请重新输入。${RESET}"
                ;;
        esac
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
