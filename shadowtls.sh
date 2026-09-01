#!/bin/bash
# =========================================
# 作者: jinqians
# 日期: 2025年3月16
# 网站：jinqians.com
# 描述: 这个脚本用于安装和管理 ShadowTLS V3
# =========================================

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 定义系统路径
INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
CONFIG_DIR="/etc/shadowtls"
SERVICE_FILE="${SYSTEMD_DIR}/shadowtls.service"

# 定义配置目录
SNELL_CONF_DIR="/etc/snell"
SNELL_CONF_FILE="${SNELL_CONF_DIR}/users/snell-main.conf"
OLD_SNELL_CONF_FILE="${SNELL_CONF_DIR}/snell-server.conf"
USERS_DIR="${SNELL_CONF_DIR}/users"
SNELL_SERVICE_USER="snell"
SNELL_SERVICE_GROUP="snell"

# =========================================
# 读取 Snell 通道信息（与 snell.sh 的版本层保持一致的只读子集）
# 每个用户配置首行的 "#version-choice = vX" 标明该端口跑的是哪个版本；
# 没有标记时（尚未迁移的老安装）回落到 snell-server 软链自报的版本。
# =========================================
SNELL_VERSION_MARKER_KEY="version-choice"

snell_binary_for_version() {
    case "$1" in
        v4|v5|v6) echo "${INSTALL_DIR}/snell-server-$1" ;;
        *)        echo "${INSTALL_DIR}/snell-server" ;;
    esac
}

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
        echo "v4"
    fi
}

detect_installed_snell_version() {
    probe_snell_binary_version "${INSTALL_DIR}/snell-server"
}

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

get_conf_snell_version() {
    local conf_file="$1"
    local marked
    if marked=$(read_conf_snell_version "$conf_file"); then
        echo "$marked"
        return 0
    fi
    detect_installed_snell_version
}

snell_conf_for_port() {
    local port="$1"
    local main_port
    main_port=$(get_snell_port 2>/dev/null)
    if [ -n "$main_port" ] && [ "$port" = "$main_port" ]; then
        echo "$SNELL_CONF_FILE"
    else
        echo "${USERS_DIR}/snell-${port}.conf"
    fi
}

# 后端端口 -> 该端口跑的 Snell 版本
get_port_snell_version() {
    get_conf_snell_version "$(snell_conf_for_port "$1")"
}

# 后端端口 -> v6 的 mode（客户端必须与服务端一致）
get_port_snell_mode() {
    local conf_file mode=""
    conf_file=$(snell_conf_for_port "$1")
    if [ -f "$conf_file" ]; then
        mode=$(grep -E '^[[:space:]]*mode[[:space:]]*=' "$conf_file" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' ')
    fi
    echo "${mode:-default}"
}

# 生成一个后端端口对应的 Surge 代理行（含 ShadowTLS 参数）
print_snell_shadowtls_line() {
    local label="$1"
    local server_ip="$2"
    local stls_port="$3"
    local psk="$4"
    local stls_password="$5"
    local stls_sni="$6"
    local backend_port="$7"

    local version stls_suffix
    version=$(get_port_snell_version "$backend_port")
    stls_suffix="reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_sni}, shadow-tls-version = 3"

    case "$version" in
        v6)
            echo -e "${label} (v6) = snell, ${server_ip}, ${stls_port}, psk = ${psk}, version = 6, mode = $(get_port_snell_mode "$backend_port"), ${stls_suffix}"
            ;;
        v5)
            echo -e "${label} (v4) = snell, ${server_ip}, ${stls_port}, psk = ${psk}, version = 4, ${stls_suffix}"
            echo -e "${label} (v5) = snell, ${server_ip}, ${stls_port}, psk = ${psk}, version = 5, ${stls_suffix}"
            ;;
        *)
            echo -e "${label} (v4) = snell, ${server_ip}, ${stls_port}, psk = ${psk}, version = 4, ${stls_suffix}"
            ;;
    esac
}

# 检查是否以 root 权限运行
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请以 root 权限运行此脚本${RESET}"
        exit 1
    fi
}

# 安装必要的工具
install_requirements() {
    apt update
    apt install -y wget curl jq
}

# 获取最新版本
SHADOWTLS_FALLBACK_VERSION="v0.2.25"

