#!/bin/bash
# =========================================
# 作者: jinqians
# 日期: 2025年2月
# 网站：jinqians.com
# 描述: 这个脚本用于管理 Snell 代理的多用户配置
# =========================================

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 定义配置目录
SNELL_CONF_DIR="/etc/snell"
SNELL_CONF_FILE="${SNELL_CONF_DIR}/users/snell-main.conf"

# 定义目录和文件路径
INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"

# 检查是否以 root 权限运行
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请以 root 权限运行此脚本.${RESET}"
        exit 1
    fi
}

# 检查 Snell 是否已安装
check_snell_installed() {
    if ! command -v snell-server &> /dev/null; then
        echo -e "${RED}未检测到 Snell 安装，请先安装 Snell。${RESET}"
        exit 1
    fi
}

# 获取系统DNS
get_system_dns() {
    # 尝试从resolv.conf获取系统DNS
    if [ -f "/etc/resolv.conf" ]; then
        system_dns=$(grep -E '^nameserver' /etc/resolv.conf | awk '{print $2}' | tr '\n' ',' | sed 's/,$//')
        if [ ! -z "$system_dns" ]; then
            echo "$system_dns"
            return 0
        fi
    fi
    
    # 如果无法从resolv.conf获取，尝试使用公共DNS
    echo "1.1.1.1,8.8.8.8"
}

# 获取用户输入的 DNS 服务器
get_dns() {
    read -rp "请输入 DNS 服务器地址 (直接回车使用系统DNS): " custom_dns
    if [ -z "$custom_dns" ]; then
        DNS=$(get_system_dns)
        echo -e "${GREEN}使用系统 DNS 服务器: $DNS${RESET}"
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
        
        # 创建 iptables 规则保存目录（如果不存在）
        if [ ! -d "/etc/iptables" ]; then
            mkdir -p /etc/iptables
        fi
        
        # 尝试保存规则，如果失败则不中断脚本
        iptables-save > /etc/iptables/rules.v4 || true
    fi
}

