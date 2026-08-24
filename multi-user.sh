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
SNELL_SERVICE_USER="snell"
SNELL_SERVICE_GROUP="snell"

# Snell v6 加密模式：default / unshaped / unsafe-raw（客户端必须与服务端一致）
SNELL_MODE="default"

# 检测当前安装的 Snell 版本
detect_installed_snell_version() {
    if command -v snell-server &> /dev/null; then
        local version_output=$(snell-server --v 2>&1)
        if echo "$version_output" | grep -q "v6"; then
            echo "v6"
        elif echo "$version_output" | grep -q "v5"; then
            echo "v5"
        else
            echo "v4"
        fi
    else
        echo "unknown"
    fi
}

# 读取主配置中的 mode（v6），读不到时回落到默认值
get_snell_mode() {
    local mode=""
    if [ -f "$SNELL_CONF_FILE" ]; then
        mode=$(grep -E '^[[:space:]]*mode[[:space:]]*=' "$SNELL_CONF_FILE" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' ')
    fi
    if [ -z "$mode" ]; then
        mode="$SNELL_MODE"
    fi
    echo "$mode"
}

# 查询 IP 所属国家代码（多接口回退，避免单一接口限流返回错误信息）
get_ip_country() {
    local target="$1"
    local api=""
    local raw=""
    local result=""

    if [ -z "$target" ]; then
        echo "Unknown"
        return 1
    fi

    for api in "http://ipinfo.io/${target}/country" \
               "http://ip-api.com/line/${target}?fields=countryCode" \
               "https://ipwho.is/${target}?fields=country_code" \
               "https://ipapi.co/${target}/country/"; do
        raw=$(curl -s --connect-timeout 5 --max-time 10 "$api" 2>/dev/null)
        result=$(echo "$raw" | tr -d ' \t\r\n')
        case "$result" in
            [A-Za-z][A-Za-z]) ;;
            *) result=$(echo "$raw" | sed -n 's/.*"country_code"[[:space:]]*:[[:space:]]*"\([A-Za-z][A-Za-z]\)".*/\1/p' | head -n 1) ;;
        esac
        case "$result" in
            [A-Za-z][A-Za-z])
                echo "$result" | tr '[:lower:]' '[:upper:]'
                return 0
                ;;
        esac
    done

    echo "Unknown"
    return 1
}

# 输出单条 Surge 配置（v6 需要带 mode）
print_surge_line() {
    local country="$1"
    local ip_addr="$2"
    local port="$3"
    local psk="$4"
    local installed_version="$5"

    if [ "$installed_version" = "v6" ]; then
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 6, mode = $(get_snell_mode), reuse = true, tfo = true${RESET}"
    elif [ "$installed_version" = "v5" ]; then
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 4, reuse = true, tfo = true${RESET}"
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 5, reuse = true, tfo = true${RESET}"
    else
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 4, reuse = true, tfo = true${RESET}"
    fi
}

