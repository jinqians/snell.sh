#!/bin/bash
# =========================================
# 作者: jinqians
# 日期: 2026年7月
# 网站：jinqians.com
# 描述: 这个脚本用于统一管理 Snell、SS-Rust 和 ShadowTLS（将逐步和snell管理菜单分开）
# =========================================

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 当前版本号
current_version="4.4"

# systemd 服务目录
SYSTEMD_DIR="/etc/systemd/system"

# 中国大陆屏蔽脚本仓库地址
MAINLAND_BLOCK_URL="https://raw.githubusercontent.com/jinqians/ss-2022.sh/refs/heads/main/block-mainland.sh"
MAINLAND_EXTRACT_URL="https://raw.githubusercontent.com/jinqians/ss-2022.sh/refs/heads/main/extract-cn-ip-from-mmdb.py"
MAINLAND_SCRIPT_DIR="/usr/local/share/ss-2022"

# 安装全局命令
install_global_command() {
    echo -e "${CYAN}正在安装全局命令...${RESET}"

    # 先下载到临时文件，校验通过后再覆盖目标文件，避免下载失败破坏现有 menu 命令
    local tmp_file
    tmp_file=$(mktemp /tmp/menu_download.XXXXXX) || { echo -e "${RED}无法创建临时文件${RESET}"; return 1; }
    if ! curl -fsSL "https://menu.jinqians.com" -o "$tmp_file"; then
        echo -e "${RED}下载 menu 脚本失败，请检查网络连接${RESET}"
        rm -f "$tmp_file"
        return 1
    fi
    if [ ! -s "$tmp_file" ]; then
        echo -e "${RED}下载的 menu 脚本为空，已丢弃${RESET}"
        rm -f "$tmp_file"
        return 1
    fi
    if ! bash -n "$tmp_file" 2>/dev/null; then
        echo -e "${RED}下载的 menu 脚本未通过语法检查，已丢弃${RESET}"
        rm -f "$tmp_file"
        return 1
    fi

    mv -f "$tmp_file" "/usr/local/bin/menu.sh"
    chmod +x "/usr/local/bin/menu.sh"
    
    # 创建软链接
    if [ -f "/usr/local/bin/menu" ]; then
        rm -f "/usr/local/bin/menu"
    fi
    ln -s "/usr/local/bin/menu.sh" "/usr/local/bin/menu"
    
    echo -e "${GREEN}安装成功！现在您可以在任何位置使用 'menu' 命令来启动管理脚本${RESET}"
}

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
                    local port=$(grep -E '^listen' "$user_conf" | sed -n 's/.*:\([0-9][0-9]*\)[[:space:]]*$/\1/p')
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
    bash <(curl -sL https://raw.githubusercontent.com/jinqians/ss-2022.sh/main/ss-2022.sh)
}

# 管理中国大陆IP屏蔽
manage_mainland_block() {
    echo -e "${CYAN}正在从仓库获取大陆IP屏蔽脚本...${RESET}"

    mkdir -p "${MAINLAND_SCRIPT_DIR}"

    if ! curl -fL -s "${MAINLAND_BLOCK_URL}" -o "${MAINLAND_SCRIPT_DIR}/block-mainland.sh"; then
        echo -e "${RED}下载 block-mainland.sh 失败${RESET}"
        return 1
    fi

    if ! curl -fL -s "${MAINLAND_EXTRACT_URL}" -o "${MAINLAND_SCRIPT_DIR}/extract-cn-ip-from-mmdb.py"; then
        echo -e "${RED}下载 extract-cn-ip-from-mmdb.py 失败${RESET}"
        return 1
    fi

    chmod +x "${MAINLAND_SCRIPT_DIR}/block-mainland.sh" "${MAINLAND_SCRIPT_DIR}/extract-cn-ip-from-mmdb.py"
    PYTHONIOENCODING=UTF-8 bash "${MAINLAND_SCRIPT_DIR}/block-mainland.sh"
}

# 安装/管理 ShadowTLS
manage_shadowtls() {
    bash <(curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/main/shadowtls.sh)
}

