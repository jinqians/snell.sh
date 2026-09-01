#!/bin/bash
# =========================================
# 作者: jinqians
# 日期: 2025年2月
# 网站：jinqians.com
# 描述: 这个脚本用于安装、卸载、查看和更新 Snell 代理
# =========================================

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

#当前版本号
current_version="5.5"

# 全局变量：选择的 Snell 版本
SNELL_VERSION_CHOICE=""

# Snell v6 加密模式：default / unshaped / unsafe-raw（客户端必须与服务端一致）
SNELL_MODE="default"

# Snell v6 DNS 解析地址族偏好：default / prefer-ipv4 / prefer-ipv6 / ipv4-only / ipv6-only
# 留空表示跟随 IPv6 开关自动推导
SNELL_DNS_IP_PREFERENCE=""

# 标记用户是否在本次操作中显式选择过 v6 参数（影响升级时是否覆盖已有配置）
SNELL_V6_OPTIONS_SET="false"

# 抓取失败时的兜底版本号
SNELL_V4_FALLBACK="v4.1.1"
SNELL_V5_FALLBACK="v5.0.1"
SNELL_V6_FALLBACK="v6.0.0rc2"

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

# Snell 官方发布页（旧的 manual.nssurge.com/others/snell.html 已下线）
SNELL_RELEASE_NOTES_URL="https://kb.nssurge.com/surge-knowledge-base/release-notes/snell"
SNELL_RELEASE_NOTES_URL_ZH="https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell"

# 抓取官方发布页内容
fetch_snell_release_notes() {
    local notes
    notes=$(curl -s --max-time 15 "$SNELL_RELEASE_NOTES_URL")
    if [ -z "$notes" ]; then
        notes=$(curl -s --max-time 15 "$SNELL_RELEASE_NOTES_URL_ZH")
    fi
    echo "$notes"
}

# 把版本号转成定长可排序键，排序优先级：beta < rc < 正式版
# 6.0.0b4 -> 006.000.000.1.0004；6.0.0rc -> 006.000.000.2.0000；6.0.0rc2 -> 006.000.000.2.0002；6.0.0 -> 006.000.000.3.0000
snell_version_sort_key() {
    echo "${1#[vV]}" | awk '{
        ver = $0
        suffix = ""
        if (match(ver, /[a-zA-Z]+[0-9]*$/)) {
            suffix = tolower(substr(ver, RSTART))
            ver = substr(ver, 1, RSTART - 1)
        }
        split(ver, part, ".")
        stage = 3
        seq = 0
        if (suffix != "") {
            stage = (suffix ~ /^rc/) ? 2 : 1
            digits = suffix
            gsub(/[^0-9]/, "", digits)
            if (digits != "") seq = digits + 0
        }
        printf "%03d.%03d.%03d.%d.%04d", part[1], part[2], part[3], stage, seq
    }'
}

# 从发布页中挑出指定大版本的最新版本（页面上的先后顺序不代表新旧，必须排序）
pick_latest_snell_version() {
    local major="$1"
    local notes="$2"

    echo "$notes" \
        | grep -oE "snell-server-v${major}\.[0-9]+\.[0-9]+[a-zA-Z0-9]*" \
        | sed 's/^snell-server-v//' \
        | sort -u \
        | while read -r ver; do
              echo "$(snell_version_sort_key "$ver") ${ver}"
          done \
        | sort \
        | tail -n 1 \
        | awk '{print $2}'
}

# 获取 Snell v4 最新版本
get_latest_snell_v4_version() {
    local ver
    ver=$(pick_latest_snell_version 4 "$(fetch_snell_release_notes)")
    if [ -n "$ver" ]; then
        echo "v${ver}"
    else
        echo "${SNELL_V4_FALLBACK}"
    fi
}

# 获取 Snell v5 最新版本
get_latest_snell_v5_version() {
    local ver
    ver=$(pick_latest_snell_version 5 "$(fetch_snell_release_notes)")
    if [ -n "$ver" ]; then
        echo "v${ver}"
    else
        echo "${SNELL_V5_FALLBACK}"
    fi
}

# 获取 Snell v6 最新版本
get_latest_snell_v6_version() {
    local ver
    ver=$(pick_latest_snell_version 6 "$(fetch_snell_release_notes)")
    if [ -n "$ver" ]; then
        echo "v${ver}"
    else
        echo "${SNELL_V6_FALLBACK}"
    fi
}

# 说明：按通道取最新版本号用 resolve_latest_version_for_channel，
# 生成下载地址用 snell_download_url_for（失败返回非 0，不会 exit 掉整个脚本），
# 两者都在下方「多版本共存」段落里。

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

# === 新增：备份和还原配置函数 ===
# 备份 Snell 配置
backup_snell_config() {
    local backup_dir="${SNELL_CONF_DIR}/backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    cp -a "${SNELL_CONF_DIR}/users"/*.conf "$backup_dir"/ 2>/dev/null
    echo "$backup_dir"
}

