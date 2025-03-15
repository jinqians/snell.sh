#!/bin/bash
# =========================================
# 作者: jinqians
# 日期: 2025年2月
# 网站：jinqians.com
# 描述: 这个脚本用于统一管理 Snell、SS-Rust 和 ShadowTLS
# =========================================

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 当前版本号
current_version="1.0"

# 检查并安装依赖
check_dependencies() {
    local deps=("bc")
    local need_update=false
    
    echo -e "${CYAN}正在检查依赖...${RESET}"
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo -e "${YELLOW}未检测到 ${dep}，准备安装...${RESET}"
            need_update=true
            break
        fi
    done
    
    if [ "$need_update" = true ]; then
        if [ -x "$(command -v apt)" ]; then
            apt update
            for dep in "${deps[@]}"; do
                if ! command -v "$dep" &> /dev/null; then
                    echo -e "${CYAN}正在安装 ${dep}...${RESET}"
                    apt install -y "$dep"
                fi
            done
        elif [ -x "$(command -v yum)" ]; then
            for dep in "${deps[@]}"; do
                if ! command -v "$dep" &> /dev/null; then
                    echo -e "${CYAN}正在安装 ${dep}...${RESET}"
                    yum install -y "$dep"
                fi
            done
        else
            echo -e "${RED}未支持的包管理器，请手动安装以下依赖：${deps[*]}${RESET}"
            exit 1
        fi
    fi
    
    echo -e "${GREEN}所有依赖已满足${RESET}"
}

# 获取 CPU 使用率
get_cpu_usage() {
    local pid=$1
    local cpu_usage=0
    
    # 获取 CPU 核心数
    local cpu_cores=$(nproc)
    
    # 使用 top 命令获取准确的 CPU 使用率
    if [ ! -z "$pid" ] && [ "$pid" != "0" ]; then
        cpu_usage=$(top -b -n 2 -d 0.2 -p "$pid" | tail -1 | awk '{print $9}')
        # 如果获取失败，使用 ps 命令作为备选
        if [ -z "$cpu_usage" ]; then
            cpu_usage=$(ps -p "$pid" -o %cpu= 2>/dev/null || echo 0)
        fi
        # 将 CPU 使用率除以核心数，得到平均使用率
        cpu_usage=$(echo "scale=2; $cpu_usage / $cpu_cores" | bc -l)
    fi
    
    echo "$cpu_usage"
}

# 检查是否以 root 权限运行
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请以 root 权限运行此脚本${RESET}"
        exit 1
    fi
}

