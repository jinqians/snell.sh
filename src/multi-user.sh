#!/bin/bash
# =========================================
# 作者: jinqians
# 日期: 2025年2月
# 网站：jinqians.com
# 描述: 这个脚本用于管理 Snell 代理的多用户配置
# =========================================

# 共用部分（src/lib，发布时由 tools/build.sh 合进来）
SNELL_LIB="${SNELL_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib}"  # @dev
. "$SNELL_LIB/common.sh"    # @bundle
. "$SNELL_LIB/release.sh"   # @bundle
. "$SNELL_LIB/netinfo.sh"   # @bundle
. "$SNELL_LIB/firewall.sh"  # @bundle
. "$SNELL_LIB/channels.sh"  # @bundle
. "$SNELL_LIB/conf.sh"      # @bundle


# 读取主配置中的 dns-ip-preference（v6），读不到时按 ipv6 开关推导
get_snell_dns_preference() {
    local ipv6_enable="$1"
    local conf_file="${2:-$SNELL_CONF_FILE}"
    local pref=""
    if [ -f "$conf_file" ]; then
        pref=$(grep -E '^[[:space:]]*dns-ip-preference[[:space:]]*=' "$conf_file" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' ')
    fi
    if [ -z "$pref" ]; then
        if [ "$ipv6_enable" = "false" ]; then
            pref="ipv4-only"
        else
            pref="default"
        fi
    fi
    echo "$pref"
}

# 输出单条 Surge 配置（v6 需要带 mode）
print_surge_line() {
    local country="$1"
    local ip_addr="$2"
    local port="$3"
    local psk="$4"
    local installed_version="$5"

    if [ "$installed_version" = "v6" ]; then
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 6, mode = $(get_snell_mode "$(snell_conf_for_port "$port")"), reuse = true, tfo = true${RESET}"
    elif [ "$installed_version" = "v5" ]; then
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 4, reuse = true, tfo = true${RESET}"
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 5, reuse = true, tfo = true${RESET}"
    else
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 4, reuse = true, tfo = true${RESET}"
    fi
}

