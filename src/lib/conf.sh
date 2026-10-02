# ── lib/conf.sh ───────────────────────────────────────────────────────────────
# 用户配置：选版本与 v6 参数、写入与迁移配置、端口 / DNS / IPv6 输入、Surge 配置行。
# snell.sh、multi-user.sh 共用（bash）。

# 全局变量：选择的 Snell 版本
SNELL_VERSION_CHOICE=""

# Snell v6 加密模式：default / unshaped / unsafe-raw（客户端必须与服务端一致）
SNELL_MODE="default"

# Snell v6 DNS 解析地址族偏好：default / prefer-ipv4 / prefer-ipv6 / ipv4-only / ipv6-only
# 留空表示跟随 IPv6 开关自动推导
SNELL_DNS_IP_PREFERENCE=""

# 标记用户是否在本次操作中显式选择过 v6 参数（影响升级时是否覆盖已有配置）
SNELL_V6_OPTIONS_SET="false"

IPV6_ENABLE="true"

# === 新增：版本选择函数 ===
# 选择 Snell 版本
select_snell_version() {
    echo -e "${CYAN}请选择要安装的 Snell 版本：${RESET}"
    echo -e "${GREEN}1.${RESET} Snell v4"
    echo -e "${GREEN}2.${RESET} Snell v5"
    echo -e "${GREEN}3.${RESET} Snell v6 (RC)"

    while true; do
        read -rp "请输入选项 [1-3]: " version_choice
        case "$version_choice" in
            1)
                SNELL_VERSION_CHOICE="v4"
                echo -e "${GREEN}已选择 Snell v4${RESET}"
                break
                ;;
            2)
                SNELL_VERSION_CHOICE="v5"
                echo -e "${GREEN}已选择 Snell v5${RESET}"
                break
                ;;
            3)
                SNELL_VERSION_CHOICE="v6"
                echo -e "${GREEN}已选择 Snell v6 (RC)${RESET}"
                echo -e "${YELLOW}注意：v6 仍为预发布版本，协议可能存在不兼容更新${RESET}"
                echo -e "${YELLOW}v6 已移除 QUIC 代理模式与 obfs，且不提供 armv7l 构建${RESET}"
                echo -e "${YELLOW}加密模式：mode = ${SNELL_MODE}（客户端需配置相同的 mode）${RESET}"
                break
                ;;
            *)
                echo -e "${RED}请输入正确的选项 [1-3]${RESET}"
                ;;
        esac
    done
}

# === Snell v6 参数选择 ===
# 加密模式 (mode)：客户端必须配置完全相同的值，否则无法连接
select_snell_v6_mode() {
    local current="$1"
    local default_choice="1"
    case "$current" in
        unshaped)   default_choice="2" ;;
        unsafe-raw) default_choice="3" ;;
    esac

    echo -e "\n${CYAN}=== Snell v6 加密模式 (mode) ===${RESET}"
    echo -e "${YELLOW}客户端必须配置与服务端完全相同的 mode，不一致将无法连接${RESET}\n"
    echo -e "${GREEN}1.${RESET} default     流量混淆 + AES 加密"
    echo -e "   特征伪装最完整，抗识别与抗封锁能力最强"
    echo -e "   ${CYAN}建议：绝大多数用户、线路存在干扰或 QoS 时选此项${RESET}"
    echo -e "${GREEN}2.${RESET} unshaped    关闭混淆，仅 AES 加密"
    echo -e "   吞吐相比 default 提升约 10%，但流量特征更明显"
    echo -e "   ${CYAN}建议：线路干净、以速度为先，或已叠加 ShadowTLS 等外层伪装时选此项${RESET}"
    echo -e "${GREEN}3.${RESET} unsafe-raw  明文转发，不加密不混淆"
    echo -e "   ${RED}数据可被完整还原，公网环境切勿使用${RESET}"
    echo -e "   ${CYAN}建议：仅用于内网或完全可信链路的性能测试${RESET}\n"

    while true; do
        read -rp "请选择加密模式 [1-3]（回车使用 ${default_choice}）: " mode_choice
        [ -z "$mode_choice" ] && mode_choice="$default_choice"
        case "$mode_choice" in
            1) SNELL_MODE="default";    break ;;
            2) SNELL_MODE="unshaped";   break ;;
            3)
                SNELL_MODE="unsafe-raw"
                echo -e "${RED}警告：unsafe-raw 为明文传输，请确认该链路完全可信！${RESET}"
                read -rp "确认使用 unsafe-raw? [y/N]: " raw_confirm
                case "$raw_confirm" in
                    [yY]|[yY][eE][sS]) break ;;
                    *) echo -e "${CYAN}已取消，请重新选择${RESET}" ;;
                esac
                ;;
            *) echo -e "${RED}请输入正确的选项 [1-3]${RESET}" ;;
        esac
    done
    echo -e "${GREEN}已选择 mode = ${SNELL_MODE}${RESET}"
}