# 安装/管理 VLESS Reality（已整合到 PSM）
manage_vless() {
    echo -e "${CYAN}VLESS Reality 的安装管理已由 PSM（Proxy Stack Manager）提供，正在启动 PSM...${RESET}"
    if ! bash <(curl -fsSL https://psm.jinqians.com); then
        echo -e "${RED}PSM 启动失败，请检查网络后重试，或手动执行：bash <(curl -fsSL https://psm.jinqians.com)${RESET}"
        return 1
    fi
}
save_nftables_rules() {
    if ! command -v nft >/dev/null 2>&1; then
        return
    fi

    if [ -f "/etc/nftables.conf" ]; then
        nft list ruleset > /etc/nftables.conf 2>/dev/null || true
        systemctl enable nftables >/dev/null 2>&1 || true
    elif [ -f "/etc/sysconfig/nftables.conf" ]; then
        nft list ruleset > /etc/sysconfig/nftables.conf 2>/dev/null || true
        systemctl enable nftables >/dev/null 2>&1 || true
    fi
}

close_nftables_port() {
    local port=$1

    if ! command -v nft >/dev/null 2>&1; then
        return
    fi

    nft -a list ruleset 2>/dev/null | awk -v port="$port" '
        $1 == "table" {
            family=$2
            table=$3
            gsub(/[{}]/, "", table)
        }
        $1 == "chain" {
            chain=$2
            gsub(/[{}]/, "", chain)
        }
        ($0 ~ "tcp dport " port " .*accept" || $0 ~ "udp dport " port " .*accept") && /# handle/ {
            handle=$NF
            print family " " table " " chain " " handle
        }
    ' | while read -r family table chain handle; do
        [ -z "$handle" ] && continue
        nft delete rule "$family" "$table" "$chain" handle "$handle" 2>/dev/null || true
    done

    save_nftables_rules
}

close_port() {
    local port=$1

    if command -v ufw >/dev/null 2>&1; then
        ufw delete allow "$port"/tcp >/dev/null 2>&1 || true
        ufw delete allow "$port"/udp >/dev/null 2>&1 || true
    fi

    if command -v iptables >/dev/null 2>&1; then
        iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
        if [ -d "/etc/iptables" ]; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
    fi

    close_nftables_port "$port"
}

# 卸载 Snell
uninstall_snell() {
    echo -e "${CYAN}正在卸载 Snell${RESET}"

    # 停止并删除依赖 Snell 后端的 ShadowTLS 服务，避免留下无后端的监听服务
    local snell_shadowtls_services
    snell_shadowtls_services=$(find "${SYSTEMD_DIR}" -maxdepth 1 -name "shadowtls-snell-*.service" 2>/dev/null)
    if [ -n "$snell_shadowtls_services" ]; then
        while IFS= read -r service_file; do
            [ -z "$service_file" ] && continue
            local service_name
            service_name=$(basename "$service_file")
            local shadowtls_port
            shadowtls_port=$(sed -n 's/.*--listen .*:\([0-9][0-9]*\).*/\1/p' "$service_file" | head -n 1)
            echo -e "${YELLOW}正在停止 ShadowTLS 服务 (${service_name})${RESET}"
            systemctl stop "$service_name" 2>/dev/null
            systemctl disable "$service_name" 2>/dev/null
            rm -f "$service_file"
            if [ -n "$shadowtls_port" ]; then
                close_port "$shadowtls_port"
            fi
        done <<< "$snell_shadowtls_services"
    fi

    # 停止并禁用主服务
    systemctl stop snell 2>/dev/null
    systemctl disable snell 2>/dev/null
    systemctl stop snell.socket 2>/dev/null
    systemctl disable snell.socket 2>/dev/null
    systemctl stop snell-netns 2>/dev/null
    systemctl disable snell-netns 2>/dev/null

    # 停止并禁用所有多用户服务
    if [ -d "/etc/snell/users" ]; then
        for user_conf in "/etc/snell/users"/*; do
            if [ -f "$user_conf" ]; then
                local port=$(grep -E '^listen' "$user_conf" | sed -n 's/.*:\([0-9][0-9]*\)[[:space:]]*$/\1/p')
                if [ ! -z "$port" ]; then
                    echo -e "${YELLOW}正在停止用户服务 (端口: $port)${RESET}"
                    systemctl stop "snell-${port}" 2>/dev/null
                    systemctl disable "snell-${port}" 2>/dev/null
                    rm -f "${SYSTEMD_DIR}/snell-${port}.service"
                    close_port "$port"
                fi
            fi
        done
    fi

    # 删除服务文件
    rm -f "/lib/systemd/system/snell.service"
    rm -f "${SYSTEMD_DIR}/snell.service"
    rm -f "${SYSTEMD_DIR}/snell.socket"
    rm -f "${SYSTEMD_DIR}/snell-netns.service"
    rm -f "/usr/local/bin/snell-netns-setup.sh"

    # 删除可执行文件和配置目录
    rm -f /usr/local/bin/snell-server
    rm -rf /etc/snell
    rm -f /usr/local/bin/snell  # 删除管理脚本

    if ! find "${SYSTEMD_DIR}" -maxdepth 1 -name "shadowtls-*.service" 2>/dev/null | grep -q .; then
        rm -f /usr/local/bin/shadow-tls
    fi

    # 重载 systemd 配置
    systemctl daemon-reload

    echo -e "${GREEN}Snell 及其所有多用户配置已成功卸载${RESET}"
}

# 卸载 SS-2022
uninstall_ss_rust() {
    echo -e "${CYAN}正在卸载 SS-2022...${RESET}"

    # 获取主服务端口，用于关闭防火墙
    local main_port=""
    if [ -f "/etc/ss-rust/config.json" ]; then
        main_port=$(grep -oE '"server_port"[[:space:]]*:[[:space:]]*[0-9]+' /etc/ss-rust/config.json | grep -oE '[0-9]+' | head -n 1)
    fi

    # 停止并禁用主服务
    systemctl stop ss-rust 2>/dev/null
    systemctl disable ss-rust 2>/dev/null
    rm -f "${SYSTEMD_DIR}/ss-rust.service"
    if [ -n "$main_port" ]; then
        close_port "$main_port"
    fi

    # 清理多端口节点服务
    local extra_service
    for extra_service in "${SYSTEMD_DIR}"/ss-rust-*.service; do
        [ -f "$extra_service" ] || continue
        local svc_name=$(basename "$extra_service" .service)
        local extra_port="${svc_name#ss-rust-}"
        echo -e "${YELLOW}正在停止多端口服务 (端口: ${extra_port})${RESET}"
        systemctl stop "$svc_name" 2>/dev/null
        systemctl disable "$svc_name" 2>/dev/null
        rm -f "$extra_service"
        case "$extra_port" in
            ''|*[!0-9]*) ;;
            *) close_port "$extra_port" ;;
        esac
    done

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
        [ -z "$service" ] && continue
        local service_file="${SYSTEMD_DIR}/${service}"
        local listen_port=""
        if [ -f "$service_file" ]; then
            listen_port=$(sed -n 's/.*--listen .*:\([0-9][0-9]*\).*/\1/p' "$service_file" | head -n 1)
        fi
        systemctl stop "$service" 2>/dev/null
        systemctl disable "$service" 2>/dev/null
        rm -f "$service_file"
        if [ -n "$listen_port" ]; then
            close_port "$listen_port"
        fi
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
    echo -e "${GREEN}3.${RESET} VLESS Reality 安装管理"
    echo -e "${GREEN}4.${RESET} ShadowTLS 安装管理"
    
    echo -e "\n${YELLOW}=== 卸载功能 ===${RESET}"
    echo -e "${GREEN}5.${RESET} 卸载 Snell"
    echo -e "${GREEN}6.${RESET} 卸载 SS-2022"
    echo -e "${GREEN}7.${RESET} 卸载 ShadowTLS"
    
    echo -e "\n${YELLOW}=== 系统功能 ===${RESET}"
    echo -e "${GREEN}8.${RESET} 更新脚本"
    echo -e "${GREEN}9.${RESET} 流量管理（推荐使用 PSM 管理）"
    echo -e "${GREEN}10.${RESET} 中国大陆屏蔽管理(ss-2022)"
    echo -e "${GREEN}0.${RESET} 退出"
    
    echo -e "${CYAN}============================================${RESET}"

    echo -e "${GREEN}退出脚本后，输入menu可进入脚本${RESET}"

    echo -e "${CYAN}============================================${RESET}"
    read -rp "请输入选项 [0-10]: " num
}