get_latest_version() {
    local latest_version=""

    # 优先走 API；失败时 jq 可能返回 "null"
    latest_version=$(curl -fsSL --connect-timeout 10 "https://api.github.com/repos/ihciah/shadow-tls/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)

    # API 异常（如限流）时，回退到 releases/latest 的重定向结果
    if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
        latest_version=$(curl -fsSL --connect-timeout 10 -o /dev/null -w '%{url_effective}' "https://github.com/ihciah/shadow-tls/releases/latest" 2>/dev/null | sed -E 's#.*/tag/##')
    fi

    # 两次均失败时，使用内置的已知可用版本
    if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
        echo -e "${YELLOW}无法从 GitHub 获取最新版本，使用内置版本 ${SHADOWTLS_FALLBACK_VERSION}${RESET}" >&2
        latest_version="$SHADOWTLS_FALLBACK_VERSION"
    fi

    echo "$latest_version"
}

# 检查 SS 是否已安装
check_ssrust() {
    if [ ! -f "/usr/local/bin/ss-rust" ]; then
        return 1
    fi
    return 0
}

# 检查 Snell 是否已安装
check_snell() {
    if [ ! -f "/usr/local/bin/snell-server" ]; then
        return 1
    fi
    return 0
}

save_nftables_rules() {
    if ! command -v nft >/dev/null 2>&1; then
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

open_nftables_port() {
    local port=$1
    local chains
    local chain_opened=false

    if ! command -v nft >/dev/null 2>&1; then
        return
    fi

    echo -e "${CYAN}在 nftables 中开放端口 ${port}${RESET}"

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

        if ! nft list chain "$family" "$table" "$chain" 2>/dev/null | grep -q "tcp dport ${port} .*accept"; then
            nft insert rule "$family" "$table" "$chain" tcp dport "$port" accept 2>/dev/null || true
        fi
        chain_opened=true
    done << EOF
$chains
EOF

    if [ "$chain_opened" = false ]; then
        nft add table inet shadowtls_filter 2>/dev/null || true
        nft list chain inet shadowtls_filter input >/dev/null 2>&1 || nft add chain inet shadowtls_filter input '{ type filter hook input priority -5; policy accept; }'
        if ! nft list chain inet shadowtls_filter input 2>/dev/null | grep -q "tcp dport ${port} .*accept"; then
            nft add rule inet shadowtls_filter input tcp dport "$port" accept 2>/dev/null || true
        fi
    fi

    save_nftables_rules
}

open_port() {
    local port=$1
    local ufw_active=false

    if command -v ufw >/dev/null 2>&1; then
        echo -e "${CYAN}在 UFW 中开放端口 ${port}${RESET}"
        ufw allow "${port}"/tcp
        if ufw status 2>/dev/null | grep -qw "active"; then
            ufw_active=true
        fi
    fi

    if command -v iptables >/dev/null 2>&1; then
        echo -e "${CYAN}在 iptables 中开放端口 ${port}${RESET}"
        iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 || true
    fi

    if [ "$ufw_active" = false ]; then
        open_nftables_port "$port"
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
    mkdir -p "${USERS_DIR}"
    if getent group "${SNELL_SERVICE_GROUP}" >/dev/null 2>&1 && getent passwd "${SNELL_SERVICE_USER}" >/dev/null 2>&1; then
        chown -R "${SNELL_SERVICE_USER}:${SNELL_SERVICE_GROUP}" "${SNELL_CONF_DIR}" 2>/dev/null || true
    fi
    chmod 755 "${SNELL_CONF_DIR}" "${USERS_DIR}" 2>/dev/null || true
}

migrate_legacy_snell_config() {
    ensure_snell_config_dir

    if [ -f "${SNELL_CONF_FILE}" ]; then
        return 0
    fi

    if [ -f "${OLD_SNELL_CONF_FILE}" ]; then
        cp -a "${OLD_SNELL_CONF_FILE}" "${SNELL_CONF_FILE}"
        if getent group "${SNELL_SERVICE_GROUP}" >/dev/null 2>&1 && getent passwd "${SNELL_SERVICE_USER}" >/dev/null 2>&1; then
            chown "${SNELL_SERVICE_USER}:${SNELL_SERVICE_GROUP}" "${SNELL_CONF_FILE}" 2>/dev/null || true
        fi
        chmod 644 "${SNELL_CONF_FILE}"
        echo -e "${GREEN}已将旧 Snell 配置迁移到 ${SNELL_CONF_FILE}${RESET}"
        return 0
    fi

    return 1
}

check_snell_config() {
    if ! check_snell; then
        return 1
    fi

    migrate_legacy_snell_config || true

    if [ ! -s "${SNELL_CONF_FILE}" ]; then
        echo -e "${RED}Snell 主配置不存在: ${SNELL_CONF_FILE}${RESET}"
        echo -e "${YELLOW}请先运行 Snell 安装/修复，或将旧配置 ${OLD_SNELL_CONF_FILE} 迁移到 users 目录。${RESET}"
        return 1
    fi

    if ! grep -Eq '^[[:space:]]*listen[[:space:]]*=' "${SNELL_CONF_FILE}"; then
        echo -e "${RED}Snell 主配置缺少 listen: ${SNELL_CONF_FILE}${RESET}"
        return 1
    fi

    if ! grep -Eq '^[[:space:]]*psk[[:space:]]*=' "${SNELL_CONF_FILE}"; then
        echo -e "${RED}Snell 主配置缺少 psk: ${SNELL_CONF_FILE}${RESET}"
        return 1
    fi

    return 0
}

# 获取 SS 端口
get_ssrust_port() {
    local ssrust_conf="/etc/ss-rust/config.json"
    if [ ! -f "$ssrust_conf" ]; then
        return 1
    fi
    local port=$(jq -r '.server_port' "$ssrust_conf" 2>/dev/null)
    echo "$port"
}

# 获取 SS 密码
get_ssrust_password() {
    local ssrust_conf="/etc/ss-rust/config.json"
    if [ ! -f "$ssrust_conf" ]; then
        return 1
    fi
    local password=$(jq -r '.password' "$ssrust_conf" 2>/dev/null)
    echo "$password"
}

# 获取 SS 加密方式
get_ssrust_method() {
    local ssrust_conf="/etc/ss-rust/config.json"
    if [ ! -f "$ssrust_conf" ]; then
        return 1
    fi
    local method=$(jq -r '.method' "$ssrust_conf" 2>/dev/null)
    echo "$method"
}

# 获取 Snell 端口
get_snell_port() {
    migrate_legacy_snell_config >/dev/null 2>&1 || true
    if [ -f "${SNELL_CONF_FILE}" ]; then
        grep -E '^listen' "${SNELL_CONF_FILE}" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p'
    fi
}

# 获取 Snell PSK
get_snell_psk() {
    local snell_conf="${SNELL_CONF_FILE}"
    migrate_legacy_snell_config >/dev/null 2>&1 || true
    if [ ! -f "$snell_conf" ]; then
        return 1
    fi
    local psk=$(grep -E '^psk' "$snell_conf" | sed 's/psk = //')
    echo "$psk"
}

# 获取 Snell 配置
get_snell_config() {
    local port=$1
    local snell_conf="${USERS_DIR}/snell-${port}.conf"
    local main_conf="${USERS_DIR}/snell-main.conf"
    local psk=""
    
    migrate_legacy_snell_config >/dev/null 2>&1 || true

    if [ -f "$snell_conf" ]; then
        psk=$(grep -E "^psk[[:space:]]*=" "$snell_conf" 2>/dev/null | head -n 1 | sed 's/^[^=]*=[[:space:]]*//')
    fi

    if [ -z "$psk" ] && [ -f "$main_conf" ]; then
        psk=$(grep -E "^psk[[:space:]]*=" "$main_conf" 2>/dev/null | head -n 1 | sed 's/^[^=]*=[[:space:]]*//')
    fi

    echo "$psk"
}

# 获取所有 Snell 用户配置
get_all_snell_users() {
    migrate_legacy_snell_config >/dev/null 2>&1 || true

    # 检查用户配置目录是否存在
    if [ ! -d "${USERS_DIR}" ]; then
        return 1
    fi
    
    # 首先获取主用户配置
    local main_port=""
    local main_psk=""
    if [ -f "${SNELL_CONF_FILE}" ]; then
        main_port=$(grep -E '^listen' "${SNELL_CONF_FILE}" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
        main_psk=$(grep -E '^psk' "${SNELL_CONF_FILE}" | awk -F'=' '{print $2}' | tr -d ' ')
        if [ ! -z "$main_port" ] && [ ! -z "$main_psk" ]; then
            echo "${main_port}|${main_psk}"
        fi
    fi
    
    # 获取其他用户配置
    for user_conf in "${USERS_DIR}"/snell-*.conf; do
        if [ -f "$user_conf" ] && [[ "$user_conf" != *"snell-main.conf" ]]; then
            local port=$(grep -E '^listen' "$user_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
            local psk=$(grep -E '^psk' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
            if [ ! -z "$port" ] && [ ! -z "$psk" ]; then
                echo "${port}|${psk}"
            fi
        fi
    done
}

get_snell_config_file_by_port() {
    local target_port=$1
    local conf
    local port

    migrate_legacy_snell_config >/dev/null 2>&1 || true

    for conf in "${SNELL_CONF_FILE}" "${USERS_DIR}"/snell-*.conf; do
        [ -f "$conf" ] || continue
        port=$(sed -n 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*.*:\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$conf" | head -n 1)
        if [ "$port" = "$target_port" ]; then
            echo "$conf"
            return 0
        fi
    done

    return 1
}

get_snell_service_name_by_config() {
    local conf=$1
    local filename

    if [ "$conf" = "${SNELL_CONF_FILE}" ]; then
        echo "snell"
        return 0
    fi

    filename=$(basename "$conf")
    case "$filename" in
        snell-[0-9]*.conf)
            echo "${filename%.conf}"
            return 0
            ;;
    esac

    return 1
}

restrict_snell_to_loopback() {
    local port=$1
    local conf
    local service_name

    conf=$(get_snell_config_file_by_port "$port") || {
        echo -e "${RED}未找到 Snell 端口 ${port} 对应的配置文件${RESET}"
        return 1
    }

    service_name=$(get_snell_service_name_by_config "$conf") || {
        echo -e "${RED}无法识别 Snell 端口 ${port} 对应的 systemd 服务${RESET}"
        return 1
    }

    if [ "$service_name" = "snell" ] && { systemctl is-active --quiet snell.socket 2>/dev/null || systemctl is-enabled --quiet snell.socket 2>/dev/null; }; then
        echo -e "${RED}检测到 snell.socket 正在使用，暂不能自动将主 Snell 改为 ShadowTLS 后端模式${RESET}"
        echo -e "${YELLOW}请先在 Snell 管理脚本中关闭出口控制/socket 激活模式，再配置 ShadowTLS。${RESET}"
        return 1
    fi

    if grep -Eq "^[[:space:]]*listen[[:space:]]*=[[:space:]]*127\\.0\\.0\\.1:${port}[[:space:]]*$" "$conf"; then
        echo -e "${GREEN}Snell 端口 ${port} 已仅监听 127.0.0.1${RESET}"
    else
        cp -a "$conf" "${conf}.bak.$(date +%Y%m%d%H%M%S)"
        sed -i "s|^[[:space:]]*listen[[:space:]]*=.*:${port}[[:space:]]*$|listen = 127.0.0.1:${port}|" "$conf"

        if ! grep -Eq "^[[:space:]]*listen[[:space:]]*=[[:space:]]*127\\.0\\.0\\.1:${port}[[:space:]]*$" "$conf"; then
            echo -e "${RED}修改 Snell 监听地址失败: ${conf}${RESET}"
            return 1
        fi

        if getent group "${SNELL_SERVICE_GROUP}" >/dev/null 2>&1 && getent passwd "${SNELL_SERVICE_USER}" >/dev/null 2>&1; then
            chown "${SNELL_SERVICE_USER}:${SNELL_SERVICE_GROUP}" "$conf" 2>/dev/null || true
        fi
        chmod 644 "$conf" 2>/dev/null || true

        echo -e "${GREEN}已将 Snell 端口 ${port} 改为仅监听 127.0.0.1${RESET}"
    fi

    systemctl restart "$service_name"
    close_port "$port"
    echo -e "${GREEN}已关闭 Snell 原始端口 ${port} 的公网放行规则，客户端请连接 ShadowTLS 端口${RESET}"
}

# 获取指定后端端口的 Snell 大版本号（4 / 5 / 6）
# 不传端口时退回主用户端口。原实现只认 v4/v5，且对所有端口给同一个答案，
# 在多版本共存下会把 v6 端口误报成 v4。
get_snell_version() {
    local port="${1:-$(get_snell_port)}"
    local version

    if [ -z "$port" ]; then
        version=$(detect_installed_snell_version)
    else
        version=$(get_port_snell_version "$port")
    fi

    case "$version" in
        v6) echo "6" ;;
        v5) echo "5" ;;
        v4) echo "4" ;;
        *)  return 1 ;;
    esac
}

# 获取服务器IP
get_server_ip() {
    local ipv4
    local ipv6
    
    # 获取IPv4地址
    ipv4=$(curl -s -4 ip.sb 2>/dev/null)
    
    # 获取IPv6地址
    ipv6=$(curl -s -6 ip.sb 2>/dev/null)
    
    # 判断IP类型并返回
    if [ -n "$ipv4" ] && [ -n "$ipv6" ]; then
        # 双栈，优先返回IPv4
        echo "$ipv4"
    elif [ -n "$ipv4" ]; then
        # 仅IPv4
        echo "$ipv4"
    elif [ -n "$ipv6" ]; then
        # 仅IPv6
        echo "$ipv6"
    else
        echo -e "${RED}无法获取服务器 IP${RESET}"
        return 1
    fi
    
    return 0
}

# 检查 shadow-tls 命令格式
check_shadowtls_command() {
    local help_output
    help_output=$($INSTALL_DIR/shadow-tls --help 2>&1)
    echo -e "${YELLOW}Shadow-tls 帮助信息：${RESET}"
    echo "$help_output"
    return 0
}

# 生成安全的Base64编码
urlsafe_base64() {
    date=$(echo -n "$1"|base64|sed ':a;N;s/\n/ /g;ta'|sed 's/ //g;s/=//g;s/+/-/g;s/\//_/g')
    echo -e "${date}"
}

# 生成随机端口
generate_random_port() {
    local min_port=10000
    local max_port=65535
    echo $(shuf -i ${min_port}-${max_port} -n 1)
}

# 检查端口是否被占用
check_port_usage() {
    local port=$1

    if command -v ss >/dev/null 2>&1; then
        if ss -tuln | grep -q ":${port}\b"; then
            return 0  # 端口被占用
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -tuln | grep -q ":${port}\b"; then
            return 0  # 端口被占用
        fi
    fi

    return 1     # 端口未被占用
}

# 获取已使用的 ShadowTLS 端口
get_used_stls_ports() {
    local used_ports=()
    
    # 检查 SS 服务
    local ss_service="${SYSTEMD_DIR}/shadowtls-ss.service"
    if [ -f "$ss_service" ]; then
        local ss_port=$(grep -oP '(?<=--listen ::0:)\d+' "$ss_service")
        if [ ! -z "$ss_port" ]; then
            used_ports+=("$ss_port")
        fi
    fi
    
    # 检查 Snell 服务
    local snell_services=$(find /etc/systemd/system -name "shadowtls-snell-*.service" 2>/dev/null)
    if [ ! -z "$snell_services" ]; then
        while IFS= read -r service_file; do
            local port=$(grep -oP '(?<=--listen ::0:)\d+' "$service_file")
            if [ ! -z "$port" ]; then
                used_ports+=("$port")
            fi
        done <<< "$snell_services"
    fi
    
    echo "${used_ports[@]}"
}

# 验证并获取可用端口
get_available_port() {
    local port=$1
    local used_ports=($(get_used_stls_ports))
    
    # 如果用户指定了端口
    if [ ! -z "$port" ]; then
        # 检查端口是否已被 ShadowTLS 使用
        for used_port in "${used_ports[@]}"; do
            if [ "$port" = "$used_port" ]; then
                echo -e "${RED}端口 ${port} 已被其他 ShadowTLS 服务使用${RESET}"
                return 1
            fi
        done
        
        # 检查端口是否被其他服务使用
        if check_port_usage "$port"; then
            echo -e "${RED}端口 ${port} 已被其他服务占用${RESET}"
            return 1
        fi
        
        echo "$port"
        return 0
    fi
    
    # 如果用户没有指定端口，生成随机端口
    local attempts=0
    while [ $attempts -lt 10 ]; do
        local random_port=$(generate_random_port)
        local is_used=0
        
        # 检查是否已被 ShadowTLS 使用
        for used_port in "${used_ports[@]}"; do
            if [ "$random_port" = "$used_port" ]; then
                is_used=1
                break
            fi
        done
        
        # 如果端口未被使用且未被占用
        if [ $is_used -eq 0 ] && ! check_port_usage "$random_port"; then
            echo "$random_port"
            return 0
        fi
        
        attempts=$((attempts + 1))
    done
    
    echo -e "${RED}无法找到可用端口${RESET}"
    return 1
}

# 生成 SS 链接和配置
generate_ss_links() {
    local server_ip=$1
    local listen_port=$2
    local ssrust_password=$3
    local ssrust_method=$4
    local stls_password=$5
    local stls_sni=$6
    local backend_port=$7
    
    echo -e "\n${YELLOW}=== 服务器配置 ===${RESET}"
    echo -e "服务器IP：${server_ip}"
    echo -e "\nShadowsocks 配置："
    echo -e "  - 端口：${backend_port}"
    echo -e "  - 加密方式：${ssrust_method}"
    echo -e "  - 密码：${ssrust_password}"
    echo -e "\nShadowTLS 配置："
    echo -e "  - 端口：${listen_port}"
    echo -e "  - 密码：${stls_password}"
    echo -e "  - SNI：${stls_sni}"
    echo -e "  - 版本：3"
    
    # 生成 SS + ShadowTLS 合并链接
    local userinfo=$(echo -n "${ssrust_method}:${ssrust_password}" | base64 | tr -d '\n')
    # shadow_tls_config = plugin=shadow-tls;host=${stls_sni};password=${stls_password};version=3
    local shadow_tls_config="plugin=shadow-tls;host=${stls_sni};password=${stls_password};version=3"
    local ss_url="ss://${userinfo}@${server_ip}:${listen_port}?${shadow_tls_config}"

    echo -e "\n${YELLOW}=== Surge 配置 ===${RESET}"
    echo -e "SS-${server_ip} = ss, ${server_ip}, ${listen_port}, encrypt-method=${ssrust_method}, password=${ssrust_password}, shadow-tls-password=${stls_password}, shadow-tls-sni=${stls_sni}, shadow-tls-version=3, udp-relay=true"
    
    echo -e "\n${YELLOW}=== Shadowrocket 配置说明 ===${RESET}"
    echo -e "1. 添加 Shadowsocks 节点："
    echo -e "   - 类型：Shadowsocks"
    echo -e "   - 地址：${server_ip}"
    echo -e "   - 端口：${backend_port}"
    echo -e "   - 加密方法：${ssrust_method}"
    echo -e "   - 密码：${ssrust_password}"
    
    echo -e "\n2. 添加 ShadowTLS 节点："
    echo -e "   - 类型：ShadowTLS"
    echo -e "   - 地址：${server_ip}"
    echo -e "   - 端口：${listen_port}"
    echo -e "   - 密码：${stls_password}"
    echo -e "   - SNI：${stls_sni}"
    echo -e "   - 版本：3"

    echo -e "\n${YELLOW}=== Shadowrocket分享链接 ===${RESET}"
    echo -e "${GREEN}SS + ShadowTLS 链接：${RESET}${ss_url}"
    
    echo -e "\n${YELLOW}=== Shadowrocket二维码 ===${RESET}"
    qrencode -t UTF8 "${ss_url}"
    
    echo -e "\n${YELLOW}=== Clash Meta 配置 ===${RESET}"
    echo -e "proxies:"
    echo -e "  - name: SS-${server_ip}"
    echo -e "    type: ss"
    echo -e "    server: ${server_ip}"
    echo -e "    port: ${listen_port}"
    echo -e "    cipher: ${ssrust_method}"
    echo -e "    password: \"${ssrust_password}\""
    echo -e "    plugin: shadow-tls"
    echo -e "    plugin-opts:"
    echo -e "      host: \"${stls_sni}\""
    echo -e "      password: \"${stls_password}\""
    echo -e "      version: 3"
}

# 生成 Snell 链接和配置
generate_snell_links() {
    local server_ip=$1
    local listen_port=$2
    local snell_psk=$3
    local stls_password=$4
    local stls_sni=$5
    local backend_port=$6
    
    # 版本取自这个后端端口自己的通道
    local snell_version=$(get_snell_version "$backend_port")
    
    echo -e "\n${YELLOW}=== 服务器配置 ===${RESET}"
    echo -e "服务器IP：${server_ip}"
    echo -e "\nSnell 配置："
    echo -e "  - 端口：${backend_port}"
    echo -e "  - PSK：${snell_psk}"
    echo -e "  - 版本：${snell_version}"
    echo -e "\nShadowTLS 配置："
    echo -e "  - 端口：${listen_port}"
    echo -e "  - 密码：${stls_password}"
    echo -e "  - SNI：${stls_sni}"
    echo -e "  - 版本：3"
    
    echo -e "\n${YELLOW}=== Surge 配置 ===${RESET}"
    
    # v5 同时给出 v4/v5 两种写法；v6 需要额外带 mode
    print_snell_shadowtls_line "Snell + ShadowTLS" "$server_ip" "$listen_port" "$snell_psk" \
        "$stls_password" "$stls_sni" "$backend_port"
}

# 询问是否开启 wildcard-sni（默认关闭）
prompt_wildcard_sni() {
    wildcard_sni="off"
    echo -e "${YELLOW}是否开启 wildcard-sni=authed？${RESET}"
    echo -e "开启后已通过密码验证的客户端可使用与服务端不一致的伪装域名（SNI）"
    read -rp "开启 wildcard-sni=authed? [y/N]: " wildcard_choice
    case "$wildcard_choice" in
        [yY]|[yY][eE][sS])
            wildcard_sni="authed"
            echo -e "${GREEN}已开启 wildcard-sni=authed${RESET}"
            ;;
        *)
            echo -e "${GREEN}保持默认（关闭 wildcard-sni）${RESET}"
            ;;
    esac
}