# DNS 解析地址族偏好 (dns-ip-preference)：影响服务端解析目标域名后用哪种地址出站
select_snell_v6_dns_preference() {
    local current="$1"
    local default_choice="1"

    # 未指定时按 IPv6 开关推导默认值
    if [ -z "$current" ]; then
        [ "$IPV6_ENABLE" = "false" ] && default_choice="4"
    else
        case "$current" in
            default)     default_choice="1" ;;
            prefer-ipv4) default_choice="2" ;;
            prefer-ipv6) default_choice="3" ;;
            ipv4-only)   default_choice="4" ;;
            ipv6-only)   default_choice="5" ;;
        esac
    fi

    echo -e "\n${CYAN}=== Snell v6 DNS 解析偏好 (dns-ip-preference) ===${RESET}"
    echo -e "${YELLOW}控制服务端解析目标域名后优先使用哪种地址族出站，与监听地址无关${RESET}\n"
    echo -e "${GREEN}1.${RESET} default       跟随系统默认解析行为"
    echo -e "   ${CYAN}建议：不确定时选此项，适配绝大多数 VPS${RESET}"
    echo -e "${GREEN}2.${RESET} prefer-ipv4   双栈可用时优先 IPv4，失败再试 IPv6"
    echo -e "   ${CYAN}建议：IPv6 出口质量差、或目标站点 IPv6 解锁较差时${RESET}"
    echo -e "${GREEN}3.${RESET} prefer-ipv6   双栈可用时优先 IPv6，失败再试 IPv4"
    echo -e "   ${CYAN}建议：IPv6 线路更优，或需要 IPv6 解锁流媒体时${RESET}"
    echo -e "${GREEN}4.${RESET} ipv4-only     只使用 IPv4 解析结果"
    echo -e "   ${CYAN}建议：VPS 无 IPv6 出口，避免连接 IPv6 目标时超时等待${RESET}"
    echo -e "${GREEN}5.${RESET} ipv6-only     只使用 IPv6 解析结果"
    echo -e "   ${CYAN}建议：IPv6 Only 的 VPS（无 IPv4 出口）${RESET}\n"

    while true; do
        read -rp "请选择 DNS 解析偏好 [1-5]（回车使用 ${default_choice}）: " dns_pref_choice
        [ -z "$dns_pref_choice" ] && dns_pref_choice="$default_choice"
        case "$dns_pref_choice" in
            1) SNELL_DNS_IP_PREFERENCE="default";     break ;;
            2) SNELL_DNS_IP_PREFERENCE="prefer-ipv4"; break ;;
            3) SNELL_DNS_IP_PREFERENCE="prefer-ipv6"; break ;;
            4) SNELL_DNS_IP_PREFERENCE="ipv4-only";   break ;;
            5) SNELL_DNS_IP_PREFERENCE="ipv6-only";   break ;;
            *) echo -e "${RED}请输入正确的选项 [1-5]${RESET}" ;;
        esac
    done
    echo -e "${GREEN}已选择 dns-ip-preference = ${SNELL_DNS_IP_PREFERENCE}${RESET}"
}

# 统一入口：安装 v6 或升级到 v6 时调用，可传入现有配置文件以沿用当前取值
configure_snell_v6_options() {
    local conf_file="$1"
    local current_mode="" current_pref=""

    if [ -n "$conf_file" ] && [ -f "$conf_file" ]; then
        current_mode=$(grep -E '^[[:space:]]*mode[[:space:]]*=' "$conf_file" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' ')
        current_pref=$(grep -E '^[[:space:]]*dns-ip-preference[[:space:]]*=' "$conf_file" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' ')
        if [ -n "$current_mode" ] || [ -n "$current_pref" ]; then
            echo -e "${CYAN}检测到当前配置：mode = ${current_mode:-未设置}，dns-ip-preference = ${current_pref:-未设置}${RESET}"
        fi
    fi

    select_snell_v6_mode "$current_mode"
    select_snell_v6_dns_preference "$current_pref"
    SNELL_V6_OPTIONS_SET="true"

    echo -e "\n${CYAN}=== v6 参数确认 ===${RESET}"
    echo -e "${GREEN}服务端 mode              : ${SNELL_MODE}${RESET}"
    echo -e "${GREEN}服务端 dns-ip-preference : ${SNELL_DNS_IP_PREFERENCE}${RESET}"
    echo -e "${YELLOW}客户端对应配置：version = 6, mode = ${SNELL_MODE}${RESET}"
}