# 检查服务状态并显示
check_and_show_status() {
    # 获取 CPU 核心数
    local cpu_cores=$(nproc)
    
    echo -e "\n${CYAN}=== 服务状态检查 ===${RESET}"
    echo -e "${CYAN}系统 CPU 核心数：${cpu_cores}${RESET}"
    
    # 检查 Snell 状态
    if command -v snell-server &> /dev/null; then
        local user_count=0
        local running_count=0
        local total_snell_memory=0
        local total_snell_cpu=0
        
        # 检查主服务状态
        if systemctl is-active snell &> /dev/null; then
            user_count=$((user_count + 1))
            running_count=$((running_count + 1))
            
            local main_pid=$(systemctl show -p MainPID snell | cut -d'=' -f2)
            if [ ! -z "$main_pid" ] && [ "$main_pid" != "0" ]; then
                local mem=$(ps -o rss= -p $main_pid 2>/dev/null || echo 0)
                local cpu=$(get_cpu_usage "$main_pid")
                total_snell_memory=$((total_snell_memory + ${mem:-0}))
                if [ ! -z "$cpu" ]; then
                    total_snell_cpu=$(echo "$total_snell_cpu + ${cpu:-0}" | bc -l 2>/dev/null || echo "0")
                fi
            fi
        else
            user_count=$((user_count + 1))
        fi
        
        # 检查多用户状态
        if [ -d "/etc/snell/users" ]; then
            for user_conf in "/etc/snell/users"/*; do
                if [ -f "$user_conf" ] && [[ "$user_conf" != *"snell-main.conf" ]]; then
                    local port=$(grep -E '^listen' "$user_conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
                    if [ ! -z "$port" ]; then
                        user_count=$((user_count + 1))
                        if systemctl is-active --quiet "snell-${port}"; then
                            running_count=$((running_count + 1))
                            
                            local user_pid=$(systemctl show -p MainPID "snell-${port}" | cut -d'=' -f2)
                            if [ ! -z "$user_pid" ] && [ "$user_pid" != "0" ]; then
                                local mem=$(ps -o rss= -p $user_pid 2>/dev/null || echo 0)
                                local cpu=$(get_cpu_usage "$user_pid")
                                total_snell_memory=$((total_snell_memory + ${mem:-0}))
                                if [ ! -z "$cpu" ]; then
                                    total_snell_cpu=$(echo "$total_snell_cpu + ${cpu:-0}" | bc -l 2>/dev/null || echo "0")
                                fi
                            fi
                        fi
                    fi
                fi
            done
        fi
        
        # 确保所有数值都有效
        total_snell_memory=${total_snell_memory:-0}
        total_snell_cpu=${total_snell_cpu:-0}
        
        local total_snell_memory_mb=$(echo "scale=2; $total_snell_memory/1024" | bc -l 2>/dev/null || echo "0")
        printf "${GREEN}Snell 已安装${RESET}  ${YELLOW}CPU：%.2f%% (每核)${RESET}  ${YELLOW}内存：%.2f MB${RESET}  ${GREEN}运行中：${running_count}/${user_count}${RESET}\n" "${total_snell_cpu:-0}" "${total_snell_memory_mb:-0}"
    else
        echo -e "${YELLOW}Snell 未安装${RESET}"
    fi
    
    # 检查 SS-2022 状态
    if [[ -e "/usr/local/bin/ss-rust" ]]; then
        local ss_memory=0
        local ss_cpu=0
        local ss_running=0
        
        if systemctl is-active ss-rust &> /dev/null; then
            ss_running=1
            local ss_pid=$(systemctl show -p MainPID ss-rust | cut -d'=' -f2)
            if [ ! -z "$ss_pid" ] && [ "$ss_pid" != "0" ]; then
                ss_memory=$(ps -o rss= -p $ss_pid 2>/dev/null || echo 0)
                ss_cpu=$(get_cpu_usage "$ss_pid")
            fi
        fi
        
        local ss_memory_mb=$(echo "scale=2; $ss_memory/1024" | bc)
        printf "${GREEN}SS-2022 已安装${RESET}  ${YELLOW}CPU：%.2f%% (每核)${RESET}  ${YELLOW}内存：%.2f MB${RESET}  ${GREEN}运行中：${ss_running}/1${RESET}\n" "$ss_cpu" "$ss_memory_mb"
    else
        echo -e "${YELLOW}SS-2022 未安装${RESET}"
    fi
    
    # 检查 ShadowTLS 状态
    if systemctl list-units --type=service | grep -q "shadowtls-"; then
        local stls_total=0
        local stls_running=0
        local total_stls_memory=0
        local total_stls_cpu=0
        
        while IFS= read -r service; do
            stls_total=$((stls_total + 1))
            if systemctl is-active "$service" &> /dev/null; then
                stls_running=$((stls_running + 1))
                
                local stls_pid=$(systemctl show -p MainPID "$service" | cut -d'=' -f2)
                if [ ! -z "$stls_pid" ] && [ "$stls_pid" != "0" ]; then
                    local mem=$(ps -o rss= -p $stls_pid 2>/dev/null || echo 0)
                    local cpu=$(get_cpu_usage "$stls_pid")
                    total_stls_memory=$((total_stls_memory + mem))
                    total_stls_cpu=$(echo "$total_stls_cpu + $cpu" | bc -l)
                fi
            fi
        done < <(systemctl list-units --type=service --all --no-legend | grep "shadowtls-" | awk '{print $1}')
        
        if [ $stls_total -gt 0 ]; then
            local total_stls_memory_mb=$(echo "scale=2; $total_stls_memory/1024" | bc)
            printf "${GREEN}ShadowTLS 已安装${RESET}  ${YELLOW}CPU：%.2f%% (每核)${RESET}  ${YELLOW}内存：%.2f MB${RESET}  ${GREEN}运行中：${stls_running}/${stls_total}${RESET}\n" "$total_stls_cpu" "$total_stls_memory_mb"
        else
            echo -e "${YELLOW}ShadowTLS 未安装${RESET}"
        fi
    else
        echo -e "${YELLOW}ShadowTLS 未安装${RESET}"
    fi
    
    echo -e "${CYAN}====================${RESET}\n"
}

# 更新脚本
update_script() {
    echo -e "${CYAN}正在检查脚本更新...${RESET}"
    
    # 创建临时文件
    TMP_SCRIPT=$(mktemp)
    
    # 下载最新版本
    if curl -sL https://raw.githubusercontent.com/jinqians/menu/main/menu.sh -o "$TMP_SCRIPT"; then
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

# 安装/管理 Snell
manage_snell() {
    bash <(curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/main/snell.sh)
}

# 安装/管理 SS-2022
manage_ss_rust() {
    bash <(curl -sL https://raw.githubusercontent.com/jinqians/ss-2022/main/ss-2022.sh)
}

# 安装/管理 ShadowTLS
manage_shadowtls() {
    bash <(curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/main/shadowtls.sh)
}

# 卸载 Snell
uninstall_snell() {
    echo -e "${CYAN}正在卸载 Snell${RESET}"

    # 停止并禁用主服务
    systemctl stop snell
    systemctl disable snell

    # 停止并禁用所有多用户服务
    if [ -d "/etc/snell/users" ]; then
        for user_conf in "/etc/snell/users"/*; do
            if [ -f "$user_conf" ]; then
                local port=$(grep -E '^listen' "$user_conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
                if [ ! -z "$port" ]; then
                    echo -e "${YELLOW}正在停止用户服务 (端口: $port)${RESET}"
                    systemctl stop "snell-${port}" 2>/dev/null
                    systemctl disable "snell-${port}" 2>/dev/null
                    rm -f "${SYSTEMD_DIR}/snell-${port}.service"
                fi
            fi
        done
    fi

    # 删除服务文件
    rm -f "/lib/systemd/system/${service_name}.service"
    rm -f "${SYSTEMD_DIR}/snell.service"

    # 删除可执行文件和配置目录
    rm -f /usr/local/bin/snell-server
    rm -rf /etc/snell
    rm -f /usr/local/bin/snell  # 删除管理脚本
    
    # 重载 systemd 配置
    systemctl daemon-reload
    
    echo -e "${GREEN}Snell 及其所有多用户配置已成功卸载${RESET}"
}

# 卸载 SS-2022
uninstall_ss_rust() {
    echo -e "${CYAN}正在卸载 SS-2022...${RESET}"
    
    # 停止并禁用服务
    systemctl stop ss-rust 2>/dev/null
    systemctl disable ss-rust 2>/dev/null
    rm -f "/etc/systemd/system/ss-rust.service"
    
    # 删除二进制文件和配置目录
    rm -f "/usr/local/bin/ss-rust"
    rm -rf "/etc/ss-rust"
    
    # 重新加载 systemd
    systemctl daemon-reload
    
    echo -e "${GREEN}SS-2022 卸载完成！${RESET}"
}

# 卸载 ShadowTLS
uninstall_shadowtls() {
    echo -e "${CYAN}正在卸载 ShadowTLS...${RESET}"
    
    # 停止并禁用所有 ShadowTLS 服务
    while IFS= read -r service; do
        systemctl stop "$service" 2>/dev/null
        systemctl disable "$service" 2>/dev/null
        rm -f "/etc/systemd/system/${service}"
    done < <(systemctl list-units --type=service --all --no-legend | grep "shadowtls-" | awk '{print $1}')
    
    # 删除二进制文件
    rm -f "/usr/local/bin/shadow-tls"
    
    # 重新加载 systemd
    systemctl daemon-reload
    
    echo -e "${GREEN}ShadowTLS 卸载完成！${RESET}"
}

# 主菜单
show_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}          统一管理脚本 v${current_version}${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}作者: jinqian${RESET}"
    echo -e "${GREEN}网站：https://jinqians.com${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    
    # 显示服务状态
    check_and_show_status
    
    echo -e "${YELLOW}=== 安装管理 ===${RESET}"
    echo -e "${GREEN}1.${RESET} Snell 安装管理"
    echo -e "${GREEN}2.${RESET} SS-2022 安装管理"
    echo -e "${GREEN}3.${RESET} ShadowTLS 安装管理"
    
    echo -e "\n${YELLOW}=== 卸载功能 ===${RESET}"
    echo -e "${GREEN}4.${RESET} 卸载 Snell"
    echo -e "${GREEN}5.${RESET} 卸载 SS-2022"
    echo -e "${GREEN}6.${RESET} 卸载 ShadowTLS"
    
    echo -e "\n${YELLOW}=== 系统功能 ===${RESET}"
    echo -e "${GREEN}7.${RESET} 更新脚本"
    echo -e "${GREEN}8.${RESET} 流量管理(请勿使用，功能不完善)"
    echo -e "${GREEN}0.${RESET} 退出"
    
    echo -e "${CYAN}============================================${RESET}"
    read -rp "请输入选项 [0-8]: " num
}

# 初始检查
check_root
check_dependencies

# 主循环
while true; do
    show_menu
    case "$num" in
        1)
            manage_snell
            ;;
        2)
            manage_ss_rust
            ;;
        3)
            manage_shadowtls
            ;;
        4)
            uninstall_snell
            ;;
        5)
            uninstall_ss_rust
            ;;
        6)
            uninstall_shadowtls
            ;;
        7)
            update_script
            ;;
        8)
            bash <(curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/main/traffic.sh)
            read -p "按任意键继续..."
            ;;
        0)
            echo -e "${GREEN}感谢使用，再见！${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}请输入正确的选项 [0-8]${RESET}"
            ;;
    esac
    echo -e "\n${CYAN}按任意键返回主菜单...${RESET}"
    read -n 1 -s -r
done 