# 获取主用户端口
get_main_port() {
    if [ -f "${SNELL_CONF_FILE}" ]; then
        local main_port=$(grep -E '^listen' "${SNELL_CONF_FILE}" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
        echo "$main_port"
    fi
}

# 获取所有用户端口
get_all_ports() {
    # 检查用户配置目录是否存在
    if [ ! -d "${SNELL_CONF_DIR}/users" ]; then
        return 1
    fi
    
    # 获取所有配置文件中的端口
    for conf_file in "${SNELL_CONF_DIR}/users"/snell-*.conf; do
        if [ -f "$conf_file" ]; then
            grep -E '^listen' "$conf_file" | sed -n 's/.*::0:\([0-9]*\)/\1/p'
        fi
    done | sort -n | uniq
}

# 列出所有用户
list_users() {
    echo -e "\n${YELLOW}=== 当前用户列表 ===${RESET}"
    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        local count=0
        for user_conf in "${SNELL_CONF_DIR}/users"/*; do
            if [ -f "$user_conf" ]; then
                count=$((count + 1))
                local port=$(grep -E '^listen' "$user_conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
                local psk=$(grep -E '^psk' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
                echo -e "${GREEN}用户 $count:${RESET}"
                echo -e "端口: ${port}"
                echo -e "PSK: ${psk}"
                echo -e "配置文件: ${user_conf}\n"
            fi
        done
        if [ $count -eq 0 ]; then
            echo -e "${YELLOW}当前没有配置的用户${RESET}"
        fi
    else
        echo -e "${YELLOW}当前没有配置的用户${RESET}"
    fi
}

# 检查端口是否已被使用
check_port_usage() {
    local port=$1
    # 检查是否被其他 snell 实例使用
    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for conf in "${SNELL_CONF_DIR}/users"/*; do
            if [ -f "$conf" ]; then
                local used_port=$(grep -E '^listen' "$conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
                if [ "$used_port" == "$port" ]; then
                    return 1
                fi
            fi
        done
    fi
    # 检查主配置文件
    if [ -f "${SNELL_CONF_DIR}/snell-server.conf" ]; then
        local main_port=$(grep -E '^listen' "${SNELL_CONF_DIR}/snell-server.conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
        if [ "$main_port" == "$port" ]; then
            return 1
        fi
    fi
    return 0
}

# 添加新用户
add_user() {
    echo -e "\n${YELLOW}=== 添加新用户 ===${RESET}"
    
    # 创建用户配置目录
    mkdir -p "${SNELL_CONF_DIR}/users"
    
    # 获取端口号
    while true; do
        read -rp "请输入新用户端口号 (1-65535): " PORT
        if [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
            # 检查端口是否已被使用
            if ! check_port_usage "$PORT"; then
                echo -e "${RED}端口 $PORT 已被使用，请选择其他端口${RESET}"
                continue
            fi
            break
        else
            echo -e "${RED}无效端口号，请输入 1 到 65535 之间的数字${RESET}"
        fi
    done
    
    # 生成随机 PSK
    PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
    
    # 获取 DNS 设置
    get_dns
    
    # 创建用户配置文件
    local user_conf="${SNELL_CONF_DIR}/users/snell-${PORT}.conf"
    cat > "$user_conf" << EOF
[snell-server]
listen = ::0:${PORT}
psk = ${PSK}
ipv6 = true
dns = ${DNS}
EOF
    
    # 创建用户服务文件
    local service_name="snell-${PORT}"
    local service_file="${SYSTEMD_DIR}/${service_name}.service"
    cat > "$service_file" << EOF
[Unit]
Description=Snell Proxy Service (Port ${PORT})
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
LimitNOFILE=32768
ExecStart=${INSTALL_DIR}/snell-server -c ${user_conf}
AmbientCapabilities=CAP_NET_BIND_SERVICE
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=snell-server-${PORT}

[Install]
WantedBy=multi-user.target
EOF

    # 重载 systemd 配置
    systemctl daemon-reload
    
    # 启用并启动服务
    systemctl enable "$service_name"
    systemctl start "$service_name"
    
    # 开放端口
    open_port "$PORT"
    
    echo -e "\n${GREEN}用户添加成功！配置信息：${RESET}"
    echo -e "${CYAN}--------------------------------${RESET}"
    echo -e "${YELLOW}端口: ${PORT}${RESET}"
    echo -e "${YELLOW}PSK: ${PSK}${RESET}"
    echo -e "${YELLOW}配置文件: ${user_conf}${RESET}"
    echo -e "${CYAN}--------------------------------${RESET}"
}

# 删除用户
delete_user() {
    echo -e "\n${YELLOW}=== 删除用户 ===${RESET}"
    
    # 显示用户列表
    list_users
    
    # 获取要删除的用户端口
    read -rp "请输入要删除的用户端口号: " del_port
    
    local user_conf="${SNELL_CONF_DIR}/users/snell-${del_port}.conf"
    local service_name="snell-${del_port}"
    
    if [ -f "$user_conf" ]; then
        # 停止并禁用服务
        systemctl stop "$service_name"
        systemctl disable "$service_name"
        
        # 删除服务文件
        rm -f "${SYSTEMD_DIR}/${service_name}.service"
        rm -f "/lib/systemd/system/${service_name}.service"
        # 删除配置文件
        rm -f "$user_conf"
        
        # 重载 systemd 配置
        systemctl daemon-reload
        
        echo -e "${GREEN}用户已成功删除${RESET}"
    else
        echo -e "${RED}未找到端口为 ${del_port} 的用户${RESET}"
    fi
}

# 修改用户配置
modify_user() {
    echo -e "\n${YELLOW}=== 修改用户配置 ===${RESET}"
    
    # 显示用户列表
    list_users
    
    # 获取要修改的用户端口
    read -rp "请输入要修改的用户端口号: " mod_port
    
    local user_conf="${SNELL_CONF_DIR}/users/snell-${mod_port}.conf"
    local service_name="snell-${mod_port}"
    
    if [ -f "$user_conf" ]; then
        echo -e "\n${YELLOW}请选择要修改的项目：${RESET}"
        echo -e "${GREEN}1.${RESET} 修改端口"
        echo -e "${GREEN}2.${RESET} 重置 PSK"
        echo -e "${GREEN}3.${RESET} 修改 DNS"
        echo -e "${GREEN}0.${RESET} 返回"
        
        read -rp "请输入选项 [0-3]: " mod_choice
        case "$mod_choice" in
            1)
                # 修改端口
                while true; do
                    read -rp "请输入新端口号 (1-65535): " new_port
                    if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
                        if ! check_port_usage "$new_port"; then
                            echo -e "${RED}端口 $new_port 已被使用，请选择其他端口${RESET}"
                            continue
                        fi
                        break
                    else
                        echo -e "${RED}无效端口号，请输入 1 到 65535 之间的数字${RESET}"
                    fi
                done
                
                # 停止服务
                systemctl stop "$service_name"
                
                # 修改配置文件中的端口
                sed -i "s/listen = ::0:${mod_port}/listen = ::0:${new_port}/" "$user_conf"
                
                # 重命名配置文件和服务
                mv "$user_conf" "${SNELL_CONF_DIR}/users/snell-${new_port}.conf"
                mv "${SYSTEMD_DIR}/${service_name}.service" "${SYSTEMD_DIR}/snell-${new_port}.service"
                
                # 移动和更新服务文件
                sed -i "s/Description=Snell Proxy Service (Port ${mod_port})/Description=Snell Proxy Service (Port ${new_port})/" "${SYSTEMD_DIR}/snell-${new_port}.service"
                sed -i "s/SyslogIdentifier=snell-server-${mod_port}/SyslogIdentifier=snell-server-${new_port}/" "${SYSTEMD_DIR}/snell-${new_port}.service"
                sed -i "s/${user_conf}/${SNELL_CONF_DIR}\/users\/snell-${new_port}.conf/" "${SYSTEMD_DIR}/snell-${new_port}.service"
                
                # 重载配置并启动服务
                systemctl daemon-reload
                systemctl enable "snell-${new_port}"
                systemctl start "snell-${new_port}"
                
                # 开放新端口
                open_port "$new_port"
                
                echo -e "${GREEN}端口修改成功${RESET}"
                ;;
            2)
                # 重置 PSK
                local new_psk=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
                sed -i "s/psk = .*/psk = ${new_psk}/" "$user_conf"
                systemctl restart "$service_name"
                echo -e "${GREEN}PSK 已重置为: ${new_psk}${RESET}"
                ;;
            3)
                # 修改 DNS
                get_dns
                sed -i "s/dns = .*/dns = ${DNS}/" "$user_conf"
                systemctl restart "$service_name"
                echo -e "${GREEN}DNS 修改成功${RESET}"
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}无效选项${RESET}"
                ;;
        esac
    else
        echo -e "${RED}未找到端口为 ${mod_port} 的用户${RESET}"
    fi
}