# 读取已安装 v6 服务端使用的 mode（读不到时回落到默认值）
get_snell_mode() {
    local conf_file="${1:-${SNELL_CONF_DIR}/users/snell-main.conf}"
    local mode=""
    if [ -f "$conf_file" ]; then
        mode=$(grep -E '^[[:space:]]*mode[[:space:]]*=' "$conf_file" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' ')
    fi
    if [ -z "$mode" ]; then
        mode="$SNELL_MODE"
    fi
    echo "$mode"
}

# 生成 snell-server 配置文件
# v6 使用 mode / dns-ip-preference；ipv6 参数在 v6 已废弃（false 等价 ipv4-only）
write_snell_conf() {
    local conf_file="$1"
    local listen_addr="$2"
    local port="$3"
    local psk="$4"
    local ipv6_enable="$5"
    local dns="$6"
    local version_choice="$7"

    {
        case "$version_choice" in
            v4|v5|v6) echo "#${SNELL_VERSION_MARKER_KEY} = ${version_choice}" ;;
        esac
        echo "[snell-server]"
        echo "listen = ${listen_addr}:${port}"
        echo "psk = ${psk}"
        if [ "$version_choice" = "v6" ]; then
            echo "mode = ${SNELL_MODE}"
            if [ -n "$SNELL_DNS_IP_PREFERENCE" ]; then
                echo "dns-ip-preference = ${SNELL_DNS_IP_PREFERENCE}"
            elif [ "$ipv6_enable" = "false" ]; then
                echo "dns-ip-preference = ipv4-only"
            else
                echo "dns-ip-preference = default"
            fi
        else
            echo "ipv6 = ${ipv6_enable}"
        fi
        echo "dns = ${dns}"
    } > "$conf_file"

    # PSK 是共享密钥：仅属主可读写，避免本机其他用户读取
    chmod 600 "$conf_file" 2>/dev/null || true
    if getent passwd "${SNELL_SERVICE_USER}" >/dev/null 2>&1; then
        chown "${SNELL_SERVICE_USER}:${SNELL_SERVICE_GROUP}" "$conf_file" 2>/dev/null || true
    fi
}

# 版本切换后同步配置文件参数：v6 用 mode / dns-ip-preference，v4/v5 用 ipv6
migrate_snell_conf_for_version() {
    local conf_file="$1"
    local version_choice="$2"
    [ -f "$conf_file" ] || return 0

    local ipv6_enable="true"
    if grep -Eq '^[[:space:]]*ipv6[[:space:]]*=[[:space:]]*false' "$conf_file" \
        || grep -Eq '^[[:space:]]*dns-ip-preference[[:space:]]*=[[:space:]]*ipv4-only' "$conf_file"; then
        ipv6_enable="false"
    fi

    # 沿用配置中已有的 v6 参数；仅当用户本次显式选择过才覆盖
    local target_mode target_pref
    target_mode=$(grep -E '^[[:space:]]*mode[[:space:]]*=' "$conf_file" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' ')
    target_pref=$(grep -E '^[[:space:]]*dns-ip-preference[[:space:]]*=' "$conf_file" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' ')

    if [ "$SNELL_V6_OPTIONS_SET" = "true" ]; then
        target_mode="$SNELL_MODE"
        target_pref="$SNELL_DNS_IP_PREFERENCE"
    fi

    [ -z "$target_mode" ] && target_mode="$SNELL_MODE"
    if [ -z "$target_pref" ]; then
        if [ "$ipv6_enable" = "false" ]; then
            target_pref="ipv4-only"
        else
            target_pref="default"
        fi
    fi

    local tmp_conf="${conf_file}.tmp"
    {
        grep -Ev '^[[:space:]]*(ipv6|mode|dns-ip-preference)[[:space:]]*=' "$conf_file"
        if [ "$version_choice" = "v6" ]; then
            echo "mode = ${target_mode}"
            echo "dns-ip-preference = ${target_pref}"
        else
            echo "ipv6 = ${ipv6_enable}"
        fi
    } > "$tmp_conf" || {
        rm -f "$tmp_conf"
        echo -e "${RED}生成配置失败: ${conf_file}${RESET}" >&2
        return 1
    }

    # 用 cat 回写保留原文件属主与权限（服务以 snell 用户身份读取）
    cat "$tmp_conf" > "$conf_file" || {
        rm -f "$tmp_conf"
        echo -e "${RED}回写配置失败: ${conf_file}${RESET}" >&2
        return 1
    }
    rm -f "$tmp_conf"

    # 通道归属随之更新，后续都以标记为准
    set_conf_snell_version "$conf_file" "$version_choice"
}