# 检查 Snell 是否已安装
check_snell_installed() {
    if ! command -v snell-server &> /dev/null && [ -z "$(list_installed_snell_versions)" ]; then
        echo -e "${RED}未检测到 Snell 安装，请先安装 Snell。${RESET}"
        exit 1
    fi

    # 旧的单版本布局先迁成按通道分开存，之后新增用户才能各自选版本
    if [ -e "${INSTALL_DIR}/snell-server" ]; then
        migrate_snell_binary_layout
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
                local version=$(get_conf_snell_version "$user_conf")
                echo -e "${GREEN}用户 $count:${RESET}"
                echo -e "端口: ${port}"
                echo -e "版本: Snell ${version}"
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
    # 检查主配置文件（遗留路径）
    if [ -f "${SNELL_CONF_DIR}/snell-server.conf" ]; then
        local main_port=$(grep -E '^listen' "${SNELL_CONF_DIR}/snell-server.conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
        if [ "$main_port" == "$port" ]; then
            return 1
        fi
    fi
    # 检查系统实际监听端口（ss 不存在时跳过）
    if command -v ss &> /dev/null; then
        if ss -tulnH 2>/dev/null | grep -q ":${port} "; then
            return 1
        fi
    fi
    return 0
}

# 校验用户输入的端口：纯数字 + 范围 1-65535；显式拒绝 main（主配置）
validate_user_port() {
    local port="$1"
    if [ "$port" = "main" ]; then
        echo -e "${RED}不能直接操作主用户配置（snell-main.conf），请用主脚本管理主用户${RESET}"
        return 1
    fi
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${RED}无效端口号，请输入 1 到 65535 之间的数字${RESET}"
        return 1
    fi
    return 0
}

# 多用户数据并发锁：add/delete/modify 是典型的 check-then-act，
# 加锁防止两个管理会话同时操作同一端口导致配置互相覆盖
multi_user_lock() {
    if ! command -v flock &> /dev/null; then
        echo -e "${YELLOW}未找到 flock，跳过并发锁${RESET}"
        return 0
    fi
    if ! exec 200>"${SNELL_CONF_DIR}/.multi-user.lock" 2>/dev/null; then
        echo -e "${RED}无法创建锁文件，已取消操作${RESET}"
        return 1
    fi
    if ! flock -n 200 2>/dev/null; then
        echo -e "${RED}另有用户管理操作正在进行，请稍后再试${RESET}"
        exec 200>&- 2>/dev/null || true
        return 1
    fi
    return 0
}

multi_user_unlock() {
    flock -u 200 2>/dev/null || true
    exec 200>&- 2>/dev/null || true
}


# 通道在本机的安装状态，用于菜单提示
snell_channel_label() {
    if [ -x "$(snell_binary_for_version "$1")" ]; then
        echo "已安装"
    else
        echo "未安装，选中后自动下载"
    fi
}

# 为用户选择 Snell 通道，结果写入全局 SNELL_VERSION_CHOICE
select_user_snell_version() {
    local prompt_title="${1:-选择该用户使用的 Snell 版本}"
    local installed default_version arch
    installed=$(list_installed_snell_versions)
    default_version=$(get_conf_snell_version "$SNELL_CONF_FILE")
    arch=$(uname -m)

    # 主配置缺失或软链断了时 default_version 可能是 unknown，退到第一个已装通道
    case "$default_version" in
        v4|v5|v6) ;;
        *) default_version="${installed%% *}" ;;
    esac
    [ -n "$default_version" ] || default_version="v5"

    echo -e "\n${CYAN}=== ${prompt_title} ===${RESET}"
    echo -e "${YELLOW}已安装通道: ${installed:-无}${RESET}"
    echo -e "${YELLOW}不同端口可以跑不同版本，彼此独立互不影响${RESET}\n"
    echo -e "${GREEN}1.${RESET} Snell v4        （$(snell_channel_label v4)）"
    echo -e "${GREEN}2.${RESET} Snell v5        （$(snell_channel_label v5)）"
    echo -e "${GREEN}3.${RESET} Snell v6 (RC)   （$(snell_channel_label v6)）"
    echo -e "${GREEN}0.${RESET} 跟随主用户（${default_version}）"

    while true; do
        read -rp "请选择 [0-3]: " version_pick
        case "$version_pick" in
            1) SNELL_VERSION_CHOICE="v4"; break ;;
            2) SNELL_VERSION_CHOICE="v5"; break ;;
            3)
                if [ "$arch" = "armv7l" ] || [ "$arch" = "armv7" ]; then
                    echo -e "${RED}Snell v6 暂不提供 armv7l 构建，请选择其他版本${RESET}"
                    continue
                fi
                SNELL_VERSION_CHOICE="v6"
                echo -e "${YELLOW}注意：v6 仍为预发布版本，已移除 QUIC 代理模式与 obfs${RESET}"
                break
                ;;
            0|"") SNELL_VERSION_CHOICE="$default_version"; break ;;
            *) echo -e "${RED}请输入正确的选项 [0-3]${RESET}" ;;
        esac
    done

    echo -e "${GREEN}已选择 Snell ${SNELL_VERSION_CHOICE}${RESET}"
}