# 启用 TCP Fast Open
enable_tcp_fastopen() {
    # 立即生效
    sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null 2>&1

    # 持久化配置，重启后仍然生效
    if [ -d /etc/sysctl.d ]; then
        echo "net.ipv4.tcp_fastopen = 3" > /etc/sysctl.d/99-tcp-fastopen.conf
    elif ! grep -q "^net.ipv4.tcp_fastopen" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.tcp_fastopen = 3" >> /etc/sysctl.conf
    fi
}

# 创建服务文件的模板
create_shadowtls_service() {
    local service_type=$1  # ss 或 snell
    local port=$2
    local listen_port=$3
    local tls_domain=$4
    local password=$5
    local service_file
    local description
    local identifier
    
    if [ "$service_type" = "ss" ]; then
        service_file="${SYSTEMD_DIR}/shadowtls-ss.service"
        description="Shadow-TLS Server Service for Shadowsocks"
        identifier="shadow-tls-ss"
    else
        service_file="${SYSTEMD_DIR}/shadowtls-snell-${port}.service"
        description="Shadow-TLS Server Service for Snell (Port: ${port})"
        identifier="shadow-tls-snell-${port}"
    fi

    # 启用 TCP Fast Open（内核参数）
    enable_tcp_fastopen

    # wildcard-sni 参数（默认 off，不附加）
    local wildcard_sni_flag=""
    if [ "$wildcard_sni" = "authed" ] || [ "$wildcard_sni" = "all" ]; then
        wildcard_sni_flag=" --wildcard-sni ${wildcard_sni}"
    fi

    cat > "$service_file" << EOF
[Unit]
Description=${description}
Documentation=man:sstls-server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
Environment=RUST_BACKTRACE=1
Environment=RUST_LOG=info
ExecStart=/usr/local/bin/shadow-tls --fastopen --v3 server --listen ::0:${listen_port} --server 127.0.0.1:${port} --tls ${tls_domain} --password ${password}${wildcard_sni_flag}
StandardOutput=append:/var/log/shadowtls-${identifier}.log
StandardError=append:/var/log/shadowtls-${identifier}.log
SyslogIdentifier=${identifier}
Restart=always
RestartSec=3

# 性能优化参数
LimitNOFILE=65535
CPUAffinity=0
Nice=0
IOSchedulingClass=realtime
IOSchedulingPriority=0
MemoryMax=512M
CPUQuota=50%
LimitCORE=infinity
LimitRSS=infinity
LimitNPROC=65535
LimitAS=infinity
SystemCallFilter=@system-service
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

# 系统优化参数
Environment=RUST_THREADS=1
Environment=MONOIO_FORCE_LEGACY_DRIVER=1
Environment=RUST_LOG_LEVEL=info
Environment=RUST_LOG_TARGET=journal
Environment=RUST_LOG_FORMAT=json
Environment=RUST_LOG_FILTER=info,shadow_tls=info

[Install]
WantedBy=multi-user.target
EOF

    # 创建日志文件并设置权限
    touch "/var/log/shadowtls-${identifier}.log"
    chmod 640 "/var/log/shadowtls-${identifier}.log"
    chown root:root "/var/log/shadowtls-${identifier}.log"
}

