#!/bin/bash

# 颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RESET='\033[0m'

# 检查是否以 root 权限运行
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}请以 root 权限运行此脚本。${RESET}"
    return 1
fi

# 检查当前内核版本
check_kernel_version() {
    local version=$(uname -r | cut -d- -f1)
    if [[ $(echo $version | cut -d. -f1) -lt 4 || ($(echo $version | cut -d. -f1) -eq 4 && $(echo $version | cut -d. -f2) -lt 9) ]]; then
        return 1
    fi
    return 0
}

# 配置系统参数和启用 BBR
configure_system_and_bbr() {
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

    if lsmod | grep -q bbr && sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        echo -e "${GREEN}BBR 和系统参数已成功配置。${RESET}"
    else
        echo -e "${RED}BBR 或系统参数配置失败。${RESET}"
    fi
}

# 主函数
main() {
    if check_kernel_version; then
        echo -e "${GREEN}当前内核版本支持 BBR。${RESET}"
        configure_system_and_bbr
    else
        echo -e "${YELLOW}当前内核版本不支持 BBR。需要 4.9 或更高版本。${RESET}"
        echo -e "${YELLOW}请先升级内核后再尝试启用 BBR。${RESET}"
    fi
}

main