# 把某个用户的配置切换到目标通道：备好二进制 -> 迁移配置参数 -> 改 unit -> 重启，失败自动回滚
switch_user_conf_version() {
    local conf_file="$1"
    local target_version="$2"
    local port service unit current_version

    if [ ! -f "$conf_file" ]; then
        echo -e "${RED}配置不存在: ${conf_file}${RESET}"
        return 1
    fi

    current_version=$(get_conf_snell_version "$conf_file")
    if [ "$current_version" = "$target_version" ]; then
        echo -e "${YELLOW}该用户已经在 ${target_version} 通道，无需切换${RESET}"
        return 0
    fi

    port=$(grep -E '^listen' "$conf_file" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
    if [ -z "$port" ]; then
        echo -e "${RED}无法从 ${conf_file} 解析监听端口${RESET}"
        return 1
    fi

    service=$(snell_service_for_port "$port")
    if [ "$service" = "snell" ]; then
        unit="$SYSTEMD_SERVICE_FILE"
    else
        unit="${SYSTEMD_DIR}/snell-${port}.service"
    fi
    if [ ! -f "$unit" ]; then
        echo -e "${RED}未找到服务文件: ${unit}${RESET}"
        return 1
    fi

    if ! ensure_snell_binary "$target_version"; then
        return 1
    fi

    # v6 的 mode / dns-ip-preference 按这个用户单独选；
    # 先按本配置文件重置 IPV6_ENABLE，避免沿用之前 add_user 的残留值
    if [ "$target_version" = "v6" ]; then
        IPV6_ENABLE="true"
        if grep -Eq '^[[:space:]]*ipv6[[:space:]]*=[[:space:]]*false' "$conf_file" \
            || grep -Eq '^[[:space:]]*dns-ip-preference[[:space:]]*=[[:space:]]*ipv4-only' "$conf_file"; then
            IPV6_ENABLE="false"
        fi
        configure_snell_v6_options "$conf_file"
    fi

    local stamp backup_conf backup_unit
    stamp=$(date +%Y%m%d_%H%M%S)
    backup_conf=$(snell_backup_path "$conf_file" "$stamp")
    if [ -z "$backup_conf" ] || ! cp -a "$conf_file" "$backup_conf"; then
        echo -e "${RED}备份配置失败，已中止切换${RESET}"
        SNELL_V6_OPTIONS_SET="false"
        return 1
    fi
    backup_unit=$(snell_backup_path "$unit" "$stamp")
    cp -a "$unit" "$backup_unit" 2>/dev/null || backup_unit=""

    echo -e "${CYAN}正在把端口 ${port} 从 ${current_version} 切换到 ${target_version}...${RESET}"

    migrate_snell_conf_for_version "$conf_file" "$target_version"
    if [ "$service" = "snell" ]; then
        point_service_unit_to_version "$unit" "$target_version"
        update_snell_symlink "$target_version"
    else
        write_user_service_unit "$port" "$conf_file" "$target_version"
    fi
    systemctl daemon-reload 2>/dev/null || true

    if restart_and_verify_service "$service"; then
        echo -e "${GREEN}✓ 端口 ${port} 已切换到 Snell ${target_version}${RESET}"
        echo -e "${YELLOW}客户端请把该节点的 version 改为 ${target_version#v}${RESET}"
        if [ "$target_version" = "v6" ]; then
            echo -e "${YELLOW}并补上 mode = $(get_snell_mode "$conf_file")${RESET}"
        fi
        echo -e "${YELLOW}回滚备份: ${backup_conf}${RESET}"
        SNELL_V6_OPTIONS_SET="false"
        return 0
    fi

    echo -e "${RED}切换后服务未能启动，正在回滚到 ${current_version}...${RESET}"
    cat "$backup_conf" > "$conf_file"
    [ -n "$backup_unit" ] && cat "$backup_unit" > "$unit"
    systemctl daemon-reload 2>/dev/null || true
    if [ "$service" = "snell" ]; then
        update_snell_symlink "$current_version"
    fi
    if restart_and_verify_service "$service"; then
        echo -e "${YELLOW}已回滚到 ${current_version}，服务恢复正常${RESET}"
    else
        echo -e "${RED}回滚后服务仍未启动，请手动检查: systemctl status ${service}${RESET}"
    fi
    SNELL_V6_OPTIONS_SET="false"
    return 1
}

# 添加新用户
add_user() {
    # 并发锁（函数返回时自动释放）；重置 IPV6_ENABLE，避免沿用上次调用的残留值
    multi_user_lock || return 1
    trap 'multi_user_unlock' RETURN
    IPV6_ENABLE="true"

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
    
    # 选择该用户使用的通道
    select_user_snell_version
    local installed_version="$SNELL_VERSION_CHOICE"

    # 通道缺失时先下载，失败就不要留下半成品用户
    if ! ensure_snell_binary "$installed_version"; then
        echo -e "${RED}Snell ${installed_version} 未能就位，已取消添加用户${RESET}"
        return 1
    fi

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

    # v6 的 mode / dns-ip-preference 由本用户单独决定；默认沿用主配置里的取值
    if [ "$installed_version" = "v6" ]; then
        IPV6_ENABLE="$ipv6_enable"
        SNELL_MODE=$(get_snell_mode "$main_conf")
        SNELL_DNS_IP_PREFERENCE=$(get_snell_dns_preference "$ipv6_enable" "$main_conf")
        configure_snell_v6_options "$main_conf"
    fi

    local user_conf="${SNELL_CONF_DIR}/users/snell-${PORT}.conf"
    # v6 使用 mode / dns-ip-preference，ipv6 参数在 v6 已废弃
    {
        echo "#${SNELL_VERSION_MARKER_KEY} = ${installed_version}"
        echo "[snell-server]"
        echo "listen = ${listen_addr}:${PORT}"
        echo "psk = ${PSK}"
        if [ "$installed_version" = "v6" ]; then
            echo "mode = ${SNELL_MODE}"
            echo "dns-ip-preference = ${SNELL_DNS_IP_PREFERENCE}"
        else
            echo "ipv6 = ${ipv6_enable}"
        fi
        echo "dns = ${DNS}"
    } > "$user_conf"
    SNELL_V6_OPTIONS_SET="false"
    
    # 创建用户服务文件，ExecStart 指向该用户所选通道
    local service_name="snell-${PORT}"
    write_user_service_unit "$PORT" "$user_conf" "$installed_version"

    # 重载 systemd 配置
    systemctl daemon-reload
    systemctl enable "$service_name" 2>/dev/null

    # 启动并确认服务真的起来了，起不来就回收半成品，不留下坏用户
    if ! restart_and_verify_service "$service_name"; then
        echo -e "${RED}用户服务启动失败，正在回收本次创建的配置...${RESET}"
        systemctl disable "$service_name" 2>/dev/null
        rm -f "${SYSTEMD_DIR}/${service_name}.service"
        rm -f "$user_conf"
        systemctl daemon-reload
        echo -e "${YELLOW}已回收。端口 ${PORT} 未被占用，可换个版本或端口重试。${RESET}"
        return 1
    fi

    # 开放端口
    open_port "$PORT"
    
    echo -e "\n${GREEN}用户添加成功！配置信息：${RESET}"
    echo -e "${CYAN}--------------------------------${RESET}"
    echo -e "${YELLOW}端口: ${PORT}${RESET}"
    echo -e "${YELLOW}版本: Snell ${installed_version}${RESET}"
    echo -e "${YELLOW}PSK: ${PSK}${RESET}"
    [ "$installed_version" = "v6" ] && echo -e "${YELLOW}mode: ${SNELL_MODE}（客户端需一致）${RESET}"
    echo -e "${YELLOW}配置文件: ${user_conf}${RESET}"
    echo -e "${CYAN}--------------------------------${RESET}"
}

# 删除用户
delete_user() {
    # 并发锁（函数返回时自动释放）
    multi_user_lock || return 1
    trap 'multi_user_unlock' RETURN

    echo -e "\n${YELLOW}=== 删除用户 ===${RESET}"

    # 显示用户列表
    list_users

    # 获取要删除的用户端口（纯数字校验，拒绝 main 主配置）
    read -rp "请输入要删除的用户端口号: " del_port
    if ! validate_user_port "$del_port"; then
        return 1
    fi

    local user_conf="${SNELL_CONF_DIR}/users/snell-${del_port}.conf"
    local service_name="snell-${del_port}"

    if [ -f "$user_conf" ]; then
        # 停止并禁用服务
        systemctl stop "$service_name" 2>/dev/null || true
        systemctl disable "$service_name" 2>/dev/null || true

        # 删除服务文件
        rm -f "${SYSTEMD_DIR}/${service_name}.service"
        rm -f "/lib/systemd/system/${service_name}.service"
        # 删除配置文件
        rm -f "$user_conf"

        # 防火墙里为它开的端口一起关掉
        close_port "$del_port"

        # 清理该端口在 backup/ 下的旧备份（含明文 PSK）
        rm -f "${SNELL_CONF_DIR}/backup/snell-${del_port}.conf".* 2>/dev/null
        rm -f "${SNELL_CONF_DIR}/backup/snell-${del_port}.service".* 2>/dev/null

        # 重载 systemd 配置
        systemctl daemon-reload

        echo -e "${GREEN}用户已成功删除${RESET}"
    else
        echo -e "${RED}未找到端口为 ${del_port} 的用户${RESET}"
    fi
}

# 修改用户配置
modify_user() {
    # 并发锁（函数返回时自动释放）
    multi_user_lock || return 1
    trap 'multi_user_unlock' RETURN

    echo -e "\n${YELLOW}=== 修改用户配置 ===${RESET}"

    # 显示用户列表
    list_users

    # 获取要修改的用户端口（纯数字校验，拒绝 main 主配置）
    read -rp "请输入要修改的用户端口号: " mod_port
    if ! validate_user_port "$mod_port"; then
        return 1
    fi

    local user_conf="${SNELL_CONF_DIR}/users/snell-${mod_port}.conf"
    local service_name="snell-${mod_port}"
    
    if [ -f "$user_conf" ]; then
        echo -e "\n${YELLOW}当前版本: Snell $(get_conf_snell_version "$user_conf")${RESET}"
        echo -e "${YELLOW}请选择要修改的项目：${RESET}"
        echo -e "${GREEN}1.${RESET} 修改端口"
        echo -e "${GREEN}2.${RESET} 重置 PSK"
        echo -e "${GREEN}3.${RESET} 修改 DNS"
        echo -e "${GREEN}4.${RESET} 修改 Snell 版本（切换通道）"
        echo -e "${GREEN}0.${RESET} 返回"
        
        read -rp "请输入选项 [0-4]: " mod_choice
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
                
                local mod_version
                mod_version=$(get_conf_snell_version "$user_conf")

                # 备份旧配置与旧服务文件，新端口启动失败时回滚
                local stamp backup_old_conf backup_old_unit new_conf
                stamp=$(date +%Y%m%d_%H%M%S)
                backup_old_conf=$(snell_backup_path "$user_conf" "$stamp")
                backup_old_unit=""
                if [ -n "$backup_old_conf" ] && cp -a "$user_conf" "$backup_old_conf" 2>/dev/null; then
                    if [ -f "${SYSTEMD_DIR}/${service_name}.service" ]; then
                        backup_old_unit=$(snell_backup_path "${SYSTEMD_DIR}/${service_name}.service" "$stamp")
                        cp -a "${SYSTEMD_DIR}/${service_name}.service" "$backup_old_unit" 2>/dev/null || backup_old_unit=""
                    fi
                else
                    echo -e "${RED}备份旧配置失败，已中止改端口${RESET}"
                    return 1
                fi

                # 停止并注销旧服务
                systemctl stop "$service_name" 2>/dev/null || true
                systemctl disable "$service_name" 2>/dev/null || true

                # 修改配置文件中的端口（尾部锚定：mod_port=5 不会误改 :12345）
                sed -i "s/\(listen = .*:\)${mod_port}$/\1${new_port}/" "$user_conf"
                if ! grep -Eq "^listen = .*:${new_port}$" "$user_conf"; then
                    echo -e "${RED}配置文件端口替换失败，已中止${RESET}"
                    systemctl enable "$service_name" 2>/dev/null || true
                    restart_and_verify_service "$service_name" || true
                    return 1
                fi

                # 重命名配置文件，服务文件整份重写（Description 带版本号，逐行 sed 已不适用）
                new_conf="${SNELL_CONF_DIR}/users/snell-${new_port}.conf"
                mv "$user_conf" "$new_conf"
                rm -f "${SYSTEMD_DIR}/${service_name}.service"
                write_user_service_unit "$new_port" "$new_conf" "$mod_version"

                # 重载配置并启动服务
                systemctl daemon-reload
                systemctl enable "snell-${new_port}" 2>/dev/null || true
                if restart_and_verify_service "snell-${new_port}"; then
                    # 成功：关闭旧端口防火墙规则，开放新端口
                    close_port "$mod_port"
                    open_port "$new_port"
                    echo -e "${GREEN}端口修改成功: ${mod_port} -> ${new_port}${RESET}"
                else
                    echo -e "${RED}新端口服务启动失败，正在回滚...${RESET}"
                    systemctl disable "snell-${new_port}" 2>/dev/null || true
                    rm -f "${SYSTEMD_DIR}/snell-${new_port}.service" "$new_conf"
                    cat "$backup_old_conf" > "$user_conf"
                    [ -n "$backup_old_unit" ] && cat "$backup_old_unit" > "${SYSTEMD_DIR}/${service_name}.service"
                    systemctl daemon-reload 2>/dev/null || true
                    systemctl enable "$service_name" 2>/dev/null || true
                    if restart_and_verify_service "$service_name"; then
                        echo -e "${YELLOW}已回滚到端口 ${mod_port}，服务恢复正常${RESET}"
                    else
                        echo -e "${RED}回滚后服务仍未启动，请手动检查: systemctl status ${service_name}${RESET}"
                    fi
                fi
                ;;
            2)
                # 重置 PSK
                local new_psk=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
                sed -i "s/psk = .*/psk = ${new_psk}/" "$user_conf"
                systemctl restart "$service_name"
                echo -e "${GREEN}PSK 已重置为: ${new_psk}${RESET}"
                ;;
            3)
                # 修改 DNS（get_dns 已做格式校验；sed 转义 & 与分隔符，防止注入/语法错误）
                get_dns
                local dns_escaped
                dns_escaped=$(printf '%s' "$DNS" | sed 's/[&|\\]/\\&/g')
                sed -i "s|^[[:space:]]*dns[[:space:]]*=[[:space:]]*.*|dns = ${dns_escaped}|" "$user_conf"
                systemctl restart "$service_name"
                echo -e "${GREEN}DNS 修改成功${RESET}"
                ;;
            4)
                # 切换该用户使用的 Snell 通道
                select_user_snell_version "把端口 ${mod_port} 切换到哪个版本"
                switch_user_conf_version "$user_conf" "$SNELL_VERSION_CHOICE"
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
    
    # 获取要查看的用户端口（纯数字校验，拒绝 main 主配置）
    read -rp "请输入要查看的用户端口号: " view_port
    if ! validate_user_port "$view_port"; then
        return 1
    fi

    local user_conf="${SNELL_CONF_DIR}/users/snell-${view_port}.conf"
    
    if [ -f "$user_conf" ]; then
        local port=$(grep -E '^listen' "$user_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
        local psk=$(grep -E '^psk' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local dns=$(grep -E '^[[:space:]]*dns[[:space:]]*=' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local mode=$(grep -E '^[[:space:]]*mode[[:space:]]*=' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local dns_pref=$(grep -E '^[[:space:]]*dns-ip-preference[[:space:]]*=' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        # 版本取自这个用户自己的配置，而不是全局探测
        local installed_version=$(get_conf_snell_version "$user_conf")

        echo -e "\n${GREEN}用户配置详情：${RESET}"
        echo -e "${CYAN}--------------------------------${RESET}"
        echo -e "${YELLOW}端口: ${port}${RESET}"
        echo -e "${YELLOW}版本: Snell ${installed_version}${RESET}"
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