# 显示用户配置信息
show_user_config() {
    echo -e "\n${YELLOW}=== 用户配置信息 ===${RESET}"
    
    # 显示用户列表
    list_users
    
    # 获取要查看的用户端口
    read -rp "请输入要查看的用户端口号: " view_port
    
    local user_conf="${SNELL_CONF_DIR}/users/snell-${view_port}.conf"
    
    if [ -f "$user_conf" ]; then
        local port=$(grep -E '^listen' "$user_conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
        local psk=$(grep -E '^psk' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local dns=$(grep -E '^dns' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        
        echo -e "\n${GREEN}用户配置详情：${RESET}"
        echo -e "${CYAN}--------------------------------${RESET}"
        echo -e "${YELLOW}端口: ${port}${RESET}"
        echo -e "${YELLOW}PSK: ${psk}${RESET}"
        echo -e "${YELLOW}DNS: ${dns}${RESET}"
        
        # 获取 IPv4 地址
        IPV4_ADDR=$(curl -s4 https://api.ipify.org)
        if [ $? -eq 0 ] && [ ! -z "$IPV4_ADDR" ]; then
            IP_COUNTRY_IPV4=$(curl -s http://ipinfo.io/${IPV4_ADDR}/country)
            echo -e "\n${GREEN}IPv4 配置：${RESET}"
            echo -e "${GREEN}${IP_COUNTRY_IPV4} = snell, ${IPV4_ADDR}, ${port}, psk = ${psk}, version = 4, reuse = true, tfo = true${RESET}"
        fi
        
        # 获取 IPv6 地址
        IPV6_ADDR=$(curl -s6 https://api64.ipify.org)
        if [ $? -eq 0 ] && [ ! -z "$IPV6_ADDR" ]; then
            IP_COUNTRY_IPV6=$(curl -s https://ipapi.co/${IPV6_ADDR}/country/)
            echo -e "\n${GREEN}IPv6 配置：${RESET}"
            echo -e "${GREEN}${IP_COUNTRY_IPV6} = snell, ${IPV6_ADDR}, ${port}, psk = ${psk}, version = 4, reuse = true, tfo = true${RESET}"
        fi
        
        echo -e "${CYAN}--------------------------------${RESET}"
    else
        echo -e "${RED}未找到端口为 ${view_port} 的用户${RESET}"
    fi
}

# 主菜单
show_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}          Snell 多用户管理${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}作者: jinqian${RESET}"
    echo -e "${GREEN}网站：https://jinqians.com${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    
    echo -e "${YELLOW}=== 用户管理 ===${RESET}"
    echo -e "${GREEN}1.${RESET} 查看所有用户"
    echo -e "${GREEN}2.${RESET} 添加新用户"
    echo -e "${GREEN}3.${RESET} 删除用户"
    echo -e "${GREEN}4.${RESET} 修改用户配置"
    echo -e "${GREEN}5.${RESET} 查看用户详细配置"
    echo -e "${GREEN}0.${RESET} 退出脚本"
    
    echo -e "${CYAN}============================================${RESET}"
    read -rp "请输入选项 [0-5]: " choice
}

# 初始检查
check_root
check_snell_installed

# 主循环
while true; do
    show_menu
    case "$choice" in
        1)
            list_users
            ;;
        2)
            add_user
            ;;
        3)
            delete_user
            ;;
        4)
            modify_user
            ;;
        5)
            show_user_config
            ;;
        0)
            echo -e "${GREEN}感谢使用，再见！${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}请输入正确的选项 [0-5]${RESET}"
            ;;
    esac
    echo -e "\n${CYAN}按任意键返回主菜单...${RESET}"
    read -n 1 -s -r
done 