# 安装 ShadowTLS
install_shadowtls() {
    echo -e "${CYAN}正在安装 ShadowTLS...${RESET}"

    install_requirements
    
    # 检测已安装的协议
    local has_ss=false
    local has_snell=false
    
    if check_ssrust; then
        has_ss=true
        echo -e "${GREEN}检测到已安装 Shadowsocks Rust${RESET}"
    fi
    
    if check_snell_config; then
        has_snell=true
        echo -e "${GREEN}检测到已安装 Snell${RESET}"
    elif check_snell; then
        echo -e "${YELLOW}检测到 Snell 二进制，但主配置不可用，暂不能为 Snell 配置 ShadowTLS${RESET}"
    fi
    
    if ! $has_ss && ! $has_snell; then
        echo -e "${RED}未检测到 Shadowsocks Rust 或 Snell，请先安装其中一个${RESET}"
        return 1
    fi
    
    # 获取系统架构并下载安装 ShadowTLS
    arch=$(uname -m)
    case $arch in
        x86_64|amd64)
            arch="x86_64-unknown-linux-musl"
            ;;
        aarch64|arm64)
            arch="aarch64-unknown-linux-musl"
            ;;
        armv7l|armv7)
            arch="armv7-unknown-linux-musleabihf"
            ;;
        arm)
            arch="arm-unknown-linux-musleabi"
            ;;
        *)
            echo -e "${RED}不支持的系统架构: $arch${RESET}"
            exit 1
            ;;
    esac

    # 获取最新版本
    version=$(get_latest_version)

    # 尝试下载：先直连 GitHub，失败则走 ghproxy 镜像
    binary_name="shadow-tls-${arch}"
    github_url="https://github.com/ihciah/shadow-tls/releases/download/${version}/${binary_name}"
    proxy_url="https://ghproxy.com/${github_url}"

    echo -e "${CYAN}正在下载 ShadowTLS ${version} (${arch})...${RESET}"
    echo -e "${YELLOW}下载地址: ${github_url}${RESET}"

    if ! wget --timeout=30 --tries=2 -q "$github_url" -O "/tmp/shadow-tls.tmp" 2>/dev/null; then
        echo -e "${YELLOW}直连 GitHub 失败，尝试使用镜像下载...${RESET}"
        echo -e "${YELLOW}镜像地址: ${proxy_url}${RESET}"
        if ! wget --timeout=60 --tries=3 "$proxy_url" -O "/tmp/shadow-tls.tmp"; then
            echo -e "${RED}下载 ShadowTLS 失败，请检查网络连接后重试${RESET}"
            rm -f "/tmp/shadow-tls.tmp"
            exit 1
        fi
    fi

    # 验证下载的文件不为空
    if [ ! -s "/tmp/shadow-tls.tmp" ]; then
        echo -e "${RED}下载文件为空，请重试${RESET}"
        rm -f "/tmp/shadow-tls.tmp"
        exit 1
    fi
    
    # 移动到最终位置并设置权限
    mv "/tmp/shadow-tls.tmp" "$INSTALL_DIR/shadow-tls"
    chmod +x "$INSTALL_DIR/shadow-tls"
    
    # 生成随机密码
    password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
    
    # 获取 TLS 伪装域名
    read -rp "请输入 TLS 伪装域名 (直接回车默认为 www.microsoft.com): " tls_domain
    if [ -z "$tls_domain" ]; then
        tls_domain="www.microsoft.com"
    fi
    prompt_wildcard_sni
    
    # 让用户选择要为哪个协议设置 ShadowTLS
    while true; do
        echo -e "\n${YELLOW}请选择要配置的协议：${RESET}"
        echo -e "1. 为 Shadowsocks 配置 ShadowTLS"
        echo -e "2. 为 Snell 配置 ShadowTLS"
        echo -e "3. 为两者都配置 ShadowTLS"
        echo -e "0. 退出"
        
        read -rp "请选择 [0-3]: " protocol_choice
        
        case "$protocol_choice" in
            0)
                return 0
                ;;
            1)
                if ! $has_ss; then
                    echo -e "${RED}未安装 Shadowsocks${RESET}"
                    continue
                fi
                configure_ss=true
                configure_snell=false
                break
                ;;
            2)
                if ! $has_snell; then
                    echo -e "${RED}未安装 Snell${RESET}"
                    continue
                fi
                configure_ss=false
                configure_snell=true
                break
                ;;
            3)
                if ! $has_ss || ! $has_snell; then
                    echo -e "${RED}需要同时安装 Shadowsocks 和 Snell${RESET}"
                    continue
                fi
                configure_ss=true
                configure_snell=true
                break
                ;;
            *)
                echo -e "${RED}无效的选择${RESET}"
                ;;
        esac
    done
    
    # 配置 Shadowsocks
    if $configure_ss; then
        echo -e "\n${YELLOW}配置 Shadowsocks 的 ShadowTLS...${RESET}"
        while true; do
            read -rp "请输入 ShadowTLS 监听端口 (1-65535，直接回车随机生成): " ss_listen_port
            
            # 验证并获取可用端口
            ss_listen_port=$(get_available_port "$ss_listen_port")
            if [ $? -eq 0 ]; then
                break
            fi
            echo -e "${YELLOW}请重新输入端口${RESET}"
        done
        
        echo -e "${GREEN}将使用端口: ${ss_listen_port}${RESET}"
        
        # 创建 SS 的 ShadowTLS 服务
        local ss_port=$(get_ssrust_port)
        create_shadowtls_service "ss" "$ss_port" "$ss_listen_port" "$tls_domain" "$password"
        open_port "$ss_listen_port"
        systemctl start shadowtls-ss
        systemctl enable shadowtls-ss
    fi
    
    # 配置 Snell
    if $configure_snell; then
        echo -e "\n${YELLOW}配置 Snell 的 ShadowTLS...${RESET}"
        
        # 获取所有 Snell 用户配置
        local user_configs=$(get_all_snell_users)
        if [ -z "$user_configs" ]; then
            echo -e "${RED}未找到有效的 Snell 用户配置${RESET}"
            return 1
        fi
        
        # 显示所有 Snell 端口
        echo -e "\n${YELLOW}当前的 Snell 端口列表：${RESET}"
        local port_list=()
        while IFS='|' read -r port psk; do
            if [ ! -z "$port" ]; then
                port_list+=("$port")
                if [ "$port" = "$(get_snell_port)" ]; then
                    echo -e "${GREEN}${#port_list[@]}. ${port} (主用户)${RESET}"
                else
                    echo -e "${GREEN}${#port_list[@]}. ${port}${RESET}"
                fi
            fi
        done <<< "$user_configs"
        
        # 让用户选择要配置的端口
        echo -e "\n${YELLOW}请选择要配置的端口：${RESET}"
        echo -e "1-${#port_list[@]}. 选择单个端口"
        echo -e "0. 为所有端口配置 ShadowTLS"
        
        read -rp "请选择: " port_choice
        
        if [ "$port_choice" = "0" ]; then
            # 为所有端口配置 ShadowTLS
            for port in "${port_list[@]}"; do
                echo -e "\n${YELLOW}为 Snell 端口 ${port} 配置 ShadowTLS${RESET}"
                while true; do
                    read -rp "请输入 ShadowTLS 监听端口 (1-65535，直接回车随机生成): " stls_port
                    
                    # 验证并获取可用端口
                    stls_port=$(get_available_port "$stls_port")
                    if [ $? -eq 0 ]; then
                        break
                    fi
                    echo -e "${YELLOW}请重新输入端口${RESET}"
                done
                
                echo -e "${GREEN}将使用端口: ${stls_port}${RESET}"
                
                restrict_snell_to_loopback "$port" || return 1

                # 创建服务文件
                create_shadowtls_service "snell" "$port" "$stls_port" "$tls_domain" "$password"
                open_port "$stls_port"
                systemctl start "shadowtls-snell-${port}"
                systemctl enable "shadowtls-snell-${port}"
            done
        elif [[ "$port_choice" =~ ^[0-9]+$ ]] && [ "$port_choice" -ge 1 ] && [ "$port_choice" -le ${#port_list[@]} ]; then
            # 为选中的端口配置 ShadowTLS
            local selected_port="${port_list[$((port_choice-1))]}"
            echo -e "\n${YELLOW}为 Snell 端口 ${selected_port} 配置 ShadowTLS${RESET}"
            while true; do
                read -rp "请输入 ShadowTLS 监听端口 (1-65535，直接回车随机生成): " stls_port
                
                # 验证并获取可用端口
                stls_port=$(get_available_port "$stls_port")
                if [ $? -eq 0 ]; then
                    break
                fi
                echo -e "${YELLOW}请重新输入端口${RESET}"
            done
            
            echo -e "${GREEN}将使用端口: ${stls_port}${RESET}"
            
            restrict_snell_to_loopback "$selected_port" || return 1

            # 创建服务文件
            create_shadowtls_service "snell" "$selected_port" "$stls_port" "$tls_domain" "$password"
            open_port "$stls_port"
            systemctl start "shadowtls-snell-${selected_port}"
            systemctl enable "shadowtls-snell-${selected_port}"
        else
            echo -e "${RED}无效的选择${RESET}"
            return 1
        fi
    fi
    
    # 重新加载 systemd 配置
    systemctl daemon-reload
    
    # 获取服务器IP
    local server_ip=$(get_server_ip)
    
    echo -e "\n${GREEN}=== ShadowTLS 安装成功 ===${RESET}"
    
    # 显示所有可用的配置
    if $configure_ss; then
        local ssrust_password=$(get_ssrust_password)
        local ssrust_method=$(get_ssrust_method)
        local ss_port=$(get_ssrust_port)
        generate_ss_links "${server_ip}" "${ss_listen_port}" "${ssrust_password}" "${ssrust_method}" "${password}" "${tls_domain}" "${ss_port}"
    fi
    
    if $configure_snell; then
        while IFS='|' read -r port psk; do
            if [ ! -z "$port" ]; then
                local service_file="${SYSTEMD_DIR}/shadowtls-snell-${port}.service"
                if [ -f "$service_file" ]; then
                    local stls_port=$(grep -oP '(?<=--listen ::0:)\d+' "$service_file")
                    generate_snell_links "${server_ip}" "${stls_port}" "${psk}" "${password}" "${tls_domain}" "${port}"
                fi
            fi
        done <<< "$user_configs"
    fi

    echo -e "\n${GREEN}服务已启动并设置为开机自启${RESET}"
}

# 卸载 ShadowTLS
uninstall_shadowtls() {
    echo -e "${CYAN}正在卸载 ShadowTLS...${RESET}"
    
    # 停止并禁用 SS 服务
    if [ -f "${SYSTEMD_DIR}/shadowtls-ss.service" ]; then
        local ss_listen_port
        ss_listen_port=$(sed -n 's/.*--listen .*:\([0-9][0-9]*\).*/\1/p' "${SYSTEMD_DIR}/shadowtls-ss.service" | head -n 1)
        systemctl stop shadowtls-ss 2>/dev/null
        systemctl disable shadowtls-ss 2>/dev/null
        rm -f "${SYSTEMD_DIR}/shadowtls-ss.service"
        if [ -n "$ss_listen_port" ]; then
            close_port "$ss_listen_port"
        fi
    fi
    
    # 停止并禁用所有 Snell 相关的 ShadowTLS 服务
    local snell_services=$(find /etc/systemd/system -name "shadowtls-snell-*.service" 2>/dev/null)
    if [ ! -z "$snell_services" ]; then
        while IFS= read -r service_file; do
            local service_name=$(basename "$service_file")
            local listen_port
            listen_port=$(sed -n 's/.*--listen .*:\([0-9][0-9]*\).*/\1/p' "$service_file" | head -n 1)
            systemctl stop "$service_name" 2>/dev/null
            systemctl disable "$service_name" 2>/dev/null
            rm -f "$service_file"
            if [ -n "$listen_port" ]; then
                close_port "$listen_port"
            fi
        done <<< "$snell_services"
    fi
    
    # 删除二进制文件
    rm -f "$INSTALL_DIR/shadow-tls"
    
    # 重新加载 systemd 配置
    systemctl daemon-reload
    
    echo -e "${GREEN}ShadowTLS 已成功卸载${RESET}"
}

# 查看配置
view_config() {
    echo -e "${CYAN}正在获取配置信息...${RESET}"
    
    # 检查服务是否安装
    local ss_service="${SYSTEMD_DIR}/shadowtls-ss.service"
    local snell_services=$(find /etc/systemd/system -name "shadowtls-snell-*.service" 2>/dev/null | sort -u)
    
    if [ ! -f "$ss_service" ] && [ -z "$snell_services" ]; then
        echo -e "${RED}ShadowTLS 未安装${RESET}"
        return 1
    fi
    
    # 获取服务器IP
    local server_ip=$(get_server_ip)
    
    # 检查 SS 是否安装并获取配置
    if [ -f "$ss_service" ] && check_ssrust; then
        echo -e "\n${YELLOW}=== Shadowsocks + ShadowTLS 配置 ===${RESET}"
        local ss_listen_port=$(grep -oP '(?<=--listen ::0:)\d+' "$ss_service")
        local tls_domain=$(grep -oP '(?<=--tls )[^ ]+' "$ss_service")
        local password=$(grep -oP '(?<=--password )[^ ]+' "$ss_service")
        local ss_port=$(get_ssrust_port)
        local ssrust_password=$(get_ssrust_password)
        local ssrust_method=$(get_ssrust_method)
        
        if [ ! -z "$ss_listen_port" ] && [ ! -z "$tls_domain" ] && [ ! -z "$password" ]; then
            generate_ss_links "${server_ip}" "${ss_listen_port}" "${ssrust_password}" "${ssrust_method}" "${password}" "${tls_domain}" "${ss_port}"
        else
            echo -e "${RED}SS 配置文件不完整或已损坏${RESET}"
        fi
    fi
    
    # 检查 Snell 是否安装并获取配置
    if [ ! -z "$snell_services" ] && check_snell; then
        echo -e "\n${YELLOW}=== Snell + ShadowTLS 配置 ===${RESET}"
        
        # 获取所有用户配置
        local user_configs=$(get_all_snell_users)
        if [ ! -z "$user_configs" ]; then
            # 创建关联数组来存储已处理的端口
            declare -A processed_ports
            
            while IFS='|' read -r port psk; do
                if [ ! -z "$port" ] && [ -z "${processed_ports[$port]}" ]; then
                    processed_ports[$port]=1
                    
                    # 获取对应的 ShadowTLS 服务配置
                    local service_file="${SYSTEMD_DIR}/shadowtls-snell-${port}.service"
                    if [ -f "$service_file" ]; then
                        local exec_line=$(grep "ExecStart=" "$service_file")
                        local stls_port=$(echo "$exec_line" | grep -oP '(?<=--listen ::0:)\d+')
                        local stls_password=$(echo "$exec_line" | grep -oP '(?<=--password )[^ ]+')
                        local stls_domain=$(echo "$exec_line" | grep -oP '(?<=--tls )[^ ]+')
                        
                        if [ "$port" = "$(get_snell_port)" ]; then
                            echo -e "\n${GREEN}主用户配置：${RESET}"
                        else
                            echo -e "\n${GREEN}用户配置 (Snell 端口: ${port}):${RESET}"
                        fi
                        
                        if [ ! -z "$stls_port" ] && [ ! -z "$stls_password" ] && [ ! -z "$stls_domain" ]; then
                            echo -e "${YELLOW}Snell 配置：${RESET}"
                            echo -e "  - 端口：${port}"
                            echo -e "  - PSK：${psk}"
                            
                            echo -e "\n${YELLOW}ShadowTLS 配置：${RESET}"
                            echo -e "  - 监听端口：${stls_port}"
                            echo -e "  - 密码：${stls_password}"
                            echo -e "  - SNI：${stls_domain}"
                            echo -e "  - 版本：3"
                            
                            echo -e "\n${GREEN}Surge 配置：${RESET}"
                            echo -e "${YELLOW}Snell 版本：$(get_port_snell_version "$port")${RESET}"
                            print_snell_shadowtls_line "Snell + ShadowTLS" "$server_ip" "$stls_port" "$psk" \
                                "$stls_password" "$stls_domain" "$port"
                            
                            # 检查服务状态
                            local service_status=$(systemctl is-active "shadowtls-snell-${port}")
                            if [ "$service_status" = "active" ]; then
                                echo -e "\n${GREEN}服务状态：正在运行${RESET}"
                                # 检查端口占用情况
                                local port_usage=$(netstat -tuln | grep ":${stls_port}")
                                local port_count=$(echo "$port_usage" | wc -l)
                                if [ "$port_count" -gt 1 ]; then
                                    echo -e "${RED}警告：端口 ${stls_port} 被多个服务占用！${RESET}"
                                    echo -e "${YELLOW}端口占用情况：${RESET}"
                                    netstat -tuln | grep ":${stls_port}"
                                fi
                            else
                                echo -e "\n${RED}服务状态：未运行${RESET}"
                                echo -e "${YELLOW}请尝试以下命令重启服务：${RESET}"
                                echo -e "systemctl restart shadowtls-snell-${port}"
                            fi
                        else
                            echo -e "${RED}配置文件不完整或已损坏${RESET}"
                        fi
                    else
                        echo -e "\n${YELLOW}未找到用户 (端口: ${port}) 的 ShadowTLS 配置${RESET}"
                    fi
                fi
            done <<< "$user_configs"
        else
            echo -e "\n${YELLOW}未找到有效的 Snell 用户配置${RESET}"
        fi
    fi
    
    # 显示服务状态
    echo -e "\n${YELLOW}=== ShadowTLS 服务状态 ===${RESET}"
    
    # 显示 SS 服务状态
    if [ -f "$ss_service" ]; then
        echo -e "\n${YELLOW}SS 服务状态：${RESET}"
        systemctl status shadowtls-ss --no-pager
        
        # 如果服务未运行，显示重启命令
        if [ "$(systemctl is-active shadowtls-ss)" != "active" ]; then
            echo -e "\n${YELLOW}SS 服务未运行，请尝试以下命令重启：${RESET}"
            echo -e "systemctl restart shadowtls-ss"
        fi
    fi
    
    # 显示所有 Snell 服务状态（避免重复显示）
    if [ ! -z "$snell_services" ]; then
        echo -e "\n${YELLOW}Snell 服务状态：${RESET}"
        declare -A shown_services
        while IFS= read -r service_file; do
            local port=$(basename "$service_file" | sed 's/shadowtls-snell-\([0-9]*\)\.service/\1/')
            if [ -z "${shown_services[$port]}" ]; then
                shown_services[$port]=1
                echo -e "\n${GREEN}Snell 端口 ${port} 的 ShadowTLS 服务状态：${RESET}"
                systemctl status "shadowtls-snell-${port}" --no-pager
                
                # 如果服务未运行，显示重启命令
                if [ "$(systemctl is-active shadowtls-snell-${port})" != "active" ]; then
                    echo -e "\n${YELLOW}服务未运行，请尝试以下命令重启：${RESET}"
                    echo -e "systemctl restart shadowtls-snell-${port}"
                fi
            fi
        done <<< "$snell_services"
    fi
}

# 新增 ShadowTLS 配置
add_shadowtls_config() {
    echo -e "${CYAN}新增 ShadowTLS 配置...${RESET}"
    
    # 检测已安装的协议
    local has_ss=false
    local has_snell=false
    local has_ss_stls=false
    
    if check_ssrust; then
        has_ss=true
        echo -e "${GREEN}检测到已安装 Shadowsocks Rust${RESET}"
        if [ -f "${SYSTEMD_DIR}/shadowtls-ss.service" ]; then
            has_ss_stls=true
            echo -e "${YELLOW}已存在 Shadowsocks 的 ShadowTLS 配置${RESET}"
        fi
    fi
    
    if check_snell_config; then
        has_snell=true
        echo -e "${GREEN}检测到已安装 Snell${RESET}"
    elif check_snell; then
        echo -e "${YELLOW}检测到 Snell 二进制，但主配置不可用，暂不能为 Snell 新增 ShadowTLS 配置${RESET}"
    fi
    
    if ! $has_ss && ! $has_snell; then
        echo -e "${RED}未检测到 Shadowsocks Rust 或 Snell，请先安装其中一个${RESET}"
        return 1
    fi
    
    # 让用户选择要为哪个协议新增 ShadowTLS 配置
    while true; do
        echo -e "\n${YELLOW}请选择要新增配置的协议：${RESET}"
        if $has_ss && ! $has_ss_stls; then
            echo -e "1. 为 Shadowsocks 新增 ShadowTLS 配置"
        fi
        if $has_snell; then
            echo -e "2. 为 Snell 新增 ShadowTLS 配置"
        fi
        echo -e "0. 返回"
        
        read -rp "请选择: " choice
        
        case "$choice" in
            0)
                return 0
                ;;
            1)
                if ! $has_ss || $has_ss_stls; then
                    echo -e "${RED}无效的选择${RESET}"
                    continue
                fi
                # 获取必要的配置信息
                password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
                read -rp "请输入 TLS 伪装域名 (直接回车默认为 www.microsoft.com): " tls_domain
                if [ -z "$tls_domain" ]; then
                    tls_domain="www.microsoft.com"
                fi
                prompt_wildcard_sni
                
                # 配置 SS 的 ShadowTLS
                while true; do
                    read -rp "请输入 ShadowTLS 监听端口 (1-65535，直接回车随机生成): " ss_listen_port
                    
                    # 验证并获取可用端口
                    ss_listen_port=$(get_available_port "$ss_listen_port")
                    if [ $? -eq 0 ]; then
                        break
                    fi
                    echo -e "${YELLOW}请重新输入端口${RESET}"
                done
                
                # 创建 SS 的 ShadowTLS 服务
                local ss_port=$(get_ssrust_port)
                create_shadowtls_service "ss" "$ss_port" "$ss_listen_port" "$tls_domain" "$password"
                open_port "$ss_listen_port"
                systemctl start shadowtls-ss
                systemctl enable shadowtls-ss
                
                # 显示配置信息
                local server_ip=$(get_server_ip)
                local ssrust_password=$(get_ssrust_password)
                local ssrust_method=$(get_ssrust_method)
                generate_ss_links "${server_ip}" "${ss_listen_port}" "${ssrust_password}" "${ssrust_method}" "${password}" "${tls_domain}" "${ss_port}"
                break
                ;;
            2)
                if ! $has_snell; then
                    echo -e "${RED}无效的选择${RESET}"
                    continue
                fi
                
                # 获取必要的配置信息
                password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
                read -rp "请输入 TLS 伪装域名 (直接回车默认为 www.microsoft.com): " tls_domain
                if [ -z "$tls_domain" ]; then
                    tls_domain="www.microsoft.com"
                fi
                prompt_wildcard_sni
                
                # 获取所有 Snell 用户配置
                local user_configs=$(get_all_snell_users)
                if [ -z "$user_configs" ]; then
                    echo -e "${RED}未找到有效的 Snell 用户配置${RESET}"
                    return 1
                fi
                
                # 显示所有未配置的 Snell 端口
                echo -e "\n${YELLOW}未配置 ShadowTLS 的 Snell 端口列表：${RESET}"
                local port_list=()
                local port_count=0
                while IFS='|' read -r port psk; do
                    if [ ! -z "$port" ] && [ ! -f "${SYSTEMD_DIR}/shadowtls-snell-${port}.service" ]; then
                        port_list+=("$port")
                        if [ "$port" = "$(get_snell_port)" ]; then
                            echo -e "${GREEN}$((++port_count)). ${port} (主用户)${RESET}"
                        else
                            echo -e "${GREEN}$((++port_count)). ${port}${RESET}"
                        fi
                    fi
                done <<< "$user_configs"
                
                if [ ${#port_list[@]} -eq 0 ]; then
                    echo -e "${YELLOW}所有 Snell 端口都已配置 ShadowTLS${RESET}"
                    return 0
                fi
                
                # 让用户选择要配置的端口
                echo -e "\n${YELLOW}请选择要配置的端口：${RESET}"
                echo -e "1-${#port_list[@]}. 选择单个端口"
                echo -e "0. 为所有未配置端口配置 ShadowTLS"
                
                read -rp "请选择: " port_choice
                
                if [ "$port_choice" = "0" ]; then
                    # 为所有未配置端口配置 ShadowTLS
                    for port in "${port_list[@]}"; do
                        echo -e "\n${YELLOW}为 Snell 端口 ${port} 配置 ShadowTLS${RESET}"
                        while true; do
                            read -rp "请输入 ShadowTLS 监听端口 (1-65535，直接回车随机生成): " stls_port
                            
                            # 验证并获取可用端口
                            stls_port=$(get_available_port "$stls_port")
                            if [ $? -eq 0 ]; then
                                break
                            fi
                            echo -e "${YELLOW}请重新输入端口${RESET}"
                        done
                        
                        restrict_snell_to_loopback "$port" || return 1

                        # 创建服务文件
                        create_shadowtls_service "snell" "$port" "$stls_port" "$tls_domain" "$password"
                        open_port "$stls_port"
                        systemctl start "shadowtls-snell-${port}"
                        systemctl enable "shadowtls-snell-${port}"
                        
                        # 显示配置信息
                        local server_ip=$(get_server_ip)
                        local psk=$(get_snell_config "$port")
                        generate_snell_links "${server_ip}" "${stls_port}" "${psk}" "${password}" "${tls_domain}" "${port}"
                    done
                elif [[ "$port_choice" =~ ^[0-9]+$ ]] && [ "$port_choice" -ge 1 ] && [ "$port_choice" -le ${#port_list[@]} ]; then
                    # 为选中的端口配置 ShadowTLS
                    local selected_port="${port_list[$((port_choice-1))]}"
                    echo -e "\n${YELLOW}为 Snell 端口 ${selected_port} 配置 ShadowTLS${RESET}"
                    while true; do
                        read -rp "请输入 ShadowTLS 监听端口 (1-65535，直接回车随机生成): " stls_port
                        
                        # 验证并获取可用端口
                        stls_port=$(get_available_port "$stls_port")
                        if [ $? -eq 0 ]; then
                            break
                        fi
                        echo -e "${YELLOW}请重新输入端口${RESET}"
                    done
                    
                    restrict_snell_to_loopback "$selected_port" || return 1

                    # 创建服务文件
                    create_shadowtls_service "snell" "$selected_port" "$stls_port" "$tls_domain" "$password"
                    open_port "$stls_port"
                    systemctl start "shadowtls-snell-${selected_port}"
                    systemctl enable "shadowtls-snell-${selected_port}"
                    
                    # 显示配置信息
                    local server_ip=$(get_server_ip)
                    local psk=$(get_snell_config "$selected_port")
                    generate_snell_links "${server_ip}" "${stls_port}" "${psk}" "${password}" "${tls_domain}" "${selected_port}"
                else
                    echo -e "${RED}无效的选择${RESET}"
                    continue
                fi
                break
                ;;
            *)
                echo -e "${RED}无效的选择${RESET}"
                ;;
        esac
    done
    
    # 重新加载 systemd 配置
    systemctl daemon-reload
    echo -e "\n${GREEN}新增配置完成${RESET}"
}

# 重启 ShadowTLS 服务
restart_shadowtls_services() {
    echo -e "${CYAN}重启 ShadowTLS 服务...${RESET}"
    
    local has_services=false
    
    # 重启 SS 服务
    if [ -f "${SYSTEMD_DIR}/shadowtls-ss.service" ]; then
        has_services=true
        echo -e "\n${YELLOW}重启 Shadowsocks 的 ShadowTLS 服务...${RESET}"
        systemctl restart shadowtls-ss
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}Shadowsocks ShadowTLS 服务重启成功${RESET}"
        else
            echo -e "${RED}Shadowsocks ShadowTLS 服务重启失败${RESET}"
        fi
    fi
    
    # 重启所有 Snell 服务
    local snell_services=$(find /etc/systemd/system -name "shadowtls-snell-*.service" 2>/dev/null)
    if [ ! -z "$snell_services" ]; then
        has_services=true
        echo -e "\n${YELLOW}重启 Snell 的 ShadowTLS 服务...${RESET}"
        while IFS= read -r service_file; do
            local port=$(basename "$service_file" | sed 's/shadowtls-snell-\([0-9]*\)\.service/\1/')
            echo -e "重启端口 ${port} 的服务..."
            systemctl restart "shadowtls-snell-${port}"
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}端口 ${port} 的服务重启成功${RESET}"
            else
                echo -e "${RED}端口 ${port} 的服务重启失败${RESET}"
            fi
        done <<< "$snell_services"
    fi
    
    if ! $has_services; then
        echo -e "${RED}未找到任何 ShadowTLS 服务${RESET}"
        return 1
    fi
    
    echo -e "\n${GREEN}所有服务重启完成${RESET}"
    
    # 显示所有服务状态
    echo -e "\n${YELLOW}服务状态：${RESET}"
    if [ -f "${SYSTEMD_DIR}/shadowtls-ss.service" ]; then
        echo -e "\n${CYAN}Shadowsocks ShadowTLS 服务状态：${RESET}"
        systemctl status shadowtls-ss --no-pager
    fi
    
    if [ ! -z "$snell_services" ]; then
        while IFS= read -r service_file; do
            local port=$(basename "$service_file" | sed 's/shadowtls-snell-\([0-9]*\)\.service/\1/')
            echo -e "\n${CYAN}Snell 端口 ${port} 的 ShadowTLS 服务状态：${RESET}"
            systemctl status "shadowtls-snell-${port}" --no-pager
        done <<< "$snell_services"
    fi
}