ensure_snell_service_user() {
    if ! getent group "${SNELL_SERVICE_GROUP}" >/dev/null 2>&1; then
        groupadd --system "${SNELL_SERVICE_GROUP}" 2>/dev/null || true
    fi

    if ! getent passwd "${SNELL_SERVICE_USER}" >/dev/null 2>&1; then
        useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin --gid "${SNELL_SERVICE_GROUP}" "${SNELL_SERVICE_USER}" 2>/dev/null || \
        useradd -r -M -s /usr/sbin/nologin -g "${SNELL_SERVICE_GROUP}" "${SNELL_SERVICE_USER}" 2>/dev/null || true
    fi
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

# 保存 nftables 规则
save_nftables_rules() {
    if ! command -v nft &> /dev/null; then
        return
    fi

    if [ -f "/etc/nftables.conf" ]; then
        nft list ruleset > /etc/nftables.conf 2>/dev/null || true
        systemctl enable nftables >/dev/null 2>&1 || true
        echo -e "${GREEN}nftables 规则已保存${RESET}"
    elif [ -f "/etc/sysconfig/nftables.conf" ]; then
        nft list ruleset > /etc/sysconfig/nftables.conf 2>/dev/null || true
        systemctl enable nftables >/dev/null 2>&1 || true
        echo -e "${GREEN}nftables 规则已保存${RESET}"
    else
        echo -e "${YELLOW}未找到 nftables 持久化配置文件，端口规则已在当前运行环境生效${RESET}"
    fi
}

# 在 nftables 中开放端口
open_nftables_port() {
    local PORT=$1
    local chains
    local chain_opened=false

    if ! command -v nft &> /dev/null; then
        return
    fi

    echo -e "${CYAN}在 nftables 中开放端口 $PORT${RESET}"

    chains=$(nft -a list ruleset 2>/dev/null | awk '
        $1 == "table" {
            family=$2
            table=$3
            gsub(/[{}]/, "", table)
        }
        $1 == "chain" {
            chain=$2
            gsub(/[{}]/, "", chain)
            in_chain=1
            next
        }
        in_chain && /type filter/ && /hook input/ {
            print family " " table " " chain
        }
        in_chain && /^[[:space:]]*}/ {
            in_chain=0
        }
    ')

    while read -r family table chain; do
        [ -z "$family" ] && continue

        if ! nft list chain "$family" "$table" "$chain" 2>/dev/null | grep -q "tcp dport $PORT .*accept"; then
            nft insert rule "$family" "$table" "$chain" tcp dport "$PORT" accept 2>/dev/null || true
        fi
        if ! nft list chain "$family" "$table" "$chain" 2>/dev/null | grep -q "udp dport $PORT .*accept"; then
            nft insert rule "$family" "$table" "$chain" udp dport "$PORT" accept 2>/dev/null || true
        fi
        chain_opened=true
    done << EOF
$chains
EOF

    if [ "$chain_opened" = false ]; then
        nft add table inet snell_filter 2>/dev/null || true
        nft list chain inet snell_filter input >/dev/null 2>&1 || nft add chain inet snell_filter input '{ type filter hook input priority -5; policy accept; }'
        if ! nft list chain inet snell_filter input 2>/dev/null | grep -q "tcp dport $PORT .*accept"; then
            nft add rule inet snell_filter input tcp dport "$PORT" accept 2>/dev/null || true
        fi
        if ! nft list chain inet snell_filter input 2>/dev/null | grep -q "udp dport $PORT .*accept"; then
            nft add rule inet snell_filter input udp dport "$PORT" accept 2>/dev/null || true
        fi
    fi

    save_nftables_rules
}

# 开放端口 (ufw、nftables 和 iptables)
open_port() {
    local PORT=$1
    local ufw_active=false

    # 检查 ufw 是否已安装
    if command -v ufw &> /dev/null; then
        echo -e "${CYAN}在 UFW 中开放端口 $PORT${RESET}"
        ufw allow "$PORT"/tcp
        ufw allow "$PORT"/udp
        if ufw status 2>/dev/null | grep -qw "active"; then
            ufw_active=true
        fi
    fi

    # 检查 iptables 是否已安装
    if command -v iptables &> /dev/null; then
        echo -e "${CYAN}在 iptables 中开放端口 $PORT${RESET}"
        iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
        iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT
        
        # 创建 iptables 规则保存目录（如果不存在）
        if [ ! -d "/etc/iptables" ]; then
            mkdir -p /etc/iptables
        fi
        
        # 尝试保存规则，如果失败则不中断脚本
        iptables-save > /etc/iptables/rules.v4 || true
    fi

    if [ "$ufw_active" = false ]; then
        open_nftables_port "$PORT"
    fi
}

# 获取主用户端口
get_main_port() {
    if [ -f "${SNELL_CONF_FILE}" ]; then
        local main_port=$(grep -E '^listen' "${SNELL_CONF_FILE}" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
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
            grep -E '^listen' "$conf_file" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p'
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
                local port=$(grep -E '^listen' "$user_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
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
                local used_port=$(grep -E '^listen' "$conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
                if [ "$used_port" == "$port" ]; then
                    return 1
                fi
            fi
        done
    fi
    # 检查主配置文件
    if [ -f "${SNELL_CONF_DIR}/snell-server.conf" ]; then
        local main_port=$(grep -E '^listen' "${SNELL_CONF_DIR}/snell-server.conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
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
    
    # 创建用户配置文件（IPv6 设置跟随主配置）
    ensure_snell_service_user
    local ipv6_enable="true"
    local listen_addr="::0"
    local main_conf="${SNELL_CONF_DIR}/users/snell-main.conf"
    if [ -f "$main_conf" ] && { grep -Eq '^[[:space:]]*ipv6[[:space:]]*=[[:space:]]*false' "$main_conf" \
        || grep -Eq '^[[:space:]]*dns-ip-preference[[:space:]]*=[[:space:]]*ipv4-only' "$main_conf"; }; then
        ipv6_enable="false"
        listen_addr="0.0.0.0"
    fi

    local installed_version
    installed_version=$(detect_installed_snell_version)

    local user_conf="${SNELL_CONF_DIR}/users/snell-${PORT}.conf"
    # v6 使用 mode / dns-ip-preference，ipv6 参数在 v6 已废弃
    {
        echo "[snell-server]"
        echo "listen = ${listen_addr}:${PORT}"
        echo "psk = ${PSK}"
        if [ "$installed_version" = "v6" ]; then
            echo "mode = $(get_snell_mode)"
            if [ "$ipv6_enable" = "false" ]; then
                echo "dns-ip-preference = ipv4-only"
            else
                echo "dns-ip-preference = default"
            fi
        else
            echo "ipv6 = ${ipv6_enable}"
        fi
        echo "dns = ${DNS}"
    } > "$user_conf"
    
    # 创建用户服务文件
    local service_name="snell-${PORT}"
    local service_file="${SYSTEMD_DIR}/${service_name}.service"
    cat > "$service_file" << EOF
[Unit]
Description=Snell Proxy Service (Port ${PORT})
After=network.target

[Service]
Type=simple
User=${SNELL_SERVICE_USER}
Group=${SNELL_SERVICE_GROUP}
LimitNOFILE=32768
ExecStart=${INSTALL_DIR}/snell-server -c ${user_conf}
AmbientCapabilities=CAP_NET_BIND_SERVICE
StandardOutput=journal
StandardError=journal
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
                sed -i "s/\(listen = .*:\)${mod_port}/\1${new_port}/" "$user_conf"
                
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
        local port=$(grep -E '^listen' "$user_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
        local psk=$(grep -E '^psk' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local dns=$(grep -E '^[[:space:]]*dns[[:space:]]*=' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local mode=$(grep -E '^[[:space:]]*mode[[:space:]]*=' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local dns_pref=$(grep -E '^[[:space:]]*dns-ip-preference[[:space:]]*=' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local installed_version=$(detect_installed_snell_version)

        echo -e "\n${GREEN}用户配置详情：${RESET}"
        echo -e "${CYAN}--------------------------------${RESET}"
        echo -e "${YELLOW}端口: ${port}${RESET}"
        echo -e "${YELLOW}PSK: ${psk}${RESET}"
        [ -n "$mode" ] && echo -e "${YELLOW}模式 (mode): ${mode}${RESET}"
        [ -n "$dns_pref" ] && echo -e "${YELLOW}DNS 解析偏好: ${dns_pref}${RESET}"
        echo -e "${YELLOW}DNS: ${dns}${RESET}"
        
        # 获取 IPv4 地址
        IPV4_ADDR=$(curl -s4 https://api.ipify.org)
        if [ $? -eq 0 ] && [ ! -z "$IPV4_ADDR" ]; then
            IP_COUNTRY_IPV4=$(get_ip_country "${IPV4_ADDR}")
            echo -e "\n${GREEN}IPv4 配置：${RESET}"
            print_surge_line "$IP_COUNTRY_IPV4" "$IPV4_ADDR" "$port" "$psk" "$installed_version"
        fi
        
        # 获取 IPv6 地址
        IPV6_ADDR=$(curl -s6 https://api64.ipify.org)
        if [ $? -eq 0 ] && [ ! -z "$IPV6_ADDR" ]; then
            IP_COUNTRY_IPV6=$(get_ip_country "${IPV6_ADDR}")
            echo -e "\n${GREEN}IPv6 配置：${RESET}"
            print_surge_line "$IP_COUNTRY_IPV6" "$IPV6_ADDR" "$port" "$psk" "$installed_version"
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
    if ! read -rp "请输入选项 [0-5]: " choice; then
        echo
        echo -e "${YELLOW}未读取到输入，已退出多用户菜单。${RESET}"
        exit 0
    fi
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
    read -n 1 -s -r || exit 0
done 