# 恢复 Snell 配置
restore_snell_config() {
    local backup_dir="$1"
    if [ -d "$backup_dir" ]; then
        cp -a "$backup_dir"/*.conf "${SNELL_CONF_DIR}/users"/
        echo -e "${GREEN}配置已从备份恢复。${RESET}"
    else
        echo -e "${RED}未找到备份目录，无法恢复配置。${RESET}"
    fi
}

# 检查 bc 是否安装
check_bc() {
    if ! command -v bc &> /dev/null; then
        echo -e "${YELLOW}未检测到 bc，正在安装...${RESET}"
        # 根据系统类型安装 bc
        if [ -x "$(command -v apt)" ]; then
            wait_for_apt
            apt update && apt install -y bc
        elif [ -x "$(command -v yum)" ]; then
            yum install -y bc
        else
            echo -e "${RED}未支持的包管理器，无法安装 bc。请手动安装 bc。${RESET}"
            exit 1
        fi
    fi
}

# 检查 curl 是否安装
check_curl() {
    if ! command -v curl &> /dev/null; then
        echo -e "${YELLOW}未检测到 curl，正在安装...${RESET}"
        if [ -x "$(command -v apt)" ]; then
            wait_for_apt
            apt update && apt install -y curl
        elif [ -x "$(command -v yum)" ]; then
            yum install -y curl
        else
            echo -e "${RED}未支持的包管理器，无法安装 curl。请手动安装 curl。${RESET}"
            exit 1
        fi
    fi
}

# 定义系统路径
INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
SNELL_CONF_DIR="/etc/snell"
SNELL_CONF_FILE="${SNELL_CONF_DIR}/users/snell-main.conf"
SYSTEMD_SERVICE_FILE="${SYSTEMD_DIR}/snell.service"
SYSTEMD_SOCKET_FILE="${SYSTEMD_DIR}/snell.socket"
SYSTEMD_NETNS_FILE="${SYSTEMD_DIR}/snell-netns.service"
NETNS_SETUP_SCRIPT="${INSTALL_DIR}/snell-netns-setup.sh"

# 出口控制（netns + socket activation）默认参数
EGRESS_FEATURE_ENABLED="false"
EGRESS_IFACE=""
EGRESS_NS="snell-egress"
EGRESS_HOST_IP=""
EGRESS_NS_IP=""
EGRESS_SUBNET=""
EGRESS_GW=""

# 旧的配置文件路径（用于兼容性检查）
OLD_SNELL_CONF_FILE="${SNELL_CONF_DIR}/snell-server.conf"
OLD_SYSTEMD_SERVICE_FILE="/lib/systemd/system/snell.service"
SNELL_SERVICE_USER="snell"
SNELL_SERVICE_GROUP="snell"

# =========================================
# 多版本共存（v4 / v5 / v6）支持
#
# 二进制布局：
#   ${INSTALL_DIR}/snell-server-v4|v5|v6   各通道的实体文件，systemd unit 直接指向它
#   ${INSTALL_DIR}/snell-server            软链，指向主用户所用通道（保留给旧的探测逻辑）
#
# 版本标记：
#   每个用户配置首行写 "#version-choice = vX"。注释形式，snell-server 不会解析到，
#   且随 .conf 一起被备份/还原，不需要额外的伴生文件。
# =========================================
SNELL_VERSION_MARKER_KEY="version-choice"
SNELL_ALL_VERSIONS="v4 v5 v6"

# 版本号 -> 二进制路径
snell_binary_for_version() {
    case "$1" in
        v4|v5|v6) echo "${INSTALL_DIR}/snell-server-$1" ;;
        *)        echo "${INSTALL_DIR}/snell-server" ;;
    esac
}

# 探测指定二进制自身的版本；不可执行时返回 unknown
probe_snell_binary_version() {
    local binary="$1"
    if [ ! -x "$binary" ]; then
        echo "unknown"
        return 1
    fi

    local version_output
    version_output=$("$binary" --v 2>&1)
    if echo "$version_output" | grep -q "v6"; then
        echo "v6"
    elif echo "$version_output" | grep -q "v5"; then
        echo "v5"
    else
        # 早期 v4 的 --v 输出不带大版本号，与历史行为保持一致按 v4 处理
        echo "v4"
    fi
}

# 列出已落盘的通道（空格分隔，可能为空）
list_installed_snell_versions() {
    local version installed=""
    for version in $SNELL_ALL_VERSIONS; do
        if [ -x "$(snell_binary_for_version "$version")" ]; then
            installed="${installed}${version} "
        fi
    done
    echo "${installed% }"
}

# 读取配置里的版本标记；没有标记时返回非 0
read_conf_snell_version() {
    local conf_file="$1"
    [ -f "$conf_file" ] || return 1

    local marked
    marked=$(grep -E "^[[:space:]]*#[[:space:]]*${SNELL_VERSION_MARKER_KEY}[[:space:]]*=" "$conf_file" \
        | head -n 1 | awk -F'=' '{print $2}' | tr -d '[:space:]')
    case "$marked" in
        v4|v5|v6) echo "$marked" ;;
        *)        return 1 ;;
    esac
}

# 配置对应的通道：优先读标记，读不到回落到软链的实际版本（兼容尚未迁移的老安装）
get_conf_snell_version() {
    local conf_file="$1"
    local marked
    if marked=$(read_conf_snell_version "$conf_file"); then
        echo "$marked"
        return 0
    fi
    detect_installed_snell_version
}

# 幂等写入版本标记：相同则跳过，不同则替换，缺失则插到首行。
# 用 cat 回写而不是 mv，保留原文件的属主与权限（服务以 snell 用户身份读取）
set_conf_snell_version() {
    local conf_file="$1"
    local version="$2"

    [ -f "$conf_file" ] || return 1
    case "$version" in
        v4|v5|v6) ;;
        *) return 1 ;;
    esac

    local current=""
    current=$(read_conf_snell_version "$conf_file" 2>/dev/null)
    if [ "$current" = "$version" ]; then
        return 0
    fi

    local tmp_conf="${conf_file}.vtmp.$$"
    if ! {
        echo "#${SNELL_VERSION_MARKER_KEY} = ${version}"
        grep -Ev "^[[:space:]]*#[[:space:]]*${SNELL_VERSION_MARKER_KEY}[[:space:]]*=" "$conf_file"
    } > "$tmp_conf"; then
        rm -f "$tmp_conf"
        echo -e "${RED}生成版本标记失败: ${conf_file}${RESET}" >&2
        return 1
    fi

    if ! cat "$tmp_conf" > "$conf_file"; then
        rm -f "$tmp_conf"
        echo -e "${RED}回写版本标记失败: ${conf_file}${RESET}" >&2
        return 1
    fi
    rm -f "$tmp_conf"
    return 0
}

# 端口 -> 配置文件路径（主端口走主配置）
snell_conf_for_port() {
    local port="$1"
    local main_port
    main_port=$(get_snell_port 2>/dev/null)
    if [ -n "$main_port" ] && [ "$port" = "$main_port" ]; then
        echo "$SNELL_CONF_FILE"
    else
        echo "${SNELL_CONF_DIR}/users/snell-${port}.conf"
    fi
}

# 端口 -> 通道
get_port_snell_version() {
    get_conf_snell_version "$(snell_conf_for_port "$1")"
}

# 端口 -> systemd 服务名
snell_service_for_port() {
    local port="$1"
    local main_port
    main_port=$(get_snell_port 2>/dev/null)
    if [ -n "$main_port" ] && [ "$port" = "$main_port" ]; then
        echo "snell"
    else
        echo "snell-${port}"
    fi
}

# 指定通道当前被哪些服务使用（每行一个 systemd 服务名）
list_services_using_version() {
    local version="$1"
    local conf_file port

    if [ -f "$SNELL_CONF_FILE" ] && [ "$(get_conf_snell_version "$SNELL_CONF_FILE")" = "$version" ]; then
        echo "snell"
    fi

    [ -d "${SNELL_CONF_DIR}/users" ] || return 0
    for conf_file in "${SNELL_CONF_DIR}/users"/snell-*.conf; do
        [ -f "$conf_file" ] || continue
        case "$conf_file" in
            *snell-main.conf) continue ;;
        esac
        port=$(grep -E '^listen' "$conf_file" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
        [ -n "$port" ] || continue
        if [ "$(get_conf_snell_version "$conf_file")" = "$version" ]; then
            echo "snell-${port}"
        fi
    done
}

# 让 snell-server 软链指向指定通道（旧探测逻辑与 ShadowTLS 仍依赖这个名字）
update_snell_symlink() {
    local version="$1"
    local target
    target=$(snell_binary_for_version "$version")

    # 目标不存在时不动现场，避免把可用的旧二进制删成断链
    if [ ! -x "$target" ]; then
        return 1
    fi

    if [ -e "${INSTALL_DIR}/snell-server" ] && [ ! -L "${INSTALL_DIR}/snell-server" ]; then
        rm -f "${INSTALL_DIR}/snell-server"
    fi
    ln -sfn "$target" "${INSTALL_DIR}/snell-server"
}

# 生成指定通道 + 版本号的下载地址；不支持的架构返回非 0（不 exit，调用方可继续）
snell_download_url_for() {
    local version_choice="$1"
    local resolved_version="$2"
    local arch
    arch=$(uname -m)

    if [ "$version_choice" = "v6" ] && { [ "$arch" = "armv7l" ] || [ "$arch" = "armv7" ]; }; then
        echo -e "${RED}Snell v6 暂不提供 armv7l 构建${RESET}" >&2
        return 1
    fi

    case "$arch" in
        "x86_64"|"amd64")  echo "https://dl.nssurge.com/snell/snell-server-${resolved_version}-linux-amd64.zip" ;;
        "i386"|"i686")     echo "https://dl.nssurge.com/snell/snell-server-${resolved_version}-linux-i386.zip" ;;
        "aarch64"|"arm64") echo "https://dl.nssurge.com/snell/snell-server-${resolved_version}-linux-aarch64.zip" ;;
        "armv7l"|"armv7")  echo "https://dl.nssurge.com/snell/snell-server-${resolved_version}-linux-armv7l.zip" ;;
        *)
            echo -e "${RED}不支持的架构: ${arch}${RESET}" >&2
            return 1
            ;;
    esac
}

# 解析指定通道的最新版本号（失败时回落到内置常量）
resolve_latest_version_for_channel() {
    case "$1" in
        v6) get_latest_snell_v6_version ;;
        v5) get_latest_snell_v5_version ;;
        v4) get_latest_snell_v4_version ;;
        *)  return 1 ;;
    esac
}

# 下载指定通道的二进制到版本化路径。force=true 时即使已存在也重新下载。
# 只往 stderr 打印进度，stdout 留给调用方使用。
install_snell_binary_for_version() {
    local version="$1"
    local force="${2:-false}"
    local target
    target=$(snell_binary_for_version "$version")

    if [ -x "$target" ] && [ "$force" != "true" ]; then
        return 0
    fi

    local resolved
    resolved=$(resolve_latest_version_for_channel "$version")
    if [ -z "$resolved" ]; then
        echo -e "${RED}无法确定 Snell ${version} 的版本号${RESET}" >&2
        return 1
    fi

    local url
    if ! url=$(snell_download_url_for "$version" "$resolved"); then
        return 1
    fi

    echo -e "${CYAN}正在下载 Snell ${version} (${resolved})...${RESET}" >&2
    echo -e "${YELLOW}${url}${RESET}" >&2

    local tmp_dir
    tmp_dir=$(mktemp -d) || return 1

    local downloaded=false
    if command -v wget >/dev/null 2>&1; then
        wget -O "${tmp_dir}/snell-server.zip" "$url" && downloaded=true
    elif command -v curl >/dev/null 2>&1; then
        curl -fL --retry 2 -o "${tmp_dir}/snell-server.zip" "$url" && downloaded=true
    else
        echo -e "${RED}系统缺少 wget 与 curl，无法下载${RESET}" >&2
    fi

    if [ "$downloaded" != "true" ]; then
        echo -e "${RED}下载 Snell ${version} 失败: ${url}${RESET}" >&2
        rm -rf "$tmp_dir"
        return 1
    fi

    if ! unzip -o -q "${tmp_dir}/snell-server.zip" -d "$tmp_dir"; then
        echo -e "${RED}解压 Snell ${version} 失败${RESET}" >&2
        rm -rf "$tmp_dir"
        return 1
    fi

    if [ ! -f "${tmp_dir}/snell-server" ]; then
        echo -e "${RED}压缩包中未找到 snell-server 可执行文件${RESET}" >&2
        rm -rf "$tmp_dir"
        return 1
    fi

    # install 是原子替换，正在运行的旧进程持有旧 inode，不受影响
    if ! install -m 755 "${tmp_dir}/snell-server" "$target"; then
        echo -e "${RED}写入 ${target} 失败${RESET}" >&2
        rm -rf "$tmp_dir"
        return 1
    fi
    rm -rf "$tmp_dir"

    # 落盘后核验：装进来的确实是这个通道
    local actual
    actual=$(probe_snell_binary_version "$target")
    if [ "$actual" != "$version" ]; then
        echo -e "${YELLOW}警告：${target} 自报版本为 ${actual}，与预期的 ${version} 不一致${RESET}" >&2
    fi

    echo -e "${GREEN}✓ Snell ${version} (${resolved}) 已就位: ${target}${RESET}" >&2
    return 0
}

# 确保指定通道可用，缺失时自动下载
ensure_snell_binary() {
    install_snell_binary_for_version "$1" "false"
}

# 主服务应使用的二进制路径（标记缺失或二进制未就位时回落到软链）
main_snell_binary() {
    local version target
    version=$(get_conf_snell_version "$SNELL_CONF_FILE")
    target=$(snell_binary_for_version "$version")
    if [ -x "$target" ]; then
        echo "$target"
    else
        echo "${INSTALL_DIR}/snell-server"
    fi
}

# 把 unit 的 ExecStart 从裸 snell-server 切到版本化二进制。
# 已经是版本化路径的会被跳过（模式带尾随空格，不会命中 snell-server-v5），因此可重复执行。
sync_service_units_to_versioned_binary() {
    local changed=false
    local conf_file port unit version target

    if [ -f "$SYSTEMD_SERVICE_FILE" ] && grep -q "ExecStart=${INSTALL_DIR}/snell-server " "$SYSTEMD_SERVICE_FILE"; then
        version=$(get_conf_snell_version "$SNELL_CONF_FILE")
        target=$(snell_binary_for_version "$version")
        if [ -x "$target" ]; then
            sed -i "s|ExecStart=${INSTALL_DIR}/snell-server |ExecStart=${target} |" "$SYSTEMD_SERVICE_FILE"
            changed=true
        fi
    fi

    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for conf_file in "${SNELL_CONF_DIR}/users"/snell-*.conf; do
            [ -f "$conf_file" ] || continue
            case "$conf_file" in
                *snell-main.conf) continue ;;
            esac
            port=$(grep -E '^listen' "$conf_file" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
            [ -n "$port" ] || continue
            unit="${SYSTEMD_DIR}/snell-${port}.service"
            [ -f "$unit" ] || continue
            grep -q "ExecStart=${INSTALL_DIR}/snell-server " "$unit" || continue

            version=$(get_conf_snell_version "$conf_file")
            target=$(snell_binary_for_version "$version")
            if [ -x "$target" ]; then
                sed -i "s|ExecStart=${INSTALL_DIR}/snell-server |ExecStart=${target} |" "$unit"
                changed=true
            fi
        done
    fi

    if [ "$changed" = "true" ]; then
        systemctl daemon-reload 2>/dev/null || true
        echo -e "${GREEN}✓ systemd 服务已切换到版本化二进制路径${RESET}"
    fi
}

# 把一个 unit 的 ExecStart 指到目标通道的二进制（用于切换用户版本）
point_service_unit_to_version() {
    local unit="$1"
    local version="$2"
    local target
    target=$(snell_binary_for_version "$version")

    [ -f "$unit" ] || return 1
    [ -x "$target" ] || return 1

    sed -i -E "s|ExecStart=${INSTALL_DIR}/snell-server(-v[456])? |ExecStart=${target} |" "$unit"
}

# 老布局（唯一的 /usr/local/bin/snell-server 实体文件）迁移到按通道分开存。
# 幂等：已经是软链且配置都带标记时，什么都不做。
migrate_snell_binary_layout() {
    local snell_bin="${INSTALL_DIR}/snell-server"
    local main_version=""

    if [ -e "$snell_bin" ] && [ ! -L "$snell_bin" ]; then
        local detected versioned
        detected=$(probe_snell_binary_version "$snell_bin")
        if [ "$detected" = "unknown" ]; then
            echo -e "${YELLOW}无法识别 ${snell_bin} 的版本，跳过二进制布局迁移${RESET}"
            return 1
        fi

        versioned=$(snell_binary_for_version "$detected")
        echo -e "${CYAN}检测到旧的单版本布局，正在迁移为多版本布局...${RESET}"
        if [ ! -e "$versioned" ]; then
            if ! cp -a "$snell_bin" "$versioned"; then
                echo -e "${RED}复制二进制到 ${versioned} 失败，已保留原布局${RESET}"
                return 1
            fi
        fi
        chmod 755 "$versioned" 2>/dev/null || true
        ln -sfn "$versioned" "$snell_bin"
        echo -e "${GREEN}✓ ${snell_bin} 现在指向 ${versioned}（Snell ${detected}）${RESET}"
        main_version="$detected"
    elif [ -L "$snell_bin" ]; then
        main_version=$(probe_snell_binary_version "$snell_bin")
    fi

    [ "$main_version" = "unknown" ] && main_version=""

    # 给还没有版本标记的配置补上（老安装里所有用户必然同版本）
    if [ -n "$main_version" ] && [ -d "${SNELL_CONF_DIR}/users" ]; then
        local conf_file
        for conf_file in "${SNELL_CONF_DIR}/users"/*.conf; do
            [ -f "$conf_file" ] || continue
            if read_conf_snell_version "$conf_file" >/dev/null 2>&1; then
                continue
            fi
            if set_conf_snell_version "$conf_file" "$main_version"; then
                echo -e "${GREEN}✓ 已为 $(basename "$conf_file") 标记版本 ${main_version}${RESET}"
            fi
        done
    fi

    sync_service_units_to_versioned_binary
    return 0
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

ensure_snell_config_dir() {
    ensure_snell_service_user
    mkdir -p "${SNELL_CONF_DIR}/users"
    if getent group "${SNELL_SERVICE_GROUP}" >/dev/null 2>&1 && getent passwd "${SNELL_SERVICE_USER}" >/dev/null 2>&1; then
        chown -R "${SNELL_SERVICE_USER}:${SNELL_SERVICE_GROUP}" "${SNELL_CONF_DIR}" 2>/dev/null || true
    fi
    chmod 755 "${SNELL_CONF_DIR}" "${SNELL_CONF_DIR}/users" 2>/dev/null || true
}

migrate_legacy_main_config_if_needed() {
    ensure_snell_config_dir

    if [ -f "$SNELL_CONF_FILE" ]; then
        return 0
    fi

    if [ -f "$OLD_SNELL_CONF_FILE" ]; then
        cp -a "$OLD_SNELL_CONF_FILE" "$SNELL_CONF_FILE"
        if getent group "${SNELL_SERVICE_GROUP}" >/dev/null 2>&1 && getent passwd "${SNELL_SERVICE_USER}" >/dev/null 2>&1; then
            chown "${SNELL_SERVICE_USER}:${SNELL_SERVICE_GROUP}" "$SNELL_CONF_FILE" 2>/dev/null || true
        fi
        chmod 644 "$SNELL_CONF_FILE"
        echo -e "${GREEN}已将旧配置迁移到 ${SNELL_CONF_FILE}${RESET}"
        return 0
    fi

    return 1
}

validate_snell_main_config() {
    migrate_legacy_main_config_if_needed || true

    if [ ! -s "$SNELL_CONF_FILE" ]; then
        echo -e "${RED}主配置文件不存在: ${SNELL_CONF_FILE}${RESET}"
        echo -e "${YELLOW}请先执行安装，或将旧配置放到该路径后再启动服务。${RESET}"
        return 1
    fi

    if ! grep -Eq '^[[:space:]]*listen[[:space:]]*=' "$SNELL_CONF_FILE"; then
        echo -e "${RED}主配置缺少 listen 配置: ${SNELL_CONF_FILE}${RESET}"
        return 1
    fi

    if ! grep -Eq '^[[:space:]]*psk[[:space:]]*=' "$SNELL_CONF_FILE"; then
        echo -e "${RED}主配置缺少 psk 配置: ${SNELL_CONF_FILE}${RESET}"
        return 1
    fi

    return 0
}

write_main_systemd_service() {
    ensure_snell_config_dir
    local snell_binary
    snell_binary=$(main_snell_binary)
    cat > ${SYSTEMD_SERVICE_FILE} << EOF
[Unit]
Description=Snell Proxy Service (Main)
After=network.target

[Service]
Type=simple
User=${SNELL_SERVICE_USER}
Group=${SNELL_SERVICE_GROUP}
LimitNOFILE=32768
ExecStart=${snell_binary} -c ${SNELL_CONF_FILE}
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=on-failure
RestartSec=2s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=snell-server

[Install]
WantedBy=multi-user.target
EOF
}

sync_existing_main_service_unit() {
    if [ ! -f "$SYSTEMD_SERVICE_FILE" ]; then
        return 0
    fi

    if systemctl is-enabled --quiet snell.socket 2>/dev/null; then
        return 0
    fi

    if grep -q "NetworkNamespacePath=" "$SYSTEMD_SERVICE_FILE"; then
        return 0
    fi

    if ! grep -Eq "ExecStart=${INSTALL_DIR}/snell-server(-v[456])? -c ${SNELL_CONF_FILE}" "$SYSTEMD_SERVICE_FILE"; then
        return 0
    fi

    if grep -q "StandardOutput=syslog\\|StandardError=syslog\\|User=nobody\\|Group=nogroup" "$SYSTEMD_SERVICE_FILE"; then
        write_main_systemd_service
        systemctl daemon-reload 2>/dev/null || true
        echo -e "${GREEN}已更新 snell.service systemd 配置。${RESET}"
    fi
}

# 根据 /30 子网生成 host/ns 地址与网关
apply_egress_subnet() {
    local subnet="$1"
    local base prefix

    base="${subnet%/30}"
    prefix="${base%.*}"

    EGRESS_SUBNET="$subnet"
    EGRESS_HOST_IP="${prefix}.1/30"
    EGRESS_NS_IP="${prefix}.2/30"
    EGRESS_GW="${prefix}.1"
}

# 自动选择未占用的 /30 子网（默认池：172.31.0.0/16）
auto_pick_egress_subnet() {
    local i candidate

    if ! command -v ip &> /dev/null; then
        apply_egress_subnet "172.31.0.0/30"
        return
    fi

    for i in $(seq 0 255); do
        candidate="172.31.${i}.0/30"
        if ip -o -4 addr show | grep -q "172\\.31\\.${i}\\."; then
            continue
        fi
        if ip -4 route show | grep -q "172\\.31\\.${i}\\."; then
            continue
        fi

        apply_egress_subnet "$candidate"
        return
    done

    apply_egress_subnet "172.31.0.0/30"
}

# 初始化默认网段
auto_pick_egress_subnet

# 自动检测默认出口网卡
auto_detect_egress_iface() {
    local detected_iface

    if command -v ip &> /dev/null; then
        detected_iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    fi

    if [ -n "$detected_iface" ]; then
        EGRESS_IFACE="$detected_iface"
    elif [ -z "$EGRESS_IFACE" ]; then
        EGRESS_IFACE="eth1"
    fi
}

# 初始化默认出口网卡
auto_detect_egress_iface

# 检查并迁移旧配置
check_and_migrate_config() {
    local need_migration=false
    local old_files_exist=false

    # 自动修复 4.x -> 5.x 后服务指向新路径、配置仍在旧路径导致的启动失败。
    if [ ! -f "$SNELL_CONF_FILE" ] && [ -f "$OLD_SNELL_CONF_FILE" ]; then
        migrate_legacy_main_config_if_needed
        if [ -f "$SYSTEMD_SERVICE_FILE" ] && ! systemctl is-enabled --quiet snell.socket 2>/dev/null; then
            write_main_systemd_service
            systemctl daemon-reload 2>/dev/null || true
        fi
    fi

    # 检查仍需人工处理的旧配置。若主配置已自动迁移成功，仅保留旧文件不再反复提示。
    if { [ ! -f "$SNELL_CONF_FILE" ] && [ -f "$OLD_SNELL_CONF_FILE" ]; } || [ -f "$OLD_SYSTEMD_SERVICE_FILE" ]; then
        old_files_exist=true
        echo -e "\n${YELLOW}检测到旧版本的 Snell 配置文件${RESET}"
        echo -e "旧配置位置："
        [ -f "$OLD_SNELL_CONF_FILE" ] && echo -e "- 配置文件：${OLD_SNELL_CONF_FILE}"
        [ -f "$OLD_SYSTEMD_SERVICE_FILE" ] && echo -e "- 服务文件：${OLD_SYSTEMD_SERVICE_FILE}"
        
        # 检查用户目录是否存在
        if [ ! -d "${SNELL_CONF_DIR}/users" ]; then
            need_migration=true
            mkdir -p "${SNELL_CONF_DIR}/users"
            # 设置正确的目录权限
            ensure_snell_service_user
            chown -R "${SNELL_SERVICE_USER}:${SNELL_SERVICE_GROUP}" "${SNELL_CONF_DIR}"
            chmod -R 755 "${SNELL_CONF_DIR}"
        fi
    fi

    # 如果需要迁移，询问用户
    if [ "$old_files_exist" = true ]; then
        echo -e "\n${YELLOW}是否要迁移旧的配置文件？[y/N]${RESET}"
        read -r choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            echo -e "${CYAN}开始迁移配置文件...${RESET}"
            
            # 停止服务
            systemctl stop snell 2>/dev/null
            
            # 迁移配置文件
            if [ -f "$OLD_SNELL_CONF_FILE" ]; then
                cp "$OLD_SNELL_CONF_FILE" "${SNELL_CONF_FILE}"
                # 设置正确的文件权限
                ensure_snell_service_user
                chown "${SNELL_SERVICE_USER}:${SNELL_SERVICE_GROUP}" "${SNELL_CONF_FILE}"
                chmod 644 "${SNELL_CONF_FILE}"
                echo -e "${GREEN}已迁移配置文件${RESET}"
            fi
            
            # 迁移服务文件
            if [ -f "$OLD_SYSTEMD_SERVICE_FILE" ]; then
                write_main_systemd_service
                echo -e "${GREEN}已迁移服务文件${RESET}"
            fi
            
            # 询问是否删除旧文件
            echo -e "${YELLOW}是否删除旧的配置文件？[y/N]${RESET}"
            read -r del_choice
            if [[ "$del_choice" == "y" || "$del_choice" == "Y" ]]; then
                [ -f "$OLD_SNELL_CONF_FILE" ] && rm -f "$OLD_SNELL_CONF_FILE"
                [ -f "$OLD_SYSTEMD_SERVICE_FILE" ] && rm -f "$OLD_SYSTEMD_SERVICE_FILE"
                echo -e "${GREEN}已删除旧的配置文件${RESET}"
            fi
            
            # 重新加载服务
            systemctl daemon-reload
            if validate_snell_main_config; then
                systemctl start snell
            fi
            
            # 验证服务状态
            if systemctl is-active --quiet snell; then
                echo -e "${GREEN}配置迁移完成，服务已成功启动${RESET}"
            else
                echo -e "${RED}警告：服务启动失败，请检查配置文件和权限${RESET}"
                systemctl status snell
            fi
        else
            echo -e "${YELLOW}跳过配置迁移${RESET}"
        fi
    fi
}

# 自动更新脚本
auto_update_script() {
    echo -e "${CYAN}正在检查脚本更新...${RESET}"
    
    # 创建临时文件
    TMP_SCRIPT=$(mktemp)
    
    # 下载最新版本
    if curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/main/snell.sh -o "$TMP_SCRIPT"; then
        # 获取新版本号
        new_version=$(grep -m1 -E '^current_version="' "$TMP_SCRIPT" | cut -d'"' -f2)
        
        # 比较版本号
        if [ "$new_version" != "$current_version" ]; then
            echo -e "${GREEN}发现新版本：${new_version}${RESET}"
            echo -e "${YELLOW}当前版本：${current_version}${RESET}"
            
            # 备份当前脚本
            cp "$0" "${0}.backup"
            
            # 更新脚本
            mv "$TMP_SCRIPT" "$0"
            chmod +x "$0"
            
            echo -e "${GREEN}脚本已更新到最新版本${RESET}"
            echo -e "${YELLOW}已备份原脚本到：${0}.backup${RESET}"
            
            # 提示用户重新运行脚本
            echo -e "${CYAN}请重新运行脚本以使用新版本${RESET}"
            exit 0
        else
            echo -e "${GREEN}当前已是最新版本 (${current_version})${RESET}"
            rm -f "$TMP_SCRIPT"
        fi
    else
        echo -e "${RED}检查更新失败，请检查网络连接${RESET}"
        rm -f "$TMP_SCRIPT"
    fi
}

# 等待其他 apt 进程完成
wait_for_apt() {
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
        echo -e "${YELLOW}等待其他 apt 进程完成...${RESET}"
        sleep 1
    done
}

# 检查是否以 root 权限运行
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请以 root 权限运行此脚本.${RESET}"
        exit 1
    fi
}
check_root

# 检查 jq 是否安装
check_jq() {
    if ! command -v jq &> /dev/null; then
        echo -e "${YELLOW}未检测到 jq，正在安装...${RESET}"
        # 根据系统类型安装 jq
        if [ -x "$(command -v apt)" ]; then
            wait_for_apt
            apt update && apt install -y jq
        elif [ -x "$(command -v yum)" ]; then
            yum install -y jq
        else
            echo -e "${RED}未支持的包管理器，无法安装 jq。请手动安装 jq。${RESET}"
            exit 1
        fi
    fi
}
check_jq

# 检查 Snell 是否已安装
check_snell_installed() {
    if command -v snell-server &> /dev/null; then
        return 0
    else
        return 1
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

# 是否启用 Snell v5/v6 出口控制
get_egress_feature_choice() {
    EGRESS_FEATURE_ENABLED="false"
    if [ "$SNELL_VERSION_CHOICE" != "v5" ] && [ "$SNELL_VERSION_CHOICE" != "v6" ]; then
        return
    fi

    echo -e "${CYAN}是否启用 Snell ${SNELL_VERSION_CHOICE} 出口控制（netns + socket activation）？${RESET}"
    echo -e "${GREEN}1.${RESET} 启用（新特性）"
    echo -e "${GREEN}2.${RESET} 不启用（推荐）"

    while true; do
        read -rp "请输入选项 [1-2]: " egress_choice
        case "$egress_choice" in
            1)
                EGRESS_FEATURE_ENABLED="true"
                echo -e "${GREEN}已启用 Snell v5 出口控制${RESET}"
                break
                ;;
            2)
                EGRESS_FEATURE_ENABLED="false"
                echo -e "${YELLOW}已选择传统模式${RESET}"
                break
                ;;
            *)
                echo -e "${RED}请输入正确的选项 [1-2]${RESET}"
                ;;
        esac
    done
}

# 获取出口控制相关参数
get_egress_settings() {
    if [ "$EGRESS_FEATURE_ENABLED" != "true" ]; then
        return
    fi

    auto_detect_egress_iface
    read -rp "请输入出口接口名称（默认 ${EGRESS_IFACE}）: " custom_iface
    if [ -n "$custom_iface" ]; then
        EGRESS_IFACE="$custom_iface"
    fi

    read -rp "请输入 netns 名称（默认 snell-egress）: " custom_ns
    if [ -n "$custom_ns" ]; then
        EGRESS_NS="$custom_ns"
    fi

    # 自动探测默认子网，并允许用户手工覆盖
    auto_pick_egress_subnet
    read -rp "请输入 veth 子网（CIDR，默认 ${EGRESS_SUBNET}）: " custom_subnet
    if [ -n "$custom_subnet" ]; then
        if [[ "$custom_subnet" =~ ^([0-9]{1,3}\.){3}0/30$ ]]; then
            apply_egress_subnet "$custom_subnet"
        else
            echo -e "${YELLOW}子网格式无效，继续使用自动选择：${EGRESS_SUBNET}${RESET}"
        fi
    fi

    echo -e "${GREEN}出口接口: ${EGRESS_IFACE}${RESET}"
    echo -e "${GREEN}命名空间: ${EGRESS_NS}${RESET}"
    echo -e "${GREEN}veth 子网: ${EGRESS_SUBNET}${RESET}"
    echo -e "${YELLOW}说明：${EGRESS_HOST_IP}（主命名空间） <-> ${EGRESS_NS_IP}（${EGRESS_NS}）${RESET}"
}

# 检查出口控制依赖
check_egress_dependencies() {
    if [ "$EGRESS_FEATURE_ENABLED" != "true" ]; then
        return
    fi

    if ! command -v ip &> /dev/null; then
        echo -e "${YELLOW}未检测到 iproute2，正在安装...${RESET}"
        if [ -x "$(command -v apt)" ]; then
            wait_for_apt
            apt update && apt install -y iproute2
        elif [ -x "$(command -v yum)" ]; then
            yum install -y iproute
        else
            echo -e "${RED}未支持的包管理器，无法安装 iproute2。${RESET}"
            exit 1
        fi
    fi

    if ! command -v nft &> /dev/null; then
        echo -e "${YELLOW}未检测到 nftables，正在安装...${RESET}"
        if [ -x "$(command -v apt)" ]; then
            wait_for_apt
            apt update && apt install -y nftables
        elif [ -x "$(command -v yum)" ]; then
            yum install -y nftables
        else
            echo -e "${RED}未支持的包管理器，无法安装 nftables。${RESET}"
            exit 1
        fi
    fi
}

# 写入 netns 初始化单元
write_snell_netns_service() {
    cat > ${NETNS_SETUP_SCRIPT} << EOF
#!/bin/bash
set -eux

ip netns add ${EGRESS_NS} 2>/dev/null || true
ip link show veth-host >/dev/null 2>&1 || ip link add veth-host type veth peer name veth-snell
ip link set veth-snell netns ${EGRESS_NS} 2>/dev/null || true

ip addr replace ${EGRESS_HOST_IP} dev veth-host
ip link set veth-host up

ip netns exec ${EGRESS_NS} ip addr replace ${EGRESS_NS_IP} dev veth-snell
ip netns exec ${EGRESS_NS} ip link set lo up
ip netns exec ${EGRESS_NS} ip link set veth-snell up
ip netns exec ${EGRESS_NS} ip route replace default via ${EGRESS_GW}

mkdir -p /etc/netns/${EGRESS_NS}
cp -f /etc/resolv.conf /etc/netns/${EGRESS_NS}/resolv.conf
if grep -Eq '^nameserver[[:space:]]+127\\.0\\.0\\.53$' /etc/netns/${EGRESS_NS}/resolv.conf; then
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/netns/${EGRESS_NS}/resolv.conf
fi

sysctl -w net.ipv4.ip_forward=1

nft delete table ip snell_nat 2>/dev/null || true
nft add table ip snell_nat
nft add chain ip snell_nat postrouting '{ type nat hook postrouting priority 100; policy accept; }'
nft add rule ip snell_nat postrouting oifname "${EGRESS_IFACE}" ip saddr ${EGRESS_SUBNET} masquerade

nft add table inet snell_filter 2>/dev/null || true
nft list chain inet snell_filter forward >/dev/null 2>&1 || nft add chain inet snell_filter forward '{ type filter hook forward priority -5; policy accept; }'
nft add rule inet snell_filter forward iifname 'veth-host' oifname "${EGRESS_IFACE}" ip saddr ${EGRESS_SUBNET} accept 2>/dev/null || true
nft add rule inet snell_filter forward iifname "${EGRESS_IFACE}" oifname 'veth-host' ct state established,related accept 2>/dev/null || true

if command -v iptables >/dev/null 2>&1; then
    iptables -C FORWARD -i veth-host -o ${EGRESS_IFACE} -s ${EGRESS_SUBNET} -j ACCEPT 2>/dev/null || iptables -I FORWARD -i veth-host -o ${EGRESS_IFACE} -s ${EGRESS_SUBNET} -j ACCEPT
    iptables -C FORWARD -i ${EGRESS_IFACE} -o veth-host -d ${EGRESS_SUBNET} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -I FORWARD -i ${EGRESS_IFACE} -o veth-host -d ${EGRESS_SUBNET} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
fi
EOF
    chmod +x ${NETNS_SETUP_SCRIPT}

    cat > ${SYSTEMD_NETNS_FILE} << EOF
[Unit]
Description=Prepare netns and NAT for Snell egress
DefaultDependencies=no
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${NETNS_SETUP_SCRIPT}
ExecStop=/bin/true

[Install]
WantedBy=multi-user.target
EOF
}

# 写入 socket activation 单元
write_snell_socket_service_units() {
    local listen_port=$1
    local snell_binary
    snell_binary=$(main_snell_binary)

    cat > ${SYSTEMD_SOCKET_FILE} << EOF
[Unit]
Description=Snell v5 (socket-activated)

[Socket]
ListenStream=0.0.0.0:${listen_port}
ListenDatagram=0.0.0.0:${listen_port}
FileDescriptorName=snell_inet
ReusePort=no
NoDelay=true

[Install]
WantedBy=sockets.target
EOF

    cat > ${SYSTEMD_SERVICE_FILE} << EOF
[Unit]
Description=Snell Proxy Service (Main, netns)
Requires=snell-netns.service
After=snell-netns.service

[Service]
Type=simple
NetworkNamespacePath=/run/netns/${EGRESS_NS}
BindReadOnlyPaths=/etc/netns/${EGRESS_NS}/resolv.conf:/etc/resolv.conf
User=${SNELL_SERVICE_USER}
Group=${SNELL_SERVICE_GROUP}
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
ProtectKernelModules=yes
LimitNOFILE=32768
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
WorkingDirectory=${INSTALL_DIR}
ExecStart=${snell_binary} -c ${SNELL_CONF_FILE}
Restart=on-failure
RestartSec=2s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=snell-server

[Install]
WantedBy=multi-user.target
EOF
}

# 检查端口是否被占用（TCP/UDP）
is_port_in_use() {
    local port="$1"
    if command -v ss &> /dev/null; then
        ss -H -ltn "( sport = :${port} )" 2>/dev/null | grep -q . && return 0
        ss -H -lun "( sport = :${port} )" 2>/dev/null | grep -q . && return 0
        return 1
    fi

    if command -v lsof &> /dev/null; then
        lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1 && return 0
        lsof -nP -iUDP:"${port}" >/dev/null 2>&1
        return $?
    fi

    return 1
}

# 显示占用指定端口的进程信息
show_port_occupier() {
    local port="$1"
    if command -v ss &> /dev/null; then
        ss -ltnp "( sport = :${port} )" 2>/dev/null | sed 's/^/  /'
        ss -lunp "( sport = :${port} )" 2>/dev/null | sed 's/^/  /'
        return
    fi

    if command -v lsof &> /dev/null; then
        lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | sed 's/^/  /'
        lsof -nP -iUDP:"${port}" 2>/dev/null | sed 's/^/  /'
    fi
}

# 按端口强制清理监听进程（优先清理 snell 相关，最后兜底清理全部监听者）
force_release_port_by_pid() {
    local port="$1"
    local pids pid cmd

    if command -v ss &> /dev/null; then
        pids=$( {
            ss -H -ltnp "( sport = :${port} )" 2>/dev/null
            ss -H -lunp "( sport = :${port} )" 2>/dev/null
        } | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | sort -u)
    elif command -v lsof &> /dev/null; then
        pids=$( {
            lsof -t -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null
            lsof -t -nP -iUDP:"${port}" 2>/dev/null
        } | sort -u)
    fi

    [ -z "$pids" ] && return 0

    for pid in $pids; do
        cmd=$(ps -p "$pid" -o args= 2>/dev/null)
        if echo "$cmd" | grep -q "snell"; then
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done

    sleep 0.2

    if is_port_in_use "$port"; then
        for pid in $pids; do
            kill -KILL "$pid" 2>/dev/null || true
        done
    fi
}

# 切换到 socket activation 前，确保主端口已释放
ensure_main_port_free_for_socket() {
    local port="$1"
    local i

    systemctl stop snell.socket 2>/dev/null
    systemctl stop snell 2>/dev/null
    systemctl disable snell 2>/dev/null
    systemctl reset-failed snell.socket 2>/dev/null

    # 兜底：避免残留 snell-server 进程继续占用端口
    systemctl kill snell --signal=SIGKILL 2>/dev/null
    pkill -f "${INSTALL_DIR}/snell-server -c ${SNELL_CONF_FILE}" 2>/dev/null || true
    force_release_port_by_pid "$port"

    for i in {1..20}; do
        if ! is_port_in_use "$port"; then
            return 0
        fi
        sleep 0.2
    done

    echo -e "${RED}端口 ${port} 仍被占用，无法启动 snell.socket。${RESET}"
    echo -e "${YELLOW}占用详情：${RESET}"
    show_port_occupier "$port"
    return 1
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

close_nftables_port() {
    local PORT=$1

    if ! command -v nft &> /dev/null; then
        return
    fi

    nft -a list ruleset 2>/dev/null | awk -v port="$PORT" '
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
    local PORT=$1

    if command -v ufw &> /dev/null; then
        ufw delete allow "$PORT"/tcp >/dev/null 2>&1 || true
        ufw delete allow "$PORT"/udp >/dev/null 2>&1 || true
    fi

    if command -v iptables &> /dev/null; then
        iptables -D INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || true
        if [ -d "/etc/iptables" ]; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
    fi

    close_nftables_port "$PORT"
}

# 启用 egress 运行时：优先 socket + service；失败回退为 netns 直启服务
start_egress_runtime() {
    local port="$1"

    if ! ensure_main_port_free_for_socket "$port"; then
        return 1
    fi

    if ! systemctl enable snell.socket; then
        echo -e "${RED}启用 snell.socket 失败。${RESET}"
        return 1
    fi
    if ! systemctl start snell.socket; then
        echo -e "${RED}启动 snell.socket 失败。${RESET}"
        return 1
    fi

    # 关键：主动拉起 snell，确保 UDP/QUIC 可用，不依赖首次 TCP 触发
    if systemctl start snell; then
        echo -e "${GREEN}已启用 socket + service 运行模式。${RESET}"
        return 0
    fi

    echo -e "${YELLOW}socket 模式下主动拉起 snell 失败，自动回退到 netns 直启服务模式。${RESET}"
    systemctl stop snell.socket 2>/dev/null
    systemctl disable snell.socket 2>/dev/null

    if ! systemctl enable snell; then
        echo -e "${RED}回退模式：启用 snell 失败。${RESET}"
        return 1
    fi
    if ! systemctl restart snell; then
        echo -e "${RED}回退模式：启动 snell 失败。${RESET}"
        return 1
    fi

    echo -e "${GREEN}已回退为 netns 直启服务模式（无 socket 激活）。${RESET}"
    return 0
}

# 安装 Snell
install_snell() {
    echo -e "${CYAN}正在安装 Snell${RESET}"

    # 选择 Snell 版本
    select_snell_version

    wait_for_apt
    apt update && apt install -y wget unzip

    # 若机器上还是旧的单版本布局，先迁成版本化布局，避免装新通道时覆盖掉在用的二进制
    migrate_snell_binary_layout

    # 安装（或强制重装）所选通道的二进制，其他通道原样保留
    if ! install_snell_binary_for_version "$SNELL_VERSION_CHOICE" "true"; then
        echo -e "${RED}安装 Snell ${SNELL_VERSION_CHOICE} 失败。${RESET}"
        exit 1
    fi

    # 主用户所用通道决定 snell-server 软链指向
    update_snell_symlink "$SNELL_VERSION_CHOICE"

    get_user_port  # 获取用户输入的端口
    get_dns # 获取用户输入的 DNS 服务器
    get_ipv6_choice # 是否启用 IPv6
    # v6 需要额外选择 mode 与 dns-ip-preference
    if [ "$SNELL_VERSION_CHOICE" = "v6" ]; then
        configure_snell_v6_options
    fi
    get_egress_feature_choice
    get_egress_settings
    check_egress_dependencies
    PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)

    # 创建用户配置目录
    mkdir -p ${SNELL_CONF_DIR}/users

    # 将主用户配置存储在 users 目录下
    write_snell_conf "${SNELL_CONF_FILE}" "${LISTEN_ADDR}" "${PORT}" "${PSK}" "${IPV6_ENABLE}" "${DNS}" "${SNELL_VERSION_CHOICE}"

    write_main_systemd_service

    if [ "$EGRESS_FEATURE_ENABLED" = "true" ]; then
        write_snell_netns_service
        write_snell_socket_service_units "$PORT"
    fi

    systemctl daemon-reload
    if [ $? -ne 0 ]; then
        echo -e "${RED}重载 Systemd 配置失败。${RESET}"
        exit 1
    fi

    if [ "$EGRESS_FEATURE_ENABLED" = "true" ]; then
        systemctl enable snell-netns
        if [ $? -ne 0 ]; then
            echo -e "${RED}启用 snell-netns 失败。${RESET}"
            exit 1
        fi

        systemctl start snell-netns
        if [ $? -ne 0 ]; then
            echo -e "${RED}启动 snell-netns 失败。${RESET}"
            exit 1
        fi

        if ! start_egress_runtime "$PORT"; then
            exit 1
        fi

        echo -e "${GREEN}snell.socket 已启动，snell 服务将按需拉起（首次连接触发）${RESET}"
        if [ "$SNELL_VERSION_CHOICE" = "v6" ]; then
            echo -e "${YELLOW}v6 已移除 QUIC 代理模式，客户端 version = 6 且 mode 需与服务端一致。${RESET}"
        else
            echo -e "${YELLOW}建议客户端优先使用 version = 4（v5 的 QUIC/UDP 依赖更高）。${RESET}"
        fi
    else
        systemctl stop snell.socket 2>/dev/null
        systemctl disable snell.socket 2>/dev/null
        systemctl stop snell-netns 2>/dev/null
        systemctl disable snell-netns 2>/dev/null

        systemctl enable snell
        if [ $? -ne 0 ]; then
            echo -e "${RED}开机自启动 Snell 失败。${RESET}"
            exit 1
        fi

        if ! validate_snell_main_config; then
            exit 1
        fi

        systemctl start snell
        if [ $? -ne 0 ]; then
            echo -e "${RED}启动 Snell 服务失败。${RESET}"
            exit 1
        fi
    fi

    # 开放端口
    open_port "$PORT"

    # 在安装完成后输出配置信息
    echo -e "\n${GREEN}安装完成！以下是您的配置信息：${RESET}"
    echo -e "${CYAN}--------------------------------${RESET}"
    if [ "$EGRESS_FEATURE_ENABLED" = "true" ]; then
        echo -e "${YELLOW}出口控制: 已启用（接口 ${EGRESS_IFACE}，命名空间 ${EGRESS_NS}）${RESET}"
        echo -e "${YELLOW}Socket 激活: snell.socket${RESET}"
    fi
    echo -e "${YELLOW}监听端口: ${PORT}${RESET}"
    echo -e "${YELLOW}PSK 密钥: ${PSK}${RESET}"
    echo -e "${YELLOW}IPv6: true${RESET}"
    echo -e "${YELLOW}DNS 服务器: ${DNS}${RESET}"
    echo -e "${CYAN}--------------------------------${RESET}"

    # 获取并显示服务器IP地址
    echo -e "\n${GREEN}服务器地址信息：${RESET}"
    
    # 获取 IPv4 地址
    IPV4_ADDR=$(curl -s4 --connect-timeout 5 --max-time 10 https://api.ipify.org)
    if [ $? -eq 0 ] && [ ! -z "$IPV4_ADDR" ]; then
        IP_COUNTRY_IPV4=$(get_ip_country "${IPV4_ADDR}")
        echo -e "${GREEN}IPv4 地址: ${RESET}${IPV4_ADDR} ${GREEN}所在国家: ${RESET}${IP_COUNTRY_IPV4}"
    fi

    # 获取 IPv6 地址
    IPV6_ADDR=$(curl -s6 --connect-timeout 5 --max-time 10 https://api64.ipify.org)
    if [ $? -eq 0 ] && [ ! -z "$IPV6_ADDR" ]; then
        IP_COUNTRY_IPV6=$(get_ip_country "${IPV6_ADDR}")
        echo -e "${GREEN}IPv6 地址: ${RESET}${IPV6_ADDR} ${GREEN}所在国家: ${RESET}${IP_COUNTRY_IPV6}"
    fi

    # 输出 Surge 配置格式
    echo -e "\n${GREEN}Surge 配置格式：${RESET}"
    local installed_version="$SNELL_VERSION_CHOICE"
    if [ ! -z "$IPV4_ADDR" ]; then
        generate_surge_config "$IPV4_ADDR" "$PORT" "$PSK" "$SNELL_VERSION_CHOICE" "$IP_COUNTRY_IPV4" "$installed_version"
    fi
    
    if [ ! -z "$IPV6_ADDR" ]; then
        generate_surge_config "$IPV6_ADDR" "$PORT" "$PSK" "$SNELL_VERSION_CHOICE" "$IP_COUNTRY_IPV6" "$installed_version"
    fi


    # 创建管理脚本
    echo -e "${CYAN}正在安装管理脚本...${RESET}"
    
    # 确保目标目录存在
    mkdir -p /usr/local/bin
    
    # 创建管理脚本
    cat > /usr/local/bin/snell << 'EOFSCRIPT'
#!/bin/bash

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 检查是否以 root 权限运行
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}请以 root 权限运行此脚本${RESET}"
    exit 1
fi

# 下载并执行最新版本的脚本
echo -e "${CYAN}正在获取最新版本的管理脚本...${RESET}"
TMP_SCRIPT=$(mktemp)
if curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/main/snell.sh -o "$TMP_SCRIPT"; then
    bash "$TMP_SCRIPT"
    rm -f "$TMP_SCRIPT"
else
    echo -e "${RED}下载脚本失败，请检查网络连接。${RESET}"
    rm -f "$TMP_SCRIPT"
    exit 1
fi
EOFSCRIPT
    
    if [ $? -eq 0 ]; then
        chmod +x /usr/local/bin/snell
        if [ $? -eq 0 ]; then
            echo -e "\n${GREEN}管理脚本安装成功！${RESET}"
            echo -e "${YELLOW}您可以在终端输入 'snell' 进入管理菜单。${RESET}"
            echo -e "${YELLOW}注意：需要使用 sudo snell 或以 root 身份运行。${RESET}\n"
        else
            echo -e "\n${RED}设置脚本执行权限失败。${RESET}"
            echo -e "${YELLOW}您可以通过直接运行原脚本来管理 Snell。${RESET}\n"
        fi
    else
        echo -e "\n${RED}创建管理脚本失败。${RESET}"
        echo -e "${YELLOW}您可以通过直接运行原脚本来管理 Snell。${RESET}\n"
    fi
}

# 已安装 Snell v5/v6 的出口控制管理
configure_v5_egress_control() {
    echo -e "${CYAN}=============== v5/v6 出口控制设置 ===============${RESET}"

    if ! command -v snell-server &> /dev/null; then
        echo -e "${RED}未检测到 Snell，请先安装。${RESET}"
        return 1
    fi

    # 出口控制作用于主服务，因此按主配置的通道判断
    local installed_version
    installed_version=$(get_conf_snell_version "$SNELL_CONF_FILE")
    if [ "$installed_version" != "v5" ] && [ "$installed_version" != "v6" ]; then
        echo -e "${YELLOW}主用户当前使用 ${installed_version}，仅 Snell v5/v6 支持此设置。${RESET}"
        return 1
    fi

    local main_port
    main_port=$(get_snell_port)
    if [ -z "$main_port" ]; then
        echo -e "${RED}未找到主配置端口，请检查 ${SNELL_CONF_FILE}${RESET}"
        return 1
    fi

    local egress_enabled="false"
    if systemctl is-enabled snell.socket &> /dev/null || systemctl is-active snell.socket &> /dev/null; then
        egress_enabled="true"
    fi

    echo -e "${GREEN}主用户版本: Snell ${installed_version}${RESET}"
    echo -e "${GREEN}主端口: ${main_port}${RESET}"
    if [ "$egress_enabled" = "true" ]; then
        echo -e "${YELLOW}当前出口控制状态: 已启用${RESET}"
    else
        echo -e "${YELLOW}当前出口控制状态: 未启用${RESET}"
    fi

    echo -e "${GREEN}1.${RESET} 启用/更新 出口控制"
    echo -e "${GREEN}2.${RESET} 关闭 出口控制（恢复传统模式）"
    echo -e "${GREEN}0.${RESET} 返回"
    read -rp "请输入选项 [0-2]: " egress_manage_choice

    case "$egress_manage_choice" in
        1)
            EGRESS_FEATURE_ENABLED="true"
            get_egress_settings
            check_egress_dependencies

            write_snell_netns_service
            write_snell_socket_service_units "$main_port"

            systemctl daemon-reload
            if ! systemctl enable snell-netns; then
                echo -e "${RED}启用 snell-netns 失败。${RESET}"
                return 1
            fi
            if ! systemctl start snell-netns; then
                echo -e "${RED}启动 snell-netns 失败，请执行: systemctl status snell-netns.service${RESET}"
                return 1
            fi

            if ! start_egress_runtime "$main_port"; then
                return 1
            fi

            echo -e "${GREEN}已应用出口控制（接口 ${EGRESS_IFACE}，命名空间 ${EGRESS_NS}）。${RESET}"
            if [ "$SNELL_VERSION_CHOICE" = "v6" ]; then
            echo -e "${YELLOW}v6 已移除 QUIC 代理模式，客户端 version = 6 且 mode 需与服务端一致。${RESET}"
        else
            echo -e "${YELLOW}建议客户端优先使用 version = 4（v5 的 QUIC/UDP 依赖更高）。${RESET}"
        fi
            echo -e "${YELLOW}说明：snell.socket 已监听，snell.service 将在首次连接时自动启动。${RESET}"
            ;;
        2)
            systemctl stop snell.socket 2>/dev/null
            systemctl disable snell.socket 2>/dev/null
            systemctl stop snell-netns 2>/dev/null
            systemctl disable snell-netns 2>/dev/null

            write_main_systemd_service

            rm -f ${SYSTEMD_SOCKET_FILE}
            rm -f ${SYSTEMD_NETNS_FILE}

            systemctl daemon-reload
            systemctl enable snell
            if ! validate_snell_main_config; then
                return 1
            fi
            systemctl restart snell

            echo -e "${GREEN}已关闭出口控制，恢复传统模式。${RESET}"
            ;;
        0)
            echo -e "${CYAN}已返回。${RESET}"
            ;;
        *)
            echo -e "${RED}请输入正确的选项 [0-2]${RESET}"
            ;;
    esac
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
    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for user_conf in "${SNELL_CONF_DIR}/users"/*; do
            if [ -f "$user_conf" ]; then
                local port=$(grep -E '^listen' "$user_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
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
    rm -f /lib/systemd/system/snell.service
    rm -f ${SYSTEMD_SERVICE_FILE}
    rm -f ${SYSTEMD_SOCKET_FILE}
    rm -f ${SYSTEMD_NETNS_FILE}
    rm -f ${NETNS_SETUP_SCRIPT}

    # 删除各通道二进制、软链与更新时留下的备份
    local version
    for version in $SNELL_ALL_VERSIONS; do
        rm -f "$(snell_binary_for_version "$version")"
    done
    rm -f "${INSTALL_DIR}"/snell-server-v[456].bak.*
    rm -f ${INSTALL_DIR}/snell-server
    rm -rf ${SNELL_CONF_DIR}
    rm -f /usr/local/bin/snell  # 删除管理脚本

    if ! find "${SYSTEMD_DIR}" -maxdepth 1 -name "shadowtls-*.service" 2>/dev/null | grep -q .; then
        rm -f /usr/local/bin/shadow-tls
    fi
    
    # 重载 systemd 配置
    systemctl daemon-reload
    
    echo -e "${GREEN}Snell 及其所有多用户配置已成功卸载${RESET}"
}

# 重启 Snell
restart_snell() {
    echo -e "${YELLOW}正在重启所有 Snell 服务...${RESET}"

    if ! validate_snell_main_config; then
        echo -e "${RED}已取消重启，避免 snell-server 在缺少配置时崩溃。${RESET}"
        return 1
    fi
    
    # 若使用 socket activation，先重启 socket 与 netns，再重启服务
    if systemctl list-unit-files | grep -q '^snell.socket'; then
        systemctl restart snell-netns 2>/dev/null
        systemctl restart snell.socket 2>/dev/null
    fi

    # 重启主服务
    systemctl restart snell
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}主 Snell 服务已成功重启。${RESET}"
    else
        echo -e "${RED}重启主 Snell 服务失败。${RESET}"
    fi

    # 重启所有多用户服务
    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for user_conf in "${SNELL_CONF_DIR}/users"/*; do
            if [ -f "$user_conf" ] && [[ "$user_conf" != *"snell-main.conf" ]]; then
                local port=$(grep -E '^listen' "$user_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
                if [ ! -z "$port" ]; then
                    echo -e "${YELLOW}正在重启用户服务 (端口: $port)${RESET}"
                    systemctl restart "snell-${port}" 2>/dev/null
                    if [ $? -eq 0 ]; then
                        echo -e "${GREEN}用户服务 (端口: $port) 已成功重启。${RESET}"
                    else
                        echo -e "${RED}重启用户服务 (端口: $port) 失败。${RESET}"
                    fi
                fi
            fi
        done
    fi
}
# 检查服务状态并显示
check_and_show_status() {
    echo -e "\n${CYAN}=============== 服务状态检查 ===============${RESET}"
    
    # 检查 Snell 状态
    if command -v snell-server &> /dev/null; then
        # 初始化计数器和资源使用变量
        local user_count=0
        local running_count=0
        local total_snell_memory=0
        local total_snell_cpu=0
        
        # 检查主服务状态
        local main_available=false
        if systemctl is-active snell &> /dev/null; then
            main_available=true
        elif systemctl is-active snell.socket &> /dev/null; then
            # socket activation 场景下，服务可能按需拉起
            main_available=true
        fi

        if [ "$main_available" = "true" ]; then
            user_count=$((user_count + 1))
            running_count=$((running_count + 1))
            
            # 获取主服务资源使用情况
            local main_pid=$(systemctl show -p MainPID snell | cut -d'=' -f2)
            if [ ! -z "$main_pid" ] && [ "$main_pid" != "0" ]; then
                local mem=$(ps -o rss= -p $main_pid 2>/dev/null)
                local cpu=$(ps -o %cpu= -p $main_pid 2>/dev/null)
                if [ ! -z "$mem" ]; then
                    total_snell_memory=$((total_snell_memory + mem))
                fi
                if [ ! -z "$cpu" ]; then
                    total_snell_cpu=$(echo "$total_snell_cpu + $cpu" | bc -l)
                fi
            fi
        else
            user_count=$((user_count + 1))
        fi
        
        # 检查多用户状态
        if [ -d "${SNELL_CONF_DIR}/users" ]; then
            for user_conf in "${SNELL_CONF_DIR}/users"/*; do
                if [ -f "$user_conf" ] && [[ "$user_conf" != *"snell-main.conf" ]]; then
                    local port=$(grep -E '^listen' "$user_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
                    if [ ! -z "$port" ]; then
                        user_count=$((user_count + 1))
                        if systemctl is-active --quiet "snell-${port}"; then
                            running_count=$((running_count + 1))
                            
                            # 获取用户服务资源使用情况
                            local user_pid=$(systemctl show -p MainPID "snell-${port}" | cut -d'=' -f2)
                            if [ ! -z "$user_pid" ] && [ "$user_pid" != "0" ]; then
                                local mem=$(ps -o rss= -p $user_pid 2>/dev/null)
                                local cpu=$(ps -o %cpu= -p $user_pid 2>/dev/null)
                                if [ ! -z "$mem" ]; then
                                    total_snell_memory=$((total_snell_memory + mem))
                                fi
                                if [ ! -z "$cpu" ]; then
                                    total_snell_cpu=$(echo "$total_snell_cpu + $cpu" | bc -l)
                                fi
                            fi
                        fi
                    fi
                fi
            done
        fi
        
        # 显示 Snell 状态
        local total_snell_memory_mb=$(echo "scale=2; $total_snell_memory/1024" | bc)
        printf "${GREEN}Snell 已安装${RESET}  ${YELLOW}CPU：%.2f%%${RESET}  ${YELLOW}内存：%.2f MB${RESET}  ${GREEN}运行中：${running_count}/${user_count}${RESET}\n" "$total_snell_cpu" "$total_snell_memory_mb"

        # 已安装的通道，以及各自被多少个服务使用
        local installed_channels channel channel_summary=""
        installed_channels=$(list_installed_snell_versions)
        if [ -n "$installed_channels" ]; then
            for channel in $installed_channels; do
                channel_summary="${channel_summary}${channel}(×$(list_services_using_version "$channel" | grep -c .)) "
            done
            echo -e "${GREEN}已安装通道${RESET}  ${YELLOW}${channel_summary}${RESET}"
        fi
    else
        echo -e "${YELLOW}Snell 未安装${RESET}"
    fi
    
    # 检查 ShadowTLS 状态
    if [ -f "/usr/local/bin/shadow-tls" ]; then
        # 初始化 ShadowTLS 服务计数器和资源使用
        local stls_total=0
        local stls_running=0
        local total_stls_memory=0
        local total_stls_cpu=0
        declare -A processed_ports
        
        # 检查 Snell 的 ShadowTLS 服务
        local snell_services=$(find /etc/systemd/system -name "shadowtls-snell-*.service" 2>/dev/null | sort -u)
        if [ ! -z "$snell_services" ]; then
            while IFS= read -r service_file; do
                local port=$(basename "$service_file" | sed 's/shadowtls-snell-\([0-9]*\)\.service/\1/')
                
                # 检查是否已处理过该端口
                if [ -z "${processed_ports[$port]}" ]; then
                    processed_ports[$port]=1
                    stls_total=$((stls_total + 1))
                    if systemctl is-active "shadowtls-snell-${port}" &> /dev/null; then
                        stls_running=$((stls_running + 1))
                        
                        # 获取 ShadowTLS 服务资源使用情况
                        local stls_pid=$(systemctl show -p MainPID "shadowtls-snell-${port}" | cut -d'=' -f2)
                        if [ ! -z "$stls_pid" ] && [ "$stls_pid" != "0" ]; then
                            local mem=$(ps -o rss= -p $stls_pid 2>/dev/null)
                            local cpu=$(ps -o %cpu= -p $stls_pid 2>/dev/null)
                            if [ ! -z "$mem" ]; then
                                total_stls_memory=$((total_stls_memory + mem))
                            fi
                            if [ ! -z "$cpu" ]; then
                                total_stls_cpu=$(echo "$total_stls_cpu + $cpu" | bc -l)
                            fi
                        fi
                    fi
                fi
            done <<< "$snell_services"
        fi
        
        # 显示 ShadowTLS 状态
        if [ $stls_total -gt 0 ]; then
            local total_stls_memory_mb=$(echo "scale=2; $total_stls_memory/1024" | bc)
            printf "${GREEN}ShadowTLS 已安装${RESET}  ${YELLOW}CPU：%.2f%%${RESET}  ${YELLOW}内存：%.2f MB${RESET}  ${GREEN}运行中：${stls_running}/${stls_total}${RESET}\n" "$total_stls_cpu" "$total_stls_memory_mb"
        else
            echo -e "${YELLOW}ShadowTLS 未安装${RESET}"
        fi
    else
        echo -e "${YELLOW}ShadowTLS 未安装${RESET}"
    fi
    
    echo -e "${CYAN}============================================${RESET}\n"
}

# 查看配置
view_snell_config() {
    echo -e "${GREEN}Snell 配置信息:${RESET}"
    echo -e "${CYAN}================================${RESET}"
    
    # 每个用户可以用不同通道，这里只列出机器上装了哪些
    local installed_channels
    installed_channels=$(list_installed_snell_versions)
    if [ -n "$installed_channels" ]; then
        echo -e "${YELLOW}已安装通道: ${installed_channels}${RESET}"
    else
        echo -e "${YELLOW}未检测到已安装的 Snell 通道${RESET}"
    fi
    
    # 获取 IPv4 地址
    IPV4_ADDR=$(curl -s4 --connect-timeout 5 --max-time 10 https://api.ipify.org)
    if [ $? -eq 0 ] && [ ! -z "$IPV4_ADDR" ]; then
        IP_COUNTRY_IPV4=$(get_ip_country "${IPV4_ADDR}")
        echo -e "${GREEN}IPv4 地址: ${RESET}${IPV4_ADDR} ${GREEN}所在国家: ${RESET}${IP_COUNTRY_IPV4}"
    fi

    # 获取 IPv6 地址
    IPV6_ADDR=$(curl -s6 --connect-timeout 5 --max-time 10 https://api64.ipify.org)
    if [ $? -eq 0 ] && [ ! -z "$IPV6_ADDR" ]; then
        IP_COUNTRY_IPV6=$(get_ip_country "${IPV6_ADDR}")
        echo -e "${GREEN}IPv6 地址: ${RESET}${IPV6_ADDR} ${GREEN}所在国家: ${RESET}${IP_COUNTRY_IPV6}"
    fi

    # 检查是否获取到 IP 地址
    if [ -z "$IPV4_ADDR" ] && [ -z "$IPV6_ADDR" ]; then
        echo -e "${RED}无法获取到公网 IP 地址，请检查网络连接。${RESET}"
        return
    fi
    
    echo -e "\n${YELLOW}=== 用户配置列表 ===${RESET}"
    
    # 显示主用户配置
    local main_conf="${SNELL_CONF_DIR}/users/snell-main.conf"
    if [ -f "$main_conf" ]; then
        echo -e "\n${GREEN}主用户配置：${RESET}"
        local main_port=$(grep -E '^listen' "$main_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
        local main_psk=$(grep -E '^psk' "$main_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local main_ipv6=$(grep -E '^[[:space:]]*ipv6[[:space:]]*=' "$main_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local main_dns=$(grep -E '^[[:space:]]*dns[[:space:]]*=' "$main_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local main_mode=$(grep -E '^[[:space:]]*mode[[:space:]]*=' "$main_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local main_dns_pref=$(grep -E '^[[:space:]]*dns-ip-preference[[:space:]]*=' "$main_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local main_version=$(get_conf_snell_version "$main_conf")

        echo -e "${YELLOW}端口: ${main_port}${RESET}"
        echo -e "${YELLOW}版本: Snell ${main_version}${RESET}"
        echo -e "${YELLOW}PSK: ${main_psk}${RESET}"
        [ -n "$main_ipv6" ] && echo -e "${YELLOW}IPv6: ${main_ipv6}${RESET}"
        [ -n "$main_mode" ] && echo -e "${YELLOW}模式 (mode): ${main_mode}${RESET}"
        [ -n "$main_dns_pref" ] && echo -e "${YELLOW}DNS 解析偏好: ${main_dns_pref}${RESET}"
        echo -e "${YELLOW}DNS: ${main_dns}${RESET}"
        
        echo -e "\n${GREEN}Surge 配置格式：${RESET}"
        if [ ! -z "$IPV4_ADDR" ]; then
            generate_surge_config "$IPV4_ADDR" "$main_port" "$main_psk" "$main_version" "$IP_COUNTRY_IPV4" "$main_version"
        fi
        if [ ! -z "$IPV6_ADDR" ]; then
            generate_surge_config "$IPV6_ADDR" "$main_port" "$main_psk" "$main_version" "$IP_COUNTRY_IPV6" "$main_version"
        fi
    fi
    
    # 显示其他用户配置
    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for user_conf in "${SNELL_CONF_DIR}/users"/*; do
            if [ -f "$user_conf" ] && [[ "$user_conf" != *"snell-main.conf" ]]; then
                local user_port=$(grep -E '^listen' "$user_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
                local user_psk=$(grep -E '^psk' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
                local user_ipv6=$(grep -E '^[[:space:]]*ipv6[[:space:]]*=' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
                local user_dns=$(grep -E '^[[:space:]]*dns[[:space:]]*=' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
                local user_mode=$(grep -E '^[[:space:]]*mode[[:space:]]*=' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
                local user_dns_pref=$(grep -E '^[[:space:]]*dns-ip-preference[[:space:]]*=' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
                local user_version=$(get_conf_snell_version "$user_conf")

                echo -e "\n${GREEN}用户配置 (端口: ${user_port}):${RESET}"
                echo -e "${YELLOW}版本: Snell ${user_version}${RESET}"
                echo -e "${YELLOW}PSK: ${user_psk}${RESET}"
                [ -n "$user_ipv6" ] && echo -e "${YELLOW}IPv6: ${user_ipv6}${RESET}"
                [ -n "$user_mode" ] && echo -e "${YELLOW}模式 (mode): ${user_mode}${RESET}"
                [ -n "$user_dns_pref" ] && echo -e "${YELLOW}DNS 解析偏好: ${user_dns_pref}${RESET}"
                echo -e "${YELLOW}DNS: ${user_dns}${RESET}"
                
                echo -e "\n${GREEN}Surge 配置格式：${RESET}"
                if [ ! -z "$IPV4_ADDR" ]; then
                    generate_surge_config "$IPV4_ADDR" "$user_port" "$user_psk" "$user_version" "$IP_COUNTRY_IPV4" "$user_version"
                fi
                if [ ! -z "$IPV6_ADDR" ]; then
                    generate_surge_config "$IPV6_ADDR" "$user_port" "$user_psk" "$user_version" "$IP_COUNTRY_IPV6" "$user_version"
                fi
            fi
        done
    fi
    
    # 如果 ShadowTLS 已安装，显示组合配置（版本按后端端口各自的通道取）
    local snell_services=$(find /etc/systemd/system -name "shadowtls-snell-*.service" 2>/dev/null | sort -u)
    if [ ! -z "$snell_services" ]; then
        echo -e "\n${YELLOW}=== ShadowTLS 组合配置 ===${RESET}"
        declare -A processed_ports
        while IFS= read -r service_file; do
            local exec_line=$(grep "ExecStart=" "$service_file")
            local stls_port=$(echo "$exec_line" | grep -oP '(?<=--listen ::0:)\d+')
            local stls_password=$(echo "$exec_line" | grep -oP '(?<=--password )[^ ]+')
            local stls_domain=$(echo "$exec_line" | grep -oP '(?<=--tls )[^ ]+')
            local snell_port=$(echo "$exec_line" | grep -oP '(?<=--server 127.0.0.1:)\d+')
            # 查找 psk
            local psk=""
            if [ -f "${SNELL_CONF_DIR}/users/snell-${snell_port}.conf" ]; then
                psk=$(grep -E '^psk' "${SNELL_CONF_DIR}/users/snell-${snell_port}.conf" | awk -F'=' '{print $2}' | tr -d ' ')
            elif [ -f "${SNELL_CONF_DIR}/users/snell-main.conf" ] && [ "$snell_port" = "$(get_snell_port)" ]; then
                psk=$(grep -E '^psk' "${SNELL_CONF_DIR}/users/snell-main.conf" | awk -F'=' '{print $2}' | tr -d ' ')
            fi
            # 避免重复
            if [ -z "$snell_port" ] || [ -z "$psk" ] || [ -n "${processed_ports[$snell_port]}" ]; then
                continue
            fi
            processed_ports[$snell_port]=1
            local snell_version=$(get_port_snell_version "$snell_port")
            local snell_mode=$(get_snell_mode "$(snell_conf_for_port "$snell_port")")
            if [ "$snell_port" = "$(get_snell_port)" ]; then
                echo -e "\n${GREEN}主用户 ShadowTLS 配置：${RESET}"
            else
                echo -e "\n${GREEN}用户 ShadowTLS 配置 (端口: ${snell_port})：${RESET}"
            fi
            echo -e "  - Snell 端口：${snell_port}"
            echo -e "  - PSK：${psk}"
            echo -e "  - ShadowTLS 监听端口：${stls_port}"
            echo -e "  - ShadowTLS 密码：${stls_password}"
            echo -e "  - ShadowTLS SNI：${stls_domain}"
            echo -e "  - 版本：3"
            echo -e "  - Snell 版本：${snell_version}"
            echo -e "\n${GREEN}Surge 配置格式：${RESET}"
            if [ ! -z "$IPV4_ADDR" ]; then
                if [ "$snell_version" = "v6" ]; then
                    echo -e "${GREEN}${IP_COUNTRY_IPV4} = snell, ${IPV4_ADDR}, ${stls_port}, psk = ${psk}, version = 6, mode = ${snell_mode}, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                elif [ "$snell_version" = "v5" ]; then
                    echo -e "${GREEN}${IP_COUNTRY_IPV4} = snell, ${IPV4_ADDR}, ${stls_port}, psk = ${psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                    echo -e "${GREEN}${IP_COUNTRY_IPV4} = snell, ${IPV4_ADDR}, ${stls_port}, psk = ${psk}, version = 5, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                else
                    echo -e "${GREEN}${IP_COUNTRY_IPV4} = snell, ${IPV4_ADDR}, ${stls_port}, psk = ${psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                fi
            fi
            if [ ! -z "$IPV6_ADDR" ]; then
                if [ "$snell_version" = "v6" ]; then
                    echo -e "${GREEN}${IP_COUNTRY_IPV6} = snell, ${IPV6_ADDR}, ${stls_port}, psk = ${psk}, version = 6, mode = ${snell_mode}, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                elif [ "$snell_version" = "v5" ]; then
                    echo -e "${GREEN}${IP_COUNTRY_IPV6} = snell, ${IPV6_ADDR}, ${stls_port}, psk = ${psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                    echo -e "${GREEN}${IP_COUNTRY_IPV6} = snell, ${IPV6_ADDR}, ${stls_port}, psk = ${psk}, version = 5, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                else
                    echo -e "${GREEN}${IP_COUNTRY_IPV6} = snell, ${IPV6_ADDR}, ${stls_port}, psk = ${psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                fi
            fi
        done <<< "$snell_services"
    fi
    
    echo -e "\n${YELLOW}注意：${RESET}"
    echo -e "1. Snell 仅支持 Surge 客户端"
    echo -e "2. 请将配置中的服务器地址替换为实际可用的地址"
    read -p "按任意键返回主菜单..."
}

# =========================================
# Snell 版本管理：按通道更新 / 追加通道 / 切换用户通道
# =========================================
# 读取某通道二进制自报的具体版本号（如 v5.0.1）
get_channel_binary_version() {
    local version="$1"
    local binary
    binary=$(snell_binary_for_version "$version")
    [ -x "$binary" ] || return 1

    local detail
    detail=$("$binary" --v 2>&1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+[a-zA-Z0-9]*' | head -n 1)
    if [ -z "$detail" ]; then
        # 早期 v4 的 --v 不打印版本号，用内置常量兜底
        case "$version" in
            v4) detail="$SNELL_V4_FALLBACK" ;;
            v5) detail="$SNELL_V5_FALLBACK" ;;
            v6) detail="$SNELL_V6_FALLBACK" ;;
        esac
    fi
    echo "$detail"
}

# 重启服务并确认真的起来了；起不来打印日志尾部，不让用户自己翻
restart_and_verify_service() {
    local service="$1"
    local waited=0

    if ! systemctl restart "$service" 2>/dev/null; then
        echo -e "${RED}systemctl restart ${service} 返回失败${RESET}"
        journalctl -u "$service" -n 30 --no-pager 2>/dev/null | sed 's/^/   /'
        return 1
    fi

    while [ "$waited" -lt 10 ]; do
        if systemctl is-active --quiet "$service"; then
            return 0
        fi
        # socket 激活场景下主服务按需拉起，socket 活着即视为正常
        if [ "$service" = "snell" ] && systemctl is-active --quiet snell.socket; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    echo -e "${RED}${service} 在 ${waited} 秒内未进入 active 状态${RESET}"
    journalctl -u "$service" -n 30 --no-pager 2>/dev/null | sed 's/^/   /'
    return 1
}

# 更新单个通道的二进制到最新版本。
# 不改动任何用户的通道归属，配置格式因此不变，只重启用到该通道的服务。
update_snell_channel() {
    local version="$1"
    local target
    target=$(snell_binary_for_version "$version")

    echo -e "\n${CYAN}=============== 更新 Snell ${version} 通道 ===============${RESET}"
    echo -e "${GREEN}✓ 只替换 ${version} 的二进制，其他通道原样不动${RESET}"
    echo -e "${GREEN}✓ 端口、密码、用户配置都不会改变${RESET}"

    local services
    services=$(list_services_using_version "$version")
    if [ -n "$services" ]; then
        echo -e "${YELLOW}将重启：$(echo "$services" | tr '\n' ' ')${RESET}"
    else
        echo -e "${YELLOW}当前没有服务在使用 ${version} 通道，仅更新二进制${RESET}"
    fi

    # 配置与二进制各留一个回滚点
    local backup_dir
    backup_dir=$(backup_snell_config)
    echo -e "${GREEN}配置已备份到: ${backup_dir}${RESET}"

    local backup_binary=""
    if [ -f "$target" ]; then
        backup_binary="${target}.bak.$(date +%Y%m%d_%H%M%S)"
        if cp -a "$target" "$backup_binary"; then
            echo -e "${GREEN}原二进制已备份到: ${backup_binary}${RESET}"
        else
            echo -e "${YELLOW}警告：二进制备份失败，更新失败时将无法自动回滚${RESET}"
            backup_binary=""
        fi
    fi

    if ! install_snell_binary_for_version "$version" "true"; then
        if [ -n "$backup_binary" ]; then
            cp -a "$backup_binary" "$target" && echo -e "${YELLOW}已回滚到更新前的二进制${RESET}"
        fi
        return 1
    fi

    # 主用户用的就是这个通道时，软链跟着走
    if [ "$(get_conf_snell_version "$SNELL_CONF_FILE")" = "$version" ]; then
        update_snell_symlink "$version"
    fi

    local service failed=""
    while IFS= read -r service; do
        [ -n "$service" ] || continue
        if [ "$service" = "snell" ] && ! validate_snell_main_config; then
            failed="${failed}${service} "
            continue
        fi
        echo -e "${CYAN}正在重启 ${service}...${RESET}"
        if ! restart_and_verify_service "$service"; then
            failed="${failed}${service} "
        fi
    done <<< "$services"

    if [ -n "$failed" ]; then
        echo -e "\n${RED}以下服务未能正常启动: ${failed}${RESET}"
        if [ -n "$backup_binary" ]; then
            echo -e "${YELLOW}正在回滚 ${version} 通道的二进制...${RESET}"
            cp -a "$backup_binary" "$target"
            for service in $failed; do
                systemctl restart "$service" 2>/dev/null
            done
            echo -e "${YELLOW}已回滚。配置备份仍保留在 ${backup_dir}${RESET}"
        fi
        return 1
    fi

    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}✅ Snell ${version} 通道更新完成（$(get_channel_binary_version "$version")）${RESET}"
    echo -e "${GREEN}✓ 其他通道与全部配置未受影响${RESET}"
    echo -e "${YELLOW}配置备份目录: ${backup_dir}${RESET}"
    echo -e "${CYAN}============================================${RESET}"

    # 回滚点的使命到此结束，删掉避免 ${INSTALL_DIR} 里越积越多
    [ -n "$backup_binary" ] && rm -f "$backup_binary"
    return 0
}

# 切换/回滚用的备份统一放在 ${SNELL_CONF_DIR}/backup 下。
# 不能放进 users/ —— 多处循环是按 users/* 遍历的，备份文件会被当成真实用户。
snell_backup_path() {
    local src="$1"
    local stamp="$2"
    local dir="${SNELL_CONF_DIR}/backup"
    mkdir -p "$dir" 2>/dev/null || return 1
    echo "${dir}/$(basename "$src").${stamp}"
}

# 把一个配置切换到目标通道：备好二进制 -> 迁移配置参数 -> 改 unit -> 重启，失败自动回滚
switch_conf_to_version() {
    local conf_file="$1"
    local target_version="$2"
    local port service unit current_version

    if [ ! -f "$conf_file" ]; then
        echo -e "${RED}配置不存在: ${conf_file}${RESET}"
        return 1
    fi

    current_version=$(get_conf_snell_version "$conf_file")
    port=$(grep -E '^listen' "$conf_file" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
    if [ -z "$port" ]; then
        echo -e "${RED}无法从 ${conf_file} 解析监听端口${RESET}"
        return 1
    fi

    if [ "$current_version" = "$target_version" ]; then
        echo -e "${YELLOW}端口 ${port} 已经在 ${target_version} 通道，无需切换${RESET}"
        return 0
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

    # v6 的 mode / dns-ip-preference 按这个用户单独选
    if [ "$target_version" = "v6" ]; then
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
    point_service_unit_to_version "$unit" "$target_version"
    systemctl daemon-reload 2>/dev/null || true
    if [ "$service" = "snell" ]; then
        update_snell_symlink "$target_version"
    fi

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

# 逐个检查已安装通道是否有新版本
update_installed_channels() {
    local installed
    installed=$(list_installed_snell_versions)
    if [ -z "$installed" ]; then
        echo -e "${RED}未检测到已安装的通道${RESET}"
        return 1
    fi

    local version current latest updated=0
    for version in $installed; do
        current=$(get_channel_binary_version "$version")
        latest=$(resolve_latest_version_for_channel "$version")
        echo -e "\n${CYAN}--- ${version} 通道 ---${RESET}"
        echo -e "${YELLOW}当前: ${current:-未知}   最新: ${latest:-未知}${RESET}"

        if [ -z "$latest" ]; then
            echo -e "${YELLOW}无法获取最新版本，跳过${RESET}"
            continue
        fi
        if [ -n "$current" ] && version_greater_equal "$current" "$latest"; then
            echo -e "${GREEN}已是最新${RESET}"
            continue
        fi

        echo -e "${CYAN}发现新版本，是否更新 ${version} 通道? [y/N]${RESET}"
        read -r choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            update_snell_channel "$version" && updated=$((updated + 1))
        else
            echo -e "${CYAN}已跳过 ${version}${RESET}"
        fi
    done

    echo -e "\n${GREEN}检查完成，本次更新了 ${updated} 个通道${RESET}"
}

# 安装一个新通道，只落盘二进制，不改动任何现有用户
install_extra_channel() {
    local installed missing version
    installed=" $(list_installed_snell_versions) "
    missing=""
    for version in $SNELL_ALL_VERSIONS; do
        case "$installed" in
            *" ${version} "*) ;;
            *) missing="${missing}${version} " ;;
        esac
    done
    missing="${missing% }"

    if [ -z "$missing" ]; then
        echo -e "${GREEN}v4 / v5 / v6 三个通道都已安装${RESET}"
        return 0
    fi

    echo -e "\n${YELLOW}尚未安装的通道：${missing}${RESET}"
    echo -e "${CYAN}装好后可在「多用户管理」里给具体端口选用，或用本菜单的「切换通道」${RESET}"
    local idx=1
    local options=()
    for version in $missing; do
        echo -e "${GREEN}${idx}.${RESET} 安装 Snell ${version}"
        options+=("$version")
        idx=$((idx + 1))
    done
    echo -e "${GREEN}0.${RESET} 返回"

    read -rp "请输入选项 [0-$((idx - 1))]: " pick
    if [ "$pick" = "0" ] || [ -z "$pick" ]; then
        return 0
    fi
    if ! [[ "$pick" =~ ^[0-9]+$ ]] || [ "$pick" -lt 1 ] || [ "$pick" -gt "${#options[@]}" ]; then
        echo -e "${RED}无效选项${RESET}"
        return 1
    fi

    local target="${options[$((pick - 1))]}"
    if install_snell_binary_for_version "$target" "true"; then
        echo -e "${GREEN}✓ Snell ${target} 已就绪，现有服务未受任何影响${RESET}"
    else
        return 1
    fi
}

# 切换某个用户（含主用户）所使用的通道
switch_user_channel() {
    local conf_file port version
    local confs=()
    local labels=()

    if [ -f "$SNELL_CONF_FILE" ]; then
        port=$(grep -E '^listen' "$SNELL_CONF_FILE" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
        version=$(get_conf_snell_version "$SNELL_CONF_FILE")
        confs+=("$SNELL_CONF_FILE")
        labels+=("主用户 (端口 ${port}) 当前: ${version}")
    fi

    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for conf_file in "${SNELL_CONF_DIR}/users"/snell-*.conf; do
            [ -f "$conf_file" ] || continue
            case "$conf_file" in
                *snell-main.conf) continue ;;
            esac
            port=$(grep -E '^listen' "$conf_file" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
            [ -n "$port" ] || continue
            version=$(get_conf_snell_version "$conf_file")
            confs+=("$conf_file")
            labels+=("用户 (端口 ${port}) 当前: ${version}")
        done
    fi

    if [ "${#confs[@]}" -eq 0 ]; then
        echo -e "${RED}没有可切换的用户${RESET}"
        return 1
    fi

    echo -e "\n${YELLOW}=== 选择要切换通道的用户 ===${RESET}"
    local idx=1
    for label in "${labels[@]}"; do
        echo -e "${GREEN}${idx}.${RESET} ${label}"
        idx=$((idx + 1))
    done
    echo -e "${GREEN}0.${RESET} 返回"

    read -rp "请输入选项 [0-$((idx - 1))]: " pick
    if [ "$pick" = "0" ] || [ -z "$pick" ]; then
        return 0
    fi
    if ! [[ "$pick" =~ ^[0-9]+$ ]] || [ "$pick" -lt 1 ] || [ "$pick" -gt "${#confs[@]}" ]; then
        echo -e "${RED}无效选项${RESET}"
        return 1
    fi

    local selected="${confs[$((pick - 1))]}"
    local current
    current=$(get_conf_snell_version "$selected")

    echo -e "\n${YELLOW}=== 选择目标通道（当前 ${current}）===${RESET}"
    echo -e "${GREEN}1.${RESET} Snell v4"
    echo -e "${GREEN}2.${RESET} Snell v5"
    echo -e "${GREEN}3.${RESET} Snell v6 (RC)"
    echo -e "${GREEN}0.${RESET} 返回"
    read -rp "请输入选项 [0-3]: " target_pick

    local target=""
    case "$target_pick" in
        1) target="v4" ;;
        2) target="v5" ;;
        3)
            target="v6"
            echo -e "${YELLOW}注意：v6 仍为预发布版本，已移除 QUIC 代理模式与 obfs${RESET}"
            ;;
        0|"") return 0 ;;
        *) echo -e "${RED}无效选项${RESET}"; return 1 ;;
    esac

    switch_conf_to_version "$selected" "$target"
}

# Snell 版本管理入口（原「更新 Snell」）
check_snell_update() {
    echo -e "\n${CYAN}=============== Snell 版本管理 ===============${RESET}"

    # 老的单版本布局先迁移，否则下面按通道展示会看不到东西
    migrate_snell_binary_layout

    local installed
    installed=$(list_installed_snell_versions)
    if [ -z "$installed" ]; then
        echo -e "${RED}未检测到任何已安装的 Snell 通道，请先执行安装。${RESET}"
        return 1
    fi

    echo -e "${YELLOW}已安装通道：${RESET}"
    local version svc_count svc_list
    for version in $installed; do
        svc_list=$(list_services_using_version "$version")
        svc_count=$(echo "$svc_list" | grep -c .)
        echo -e "  ${GREEN}${version}${RESET}  版本: $(get_channel_binary_version "$version")  使用中: ${svc_count} 个服务"
    done

    echo -e "\n${GREEN}1.${RESET} 检查并更新已安装通道"
    echo -e "${GREEN}2.${RESET} 安装一个新通道（只下载二进制，不影响现有用户）"
    echo -e "${GREEN}3.${RESET} 切换某个用户使用的通道"
    echo -e "${GREEN}0.${RESET} 返回"

    read -rp "请输入选项 [0-3]: " manage_choice
    case "$manage_choice" in
        1) update_installed_channels ;;
        2) install_extra_channel ;;
        3) switch_user_channel ;;
        0|"") echo -e "${CYAN}已返回${RESET}" ;;
        *) echo -e "${RED}请输入正确的选项 [0-3]${RESET}" ;;
    esac
}

# 获取最新 GitHub 版本
get_latest_github_version() {
    local api_url="https://api.github.com/repos/jinqians/snell.sh/releases/latest"
    local response
    
    response=$(curl -s "$api_url")
    if [ $? -ne 0 ] || [ -z "$response" ]; then
        echo -e "${RED}无法获取 GitHub 上的最新版本信息。${RESET}"
        return 1
    fi

    GITHUB_VERSION=$(echo "$response" | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4)
    if [ -z "$GITHUB_VERSION" ]; then
        echo -e "${RED}解析 GitHub 版本信息失败。${RESET}"
        return 1
    fi
}

# 更新脚本
update_script() {
    echo -e "${CYAN}正在检查脚本更新...${RESET}"
    
    # 创建临时文件
    TMP_SCRIPT=$(mktemp)
    
    # 下载最新版本
    if curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/main/snell.sh -o "$TMP_SCRIPT"; then
        # 获取新版本号
        new_version=$(grep -m1 -E '^current_version="' "$TMP_SCRIPT" | cut -d'"' -f2)
        
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

# 检查是否安装的函数
check_installation() {
    local service=$1
    if systemctl list-unit-files | grep -q "^$service.service"; then
        echo -e "${GREEN}已安装${RESET}"
    else
        echo -e "${RED}未安装${RESET}"
    fi
}

# 获取 ShadowTLS 配置
get_shadowtls_config() {
    # 获取主 Snell 端口
    local main_port=$(get_snell_port)
    if [ -z "$main_port" ]; then
        return 1
    fi
    
    # 检查对应端口的 ShadowTLS 服务
    local service_name="shadowtls-snell-${main_port}"
    if ! systemctl is-active --quiet "$service_name"; then
        return 1
    fi
    
    local service_file="/etc/systemd/system/${service_name}.service"
    if [ ! -f "$service_file" ]; then
        return 1
    fi
    
    # 从服务文件中读取配置行
    local exec_line=$(grep "ExecStart=" "$service_file")
    if [ -z "$exec_line" ]; then
        return 1
    fi
    
    # 提取配置信息
    local tls_domain=$(echo "$exec_line" | grep -o -- "--tls [^ ]*" | cut -d' ' -f2)
    local password=$(echo "$exec_line" | grep -o -- "--password [^ ]*" | cut -d' ' -f2)
    local listen_part=$(echo "$exec_line" | grep -o -- "--listen [^ ]*" | cut -d' ' -f2)
    local listen_port=$(echo "$listen_part" | grep -o '[0-9]*$')
    
    if [ -z "$tls_domain" ] || [ -z "$password" ] || [ -z "$listen_port" ]; then
        return 1
    fi
    
    echo "${password}|${tls_domain}|${listen_port}"
    return 0
}

# 检查是否以 root 权限运行
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请以 root 权限运行此脚本${RESET}"
        exit 1
    fi
}

# 初始检查
initial_check() {
    check_root
    check_curl
    check_bc
    check_and_migrate_config
    # 旧的单版本布局迁到按通道分开存；已经是新布局时什么都不做
    if [ -e "${INSTALL_DIR}/snell-server" ]; then
        migrate_snell_binary_layout
    fi
    sync_existing_main_service_unit
    check_and_show_status
}

# 运行初始检查
initial_check

# 多用户管理
setup_multi_user() {
    echo -e "${CYAN}正在执行多用户管理脚本...${RESET}"
    bash <(curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/main/multi-user.sh)
    
    # 多用户管理脚本执行完毕后会自动返回这里
    echo -e "${GREEN}多用户管理操作完成${RESET}"
    sleep 1  # 给用户一点时间看到提示
}

# 主菜单
show_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}    Snell 管理脚本 v${current_version} (v4/v5/v6 可共存)${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}作者: jinqian${RESET}"
    echo -e "${GREEN}网站：https://jinqians.com${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    
    # 显示服务状态
    check_and_show_status
    
    echo -e "${YELLOW}=== 基础功能 ===${RESET}"
    echo -e "${GREEN}1.${RESET} 安装 Snell"
    echo -e "${GREEN}2.${RESET} 卸载 Snell"
    echo -e "${GREEN}3.${RESET} 查看配置"
    echo -e "${GREEN}4.${RESET} 重启服务"
    
    echo -e "\n${YELLOW}=== 增强功能 ===${RESET}"
    echo -e "${GREEN}5.${RESET} ShadowTLS 管理"
    echo -e "${GREEN}6.${RESET} BBR 管理"
    echo -e "${GREEN}7.${RESET} 多用户管理"
    
    echo -e "\n${YELLOW}=== 系统功能 ===${RESET}"
    echo -e "${GREEN}8.${RESET} 版本管理（更新 / 追加通道 / 切换通道）"
    echo -e "${GREEN}9.${RESET} 更新脚本"
    echo -e "${GREEN}10.${RESET} 查看服务状态"
    echo -e "${GREEN}11.${RESET} Snell v5/v6 出口控制设置"
    echo -e "${GREEN}0.${RESET} 退出脚本"
    
    echo -e "${CYAN}============================================${RESET}"
    if ! read -rp "请输入选项 [0-11]: " num; then
        echo
        echo -e "${YELLOW}未读取到输入，已退出 Snell 菜单。${RESET}"
        exit 0
    fi
}

#开启bbr
setup_bbr() {
    echo -e "${CYAN}正在获取并执行 BBR 管理脚本...${RESET}"
    
    # 直接从远程执行BBR脚本
    bash <(curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/main/bbr.sh)
    
    # BBR 脚本执行完毕后会自动返回这里
    echo -e "${GREEN}BBR 管理操作完成${RESET}"
    sleep 1  # 给用户一点时间看到提示
}

# ShadowTLS管理
setup_shadowtls() {
    echo -e "${CYAN}正在执行 ShadowTLS 管理脚本...${RESET}"
    bash <(curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/main/shadowtls.sh)
    
    # ShadowTLS 脚本执行完毕后会自动返回这里
    echo -e "${GREEN}ShadowTLS 管理操作完成${RESET}"
    sleep 1  # 给用户一点时间看到提示
}

# 获取 Snell 端口
get_snell_port() {
    if [ -f "${SNELL_CONF_DIR}/users/snell-main.conf" ]; then
        grep -E '^listen' "${SNELL_CONF_DIR}/users/snell-main.conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p'
    fi
}

# 获取所有 Snell 用户配置
get_all_snell_users() {
    # 检查用户配置目录是否存在
    if [ ! -d "${SNELL_CONF_DIR}/users" ]; then
        return 1
    fi
    
    # 首先获取主用户配置
    local main_port=""
    local main_psk=""
    if [ -f "${SNELL_CONF_DIR}/users/snell-main.conf" ]; then
        main_port=$(grep -E '^listen' "${SNELL_CONF_DIR}/users/snell-main.conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
        main_psk=$(grep -E '^psk' "${SNELL_CONF_DIR}/users/snell-main.conf" | awk -F'=' '{print $2}' | tr -d ' ')
        if [ ! -z "$main_port" ] && [ ! -z "$main_psk" ]; then
            echo "${main_port}|${main_psk}"
        fi
    fi
    
    # 获取其他用户配置
    for user_conf in "${SNELL_CONF_DIR}/users"/snell-*.conf; do
        if [ -f "$user_conf" ] && [[ "$user_conf" != *"snell-main.conf" ]]; then
            local port=$(grep -E '^listen' "$user_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
            local psk=$(grep -E '^psk' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
            if [ ! -z "$port" ] && [ ! -z "$psk" ]; then
                echo "${port}|${psk}"
            fi
        fi
    done
}

# 主循环
while true; do
    show_menu
    case "$num" in
        1)
            install_snell
            ;;
        2)
            uninstall_snell
            ;;
        3)
            view_snell_config
            ;;
        4)
            restart_snell
            ;;
        5)
            setup_shadowtls
            ;;
        6)
            setup_bbr
            ;;
        7)
            setup_multi_user
            ;;
        8)
            check_snell_update
            ;;
        9)
            update_script
            ;;
        10)
            check_and_show_status
            read -p "按任意键继续..." || exit 0
            ;;
        11)
            configure_v5_egress_control
            read -p "按任意键继续..." || exit 0
            ;;
        0)
            echo -e "${GREEN}感谢使用，再见！${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}请输入正确的选项 [0-11]${RESET}"
            ;;
    esac
    echo -e "\n${CYAN}按任意键返回主菜单...${RESET}"
    read -n 1 -s -r || exit 0
done