# 主菜单
main_menu() {
    while true; do
        echo -e "\n${CYAN}ShadowTLS 管理菜单${RESET}"
        echo -e "${YELLOW}1. 安装 ShadowTLS${RESET}"
        echo -e "${YELLOW}2. 卸载 ShadowTLS${RESET}"
        echo -e "${YELLOW}3. 查看配置${RESET}"
        echo -e "${YELLOW}4. 新增配置${RESET}"
        echo -e "${YELLOW}5. 重启服务${RESET}"
        echo -e "${YELLOW}6. 返回上级菜单${RESET}"
        echo -e "${YELLOW}0. 退出${RESET}"
        
        if ! read -rp "请选择操作 [0-6]: " choice; then
            echo
            echo -e "${YELLOW}未读取到输入，已退出 ShadowTLS 菜单。${RESET}"
            return 0
        fi
        
        case "$choice" in
            1)
                install_shadowtls
                ;;
            2)
                uninstall_shadowtls
                ;;
            3)
                view_config
                ;;
            4)
                add_shadowtls_config
                ;;
            5)
                restart_shadowtls_services
                ;;
            6)
                return 0
                ;;
            0)
                exit 0
                ;;
            *)
                echo -e "${RED}无效的选择${RESET}"
                ;;
        esac
    done
}

# 检查root权限
check_root

# 如果直接运行此脚本，则显示主菜单
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_menu
fi