# 生成 Surge 配置格式
generate_surge_config() {
    local ip_addr=$1
    local port=$2
    local psk=$3
    local version=$4
    local country=$5
    local installed_version=$6

    if [ "$installed_version" = "v6" ]; then
        # v6 版本：v6 协议（已移除 QUIC 模式与 obfs），mode 必须与服务端一致
        local mode
        mode=$(get_snell_mode "$(snell_conf_for_port "$port")")
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 6, mode = ${mode}, reuse = true, tfo = true${RESET}"
    elif [ "$installed_version" = "v5" ]; then
        # v5 版本输出 v4 和 v5 两种配置
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 4, reuse = true, tfo = true${RESET}"
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 5, reuse = true, tfo = true${RESET}"
    else
        # v4 版本只输出 v4 配置
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 4, reuse = true, tfo = true${RESET}"
    fi
}

# 比较版本号（复用 snell_version_sort_key，正确处理 b4 / rc / rc2 / 正式版）
version_greater_equal() {
    local key1 key2
    key1=$(snell_version_sort_key "$1")
    key2=$(snell_version_sort_key "$2")

    [[ "$key1" > "$key2" || "$key1" == "$key2" ]]
}

# 用户输入端口号，范围 1-65535
get_user_port() {
    while true; do
        read -rp "请输入要使用的端口号 (1-65535): " PORT
        if [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
            if is_port_in_use "$PORT"; then
                echo -e "${YELLOW}警告：端口 ${PORT} 当前已被占用${RESET}"
                show_port_occupier "$PORT"
                read -rp "仍要使用该端口吗? [y/N]: " port_confirm
                case "$port_confirm" in
                    [yY]|[yY][eE][sS]) ;;
                    *)
                        echo -e "${CYAN}请重新选择端口${RESET}"
                        continue
                        ;;
                esac
            fi
            echo -e "${GREEN}已选择端口: $PORT${RESET}"
            break
        else
            echo -e "${RED}无效端口号，请输入 1 到 65535 之间的数字。${RESET}"
        fi
    done
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
# 校验单个 DNS 主机：IPv4 / IPv6 / 域名
validate_dns_host() {
    local host="$1"
    # IPv4：四段数字，每段 0-255
    if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local seg old_ifs="$IFS"
        IFS='.'
        for seg in $host; do
            if [ "$seg" -gt 255 ] 2>/dev/null; then
                IFS="$old_ifs"
                return 1
            fi
        done
        IFS="$old_ifs"
        return 0
    fi
    # IPv6：含冒号的十六进制组（宽松校验，snell 侧会再解析）
    if [[ "$host" == *:* ]] && [[ "$host" =~ ^[0-9A-Fa-f:.]+$ ]]; then
        return 0
    fi
    # 域名：字母数字点横线，不以点/横线开头结尾
    if [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]; then
        return 0
    fi
    return 1
}

# 校验 DNS 输入：允许英文逗号分隔的多个地址
validate_dns_input() {
    local dns_input="$1" item
    dns_input="${dns_input//[[:space:]]/}"
    [ -n "$dns_input" ] || return 1
    local old_ifs="$IFS"
    IFS=','
    for item in $dns_input; do
        if ! validate_dns_host "$item"; then
            IFS="$old_ifs"
            return 1
        fi
    done
    IFS="$old_ifs"
    return 0
}

# 获取用户输入的 DNS 服务器（校验 IPv4/IPv6/域名，非法输入要求重填）
get_dns() {
    while true; do
        read -rp "请输入 DNS 服务器地址 (直接回车使用系统DNS): " custom_dns
        if [ -z "$custom_dns" ]; then
            DNS=$(get_system_dns)
            echo -e "${GREEN}使用系统 DNS 服务器: $DNS${RESET}"
            return 0
        fi
        if validate_dns_input "$custom_dns"; then
            DNS="${custom_dns//[[:space:]]/}"
            echo -e "${GREEN}使用自定义 DNS 服务器: $DNS${RESET}"
            return 0
        fi
        echo -e "${RED}DNS 地址格式无效，请输入 IPv4/IPv6 地址或域名（多个请用英文逗号分隔）${RESET}"
    done
}

# 是否启用 IPv6
get_ipv6_choice() {
    IPV6_ENABLE="true"
    LISTEN_ADDR="::0"
    read -rp "是否启用 IPv6? [Y/n]: " ipv6_choice
    case "$ipv6_choice" in
        [nN]|[nN][oO])
            IPV6_ENABLE="false"
            LISTEN_ADDR="0.0.0.0"
            echo -e "${GREEN}已关闭 IPv6，仅监听 IPv4${RESET}"
            ;;
        *)
            echo -e "${GREEN}已启用 IPv6${RESET}"
            ;;
    esac
}