# 初始检查
check_root
check_dependencies
install_global_command

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
            manage_vless
            ;;
        4)
            manage_shadowtls
            ;;
        5)
            uninstall_snell
            ;;
        6)
            uninstall_ss_rust
            ;;
        7)
            uninstall_shadowtls
            ;;
        8)
            update_script
            ;;
        9)
            echo -e "\n${YELLOW}=== 流量管理 ===${RESET}"
            echo -e "本脚本内置的流量管理功能尚不完善，推荐使用 ${GREEN}PSM（Proxy Stack Manager）${RESET} 进行流量管理。"
            echo -e "\nPSM 支持 Snell / SS2022 / Xray 等协议的统一流量限额管理，功能包括："
            echo -e "  • 设置月度流量上限（GB）及自动重置日"
            echo -e "  • 超限自动暂停节点，恢复后自动解封"
            echo -e "  • iptables 精确计数，数据持久化保存"
            echo -e "\n安装 PSM："
            echo -e "  ${CYAN}bash <(curl -fsSL https://psm.jinqians.com)${RESET}"
            echo -e "\n进入 PSM 后选择：${GREEN}15. 流量管理${RESET} 即可添加 SS2022 节点并配置限额。"
            read -p "按任意键继续..."
            ;;
        10)
            if ! manage_mainland_block; then
                echo -e "${YELLOW}请检查仓库地址或网络连接后重试${RESET}"
                read -p "按任意键继续..."
            fi
            ;;
        0)
            echo -e "${GREEN}感谢使用，再见！${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}请输入正确的选项 [0-10]${RESET}"
            ;;
    esac
    echo -e "\n${CYAN}按任意键返回主菜单...${RESET}"
    read -n 1 -s -r
done 
