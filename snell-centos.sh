#!/bin/bash
# =========================================
# 作者: jinqians
# 日期: 2025年5月
# 网站：jinqians.com
# 描述: 这个脚本用于在 CentOS/Red Hat/Fedora 系统上安装和管理 Snell 代理
# =========================================

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
RESET='\033[0m'

#当前版本号
current_version="3.2"

# 全局变量：选择的 Snell 版本
SNELL_VERSION_CHOICE=""

# Snell v6 加密模式：default / unshaped / unsafe-raw（客户端必须与服务端一致）
SNELL_MODE="default"

# 抓取失败时的兜底版本号
SNELL_V4_FALLBACK="v4.1.1"
SNELL_V5_FALLBACK="v5.0.1"
SNELL_V6_FALLBACK="v6.0.0rc2"
SNELL_VERSION=""

# 定义系统路径
INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/usr/lib/systemd/system"
SNELL_CONF_DIR="/etc/snell"
SNELL_CONF_FILE="${SNELL_CONF_DIR}/users/snell-main.conf"
SYSTEMD_SERVICE_FILE="${SYSTEMD_DIR}/snell.service"

# 检查是否以 root 权限运行
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请以 root 权限运行此脚本${RESET}"
        exit 1
    fi
}

# 检查系统类型
check_system() {
    if [[ -f /etc/redhat-release ]]; then
        echo -e "${GREEN}检测到 CentOS/Red Hat 系统${RESET}"
    else
        echo -e "${RED}错误: 此脚本仅适用于 CentOS/Red Hat 系统${RESET}"
        exit 1
    fi
}

# 检查 curl 是否安装
check_curl() {
    if ! command -v curl &> /dev/null; then
        echo -e "${YELLOW}未检测到 curl，正在安装...${RESET}"
        if [ -x "$(command -v yum)" ]; then
            yum install -y curl
        elif [ -x "$(command -v apt)" ]; then
            apt update && apt install -y curl
        else
            echo -e "${RED}未支持的包管理器，无法安装 curl。请手动安装 curl。${RESET}"
            exit 1
        fi
    fi
}

# 安装依赖
install_dependencies() {
    echo -e "${CYAN}正在安装依赖...${RESET}"
    yum -y update
    yum -y install curl wget unzip net-tools systemd
}

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

# 获取 Snell 最新版本（根据选择的版本）
get_latest_snell_version() {
    if [ "$SNELL_VERSION_CHOICE" = "v6" ]; then
        SNELL_VERSION=$(get_latest_snell_v6_version)
    elif [ "$SNELL_VERSION_CHOICE" = "v5" ]; then
        SNELL_VERSION=$(get_latest_snell_v5_version)
    else
        SNELL_VERSION=$(get_latest_snell_v4_version)
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

    local tmp_conf="${conf_file}.tmp"
    {
        grep -Ev '^[[:space:]]*(ipv6|mode|dns-ip-preference)[[:space:]]*=' "$conf_file"
        if [ "$version_choice" = "v6" ]; then
            echo "mode = ${SNELL_MODE}"
            if [ "$ipv6_enable" = "false" ]; then
                echo "dns-ip-preference = ipv4-only"
            else
                echo "dns-ip-preference = default"
            fi
        else
            echo "ipv6 = ${ipv6_enable}"
        fi
    } > "$tmp_conf" && mv "$tmp_conf" "$conf_file"
}

# 读取已安装 v6 服务端使用的 mode（读不到时回落到默认值）
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

# 获取 Snell 下载 URL
get_snell_download_url() {
    local arch=$(uname -m)

    # v6 暂不提供 armv7l 构建
    if [ "$SNELL_VERSION_CHOICE" = "v6" ] && { [ "$arch" = "armv7l" ] || [ "$arch" = "armv7" ]; }; then
        echo -e "${RED}Snell v6 暂不支持 armv7l 架构${RESET}" >&2
        exit 1
    fi

    case ${arch} in
        "x86_64"|"amd64")
            echo "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-amd64.zip"
            ;;
        "i386"|"i686")
            echo "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-i386.zip"
            ;;
        "aarch64"|"arm64")
            echo "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-aarch64.zip"
            ;;
        "armv7l"|"armv7")
            echo "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-armv7l.zip"
            ;;
        *)
            echo -e "${RED}不支持的架构: ${arch}${RESET}" >&2
            exit 1
            ;;
    esac
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
        # v6 版本：v6 协议（已移除 QUIC 模式）
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 6, mode = $(get_snell_mode), reuse = true, tfo = true${RESET}"
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

# 获取用户输入的 DNS 服务器
get_dns() {
    read -rp "请输入 DNS 服务器地址 (直接回车使用系统DNS): " custom_dns
    if [ -z "$custom_dns" ]; then
        DNS="1.1.1.1,8.8.8.8"
        echo -e "${GREEN}使用默认 DNS 服务器: $DNS${RESET}"
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

    if [ -f "/etc/sysconfig/nftables.conf" ]; then
        nft list ruleset > /etc/sysconfig/nftables.conf 2>/dev/null || true
        systemctl enable nftables >/dev/null 2>&1 || true
        echo -e "${GREEN}nftables 规则已保存${RESET}"
    elif [ -f "/etc/nftables.conf" ]; then
        nft list ruleset > /etc/nftables.conf 2>/dev/null || true
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

    echo -e "${YELLOW}检测到 nftables，正在配置...${RESET}"

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
    echo -e "${GREEN}nftables 配置完成${RESET}"
}

# 开放端口
open_port() {
    local PORT=$1
    local firewalld_active=false
    echo -e "${CYAN}正在配置防火墙...${RESET}"
    
    # 检查 firewalld
    if command -v firewall-cmd &> /dev/null && systemctl is-active firewalld &>/dev/null; then
        firewalld_active=true
        echo -e "${YELLOW}检测到 firewalld 正在运行，正在配置...${RESET}"
        firewall-cmd --permanent --add-port="$PORT"/tcp
        firewall-cmd --permanent --add-port="$PORT"/udp
        firewall-cmd --reload
        echo -e "${GREEN}firewalld 配置完成${RESET}"
    fi

    if [ "$firewalld_active" = false ]; then
        open_nftables_port "$PORT"
    fi
    
    # 检查 iptables
    if command -v iptables &> /dev/null; then
        echo -e "${YELLOW}检测到 iptables，正在配置...${RESET}"
        # 检查规则是否已存在
        if ! iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT &>/dev/null; then
            iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
        fi
        if ! iptables -C INPUT -p udp --dport "$PORT" -j ACCEPT &>/dev/null; then
            iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT
        fi
        
        # 保存规则
        if command -v iptables-save &> /dev/null; then
            iptables-save > /etc/sysconfig/iptables
            echo -e "${GREEN}iptables 规则已保存${RESET}"
        fi
        echo -e "${GREEN}iptables 配置完成${RESET}"
    fi
    
    # 检查端口是否已开放
    if command -v netstat &> /dev/null; then
        echo -e "\n${YELLOW}端口状态检查:${RESET}"
        netstat -tuln | grep "$PORT"
    fi
    
    echo -e "${GREEN}防火墙配置完成${RESET}"
}

# 安装 Snell
install_snell() {
    echo -e "${CYAN}正在安装 Snell${RESET}"

    # 检查系统
    check_root
    check_system

    # 选择 Snell 版本
    select_snell_version

    # 安装依赖
    install_dependencies

    # 获取最新版本
    get_latest_snell_version
    ARCH=$(uname -m)
    
    # 确定下载链接
    SNELL_URL=$(get_snell_download_url "$SNELL_VERSION_CHOICE")

    echo -e "${CYAN}正在下载 Snell ${SNELL_VERSION_CHOICE} (${SNELL_VERSION})...${RESET}"
    echo -e "${YELLOW}下载链接: ${SNELL_URL}${RESET}"

    # 创建安装目录
    mkdir -p ${INSTALL_DIR}
    mkdir -p ${SNELL_CONF_DIR}/users

    # 下载并解压
    wget ${SNELL_URL} -O snell-server.zip
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载 Snell ${SNELL_VERSION_CHOICE} 失败。${RESET}"
        exit 1
    fi

    unzip -o snell-server.zip -d ${INSTALL_DIR}
    if [ $? -ne 0 ]; then
        echo -e "${RED}解压缩 Snell 失败。${RESET}"
        exit 1
    fi

    rm snell-server.zip
    chmod +x ${INSTALL_DIR}/snell-server

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
if curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/refs/heads/main/snell-centos.sh -o "$TMP_SCRIPT"; then
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

    # 生成配置
    get_user_port
    get_dns
    # 生成 PSK
    PSK=$(openssl rand -base64 16)
    # 确保 PSK 不为空
    if [ -z "$PSK" ]; then
        echo -e "${RED}PSK 生成失败${RESET}"
        exit 1
    fi

    # 创建配置文件（v6 使用 mode / dns-ip-preference，ipv6 参数在 v6 已废弃）
    {
        echo "[snell-server]"
        echo "listen = ::0:${PORT}"
        echo "psk = ${PSK}"
        if [ "$SNELL_VERSION_CHOICE" = "v6" ]; then
            echo "mode = ${SNELL_MODE}"
            echo "dns-ip-preference = default"
        else
            echo "ipv6 = true"
        fi
        echo "dns = ${DNS}"
    } > ${SNELL_CONF_FILE}

    # 验证配置文件
    if [ ! -f "${SNELL_CONF_FILE}" ]; then
        echo -e "${RED}配置文件创建失败${RESET}"
        exit 1
    fi

    # 验证 PSK 是否正确写入
    if ! grep -q "psk = ${PSK}" "${SNELL_CONF_FILE}"; then
        echo -e "${RED}PSK 写入配置文件失败${RESET}"
        exit 1
    fi

    echo -e "${GREEN}PSK 已生成并写入配置文件${RESET}"

    # 创建 systemd 服务
    cat > ${SYSTEMD_SERVICE_FILE} << EOF
[Unit]
Description=Snell Proxy Service
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/snell-server -c ${SNELL_CONF_FILE}
Restart=on-failure
RestartSec=5
LimitNOFILE=16384
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

    # 创建 systemd preset 文件
    cat > /usr/lib/systemd/system-preset/90-snell.preset << EOF
enable snell.service
EOF

    # 设置权限
    chmod 644 ${SYSTEMD_SERVICE_FILE}
    chmod 644 /usr/lib/systemd/system-preset/90-snell.preset
    chmod -R 755 ${SNELL_CONF_DIR}
    chmod 755 ${INSTALL_DIR}/snell-server

    # 重载并启动服务
    systemctl daemon-reload
    systemctl preset snell
    systemctl enable snell
    systemctl start snell

    # 检查服务状态
    if ! systemctl is-active snell &>/dev/null; then
        echo -e "${RED}Snell 服务启动失败${RESET}"
        echo -e "${YELLOW}请检查服务状态：systemctl status snell${RESET}"
        echo -e "${YELLOW}请检查日志：journalctl -u snell -n 50${RESET}"
        exit 1
    fi

    # 开放端口
    open_port "$PORT"

    # 显示安装信息
    show_information
}

# 显示安装信息
show_information() {
    echo -e "\n${BLUE}============================================${RESET}"
    echo -e "${GREEN}Snell 安装成功!${RESET}"
    echo -e "${BLUE}============================================${RESET}"
    
    # 检测当前安装的 Snell 版本
    local installed_version=$(detect_installed_snell_version)
    if [ "$installed_version" != "unknown" ]; then
        echo -e "${YELLOW}当前安装版本: Snell ${installed_version}${RESET}"
    fi
    
    # 读取配置文件
    if [ -f "${SNELL_CONF_FILE}" ]; then
        # 直接从配置文件读取信息
        PORT=$(grep -oP 'listen\s*=\s*::0:\K\d+' ${SNELL_CONF_FILE})
        PSK=$(grep -oP 'psk\s*=\s*\K.*' ${SNELL_CONF_FILE})
    else
        echo -e "${RED}错误: 配置文件不存在${RESET}"
        exit 1
    fi
    
    IPV4_ADDR=$(curl -s4 https://api.ipify.org)
    IPV6_ADDR=$(curl -s6 https://api64.ipify.org)
    
    echo -e "${YELLOW}服务器信息:${RESET}"
    if [ ! -z "$IPV4_ADDR" ]; then
        IP_COUNTRY_IPV4=$(curl -s http://ipinfo.io/${IPV4_ADDR}/country)
        echo -e "${YELLOW}IPv4 地址: ${RESET}${IPV4_ADDR} ${GREEN}所在国家: ${RESET}${IP_COUNTRY_IPV4}"
    fi
    if [ ! -z "$IPV6_ADDR" ]; then
        IP_COUNTRY_IPV6=$(curl -s https://ipapi.co/${IPV6_ADDR}/country/)
        echo -e "${YELLOW}IPv6 地址: ${RESET}${IPV6_ADDR} ${GREEN}所在国家: ${RESET}${IP_COUNTRY_IPV6}"
    fi
    echo -e "${YELLOW}服务器端口: ${RESET}${PORT}"
    echo -e "${YELLOW}PSK 密钥: ${RESET}${PSK}"
    echo -e "${YELLOW}版本: ${RESET}${SNELL_VERSION}"
    echo -e "${YELLOW}服务状态: ${RESET}$(systemctl is-active snell)"
    
    # 显示 Surge 配置格式
    echo -e "\n${GREEN}Surge 配置格式:${RESET}"
    local installed_version=$(detect_installed_snell_version)
    if [ ! -z "$IPV4_ADDR" ]; then
        generate_surge_config "$IPV4_ADDR" "$PORT" "$PSK" "$installed_version" "$IP_COUNTRY_IPV4" "$installed_version"
    fi
    if [ ! -z "$IPV6_ADDR" ]; then
        generate_surge_config "$IPV6_ADDR" "$PORT" "$PSK" "$installed_version" "$IP_COUNTRY_IPV6" "$installed_version"
    fi
    
    echo -e "\n${GREEN}使用以下命令管理服务:${RESET}"
    echo -e "  ${BLUE}systemctl start snell${RESET} - 启动服务"
    echo -e "  ${BLUE}systemctl stop snell${RESET} - 停止服务"
    echo -e "  ${BLUE}systemctl restart snell${RESET} - 重启服务"
    echo -e "  ${BLUE}systemctl status snell${RESET} - 查看服务状态"
    echo -e "  ${BLUE}journalctl -u snell -f${RESET} - 实时查看日志"
    
    echo -e "\n${GREEN}配置文件位置:${RESET} ${BLUE}${SNELL_CONF_FILE}${RESET}"
    echo -e "${BLUE}============================================${RESET}"
}

# 卸载 Snell
uninstall_snell() {
    echo -e "${CYAN}正在卸载 Snell${RESET}"

    # 停止并禁用服务
    systemctl stop snell
    systemctl disable snell

    # 删除服务文件
    rm -f ${SYSTEMD_SERVICE_FILE}

    # 删除安装目录
    rm -f ${INSTALL_DIR}/snell-server
    rm -rf ${SNELL_CONF_DIR}
    
    # 删除软链接
    if [ -L "/usr/bin/snell" ]; then
        rm -f /usr/bin/snell
        echo -e "${GREEN}已删除 snell 命令软链接${RESET}"
    fi
    
    # 获取端口号
    if [ -f "${SNELL_CONF_FILE}" ]; then
        PORT=$(grep "listen" ${SNELL_CONF_FILE} | sed 's/.*://' | tr -d ' ')
        # 关闭防火墙端口
        if command -v firewall-cmd &> /dev/null; then
            firewall-cmd --permanent --remove-port="$PORT"/tcp
            firewall-cmd --permanent --remove-port="$PORT"/udp
            firewall-cmd --reload
        fi
        if command -v iptables &> /dev/null; then
            iptables -D INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null
            iptables -D INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null
            if command -v iptables-save &> /dev/null; then
                iptables-save > /etc/sysconfig/iptables
            fi
        fi
    fi
    
    # 重载 systemd 配置
    systemctl daemon-reload
    
    echo -e "${GREEN}Snell 已成功卸载${RESET}"
}

# 重启 Snell
restart_snell() {
    echo -e "${YELLOW}正在重启 Snell 服务...${RESET}"
    systemctl restart snell
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Snell 服务已成功重启。${RESET}"
    else
        echo -e "${RED}重启 Snell 服务失败。${RESET}"
    fi
}

# 检查服务状态并显示
check_and_show_status() {
    echo -e "\n${CYAN}=============== 服务状态检查 ===============${RESET}"
    
    if systemctl is-active snell &>/dev/null; then
        echo -e "${GREEN}Snell 服务状态: 运行中${RESET}"
    
    else
        echo -e "${RED}Snell 服务状态: 未运行${RESET}"
    fi
    
    echo -e "${CYAN}============================================${RESET}\n"
}

# === 新增：备份和还原配置函数 ===
# 备份 Snell 配置
backup_snell_config() {
    local backup_dir="/etc/snell/backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    cp -a /etc/snell/users/*.conf "$backup_dir"/ 2>/dev/null
    echo "$backup_dir"
}

# 恢复 Snell 配置
restore_snell_config() {
    local backup_dir="$1"
    if [ -d "$backup_dir" ]; then
        cp -a "$backup_dir"/*.conf /etc/snell/users/
        echo -e "${GREEN}配置已从备份恢复。${RESET}"
    else
        echo -e "${RED}未找到备份目录，无法恢复配置。${RESET}"
    fi
}

# 获取当前 Snell 版本
get_current_snell_version() {
    if [ -f "${INSTALL_DIR}/snell-server" ]; then
        local current_installed_version
        current_installed_version=$(detect_installed_snell_version)
        if [ "$current_installed_version" = "v6" ] || [ "$current_installed_version" = "v5" ]; then
            CURRENT_VERSION=$(${INSTALL_DIR}/snell-server --v 2>&1 | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+[a-z0-9]*')
            if [ -z "$CURRENT_VERSION" ]; then
                if [ "$current_installed_version" = "v6" ]; then
                    CURRENT_VERSION="$SNELL_V6_FALLBACK"
                else
                    CURRENT_VERSION="$SNELL_V5_FALLBACK"
                fi
            fi
        else
            CURRENT_VERSION=$(${INSTALL_DIR}/snell-server --v 2>&1 | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+')
            if [ -z "$CURRENT_VERSION" ]; then
                echo -e "${RED}无法获取当前 Snell 版本。${RESET}"
                return 1
            fi
        fi
    else
        echo -e "${RED}错误: Snell 未安装${RESET}"
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

# 只更新 Snell 二进制文件，不覆盖配置
update_snell_binary() {
    echo -e "${CYAN}=============== Snell 更新 ===============${RESET}"
    echo -e "${YELLOW}注意：这是更新操作，不是重新安装${RESET}"
    echo -e "${GREEN}✓ 所有现有配置将被保留${RESET}"
    echo -e "${GREEN}✓ 端口、密码、用户配置都不会改变${RESET}"
    echo -e "${GREEN}✓ 服务会自动重启${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    
    echo -e "${CYAN}正在备份当前配置...${RESET}"
    local backup_dir
    backup_dir=$(backup_snell_config)
    echo -e "${GREEN}配置已备份到: $backup_dir${RESET}"

    echo -e "${CYAN}正在更新 Snell 二进制文件...${RESET}"
    
    # 获取最新版本信息（版本已在 check_snell_update 中确定）
    get_latest_snell_version
    ARCH=$(uname -m)
    SNELL_URL=$(get_snell_download_url "$SNELL_VERSION_CHOICE")

    echo -e "${CYAN}正在下载 Snell ${SNELL_VERSION_CHOICE} (${SNELL_VERSION})...${RESET}"
    
    # v4/v5/v6 均使用 zip 格式，统一处理
    wget ${SNELL_URL} -O snell-server.zip
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载 Snell ${SNELL_VERSION_CHOICE} 失败。${RESET}"
        restore_snell_config "$backup_dir"
        exit 1
    fi

    echo -e "${CYAN}正在替换 Snell 二进制文件...${RESET}"
    unzip -o snell-server.zip -d ${INSTALL_DIR}
    if [ $? -ne 0 ]; then
        echo -e "${RED}解压缩 Snell 失败。${RESET}"
        restore_snell_config "$backup_dir"
        exit 1
    fi

    rm snell-server.zip
    chmod +x ${INSTALL_DIR}/snell-server

    # 版本切换后同步配置参数（如 v4/v5 升级到 v6 需要 mode / dns-ip-preference）
    echo -e "${CYAN}正在同步配置文件参数...${RESET}"
    for conf_file in "${SNELL_CONF_DIR}/users"/*.conf; do
        [ -f "$conf_file" ] || continue
        migrate_snell_conf_for_version "$conf_file" "$SNELL_VERSION_CHOICE"
    done

    echo -e "${CYAN}正在重启 Snell 服务...${RESET}"
    # 重启主服务
    systemctl restart snell
    if [ $? -ne 0 ]; then
        echo -e "${RED}主服务重启失败，尝试恢复配置...${RESET}"
        restore_snell_config "$backup_dir"
        systemctl restart snell
    fi

    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}✅ Snell 更新完成！${RESET}"
    echo -e "${GREEN}✓ 版本已更新到: ${SNELL_VERSION_CHOICE} (${SNELL_VERSION})${RESET}"
    echo -e "${GREEN}✓ 所有配置已保留${RESET}"
    echo -e "${GREEN}✓ 服务已重启${RESET}"
    echo -e "${YELLOW}配置备份目录: $backup_dir${RESET}"
    echo -e "${CYAN}============================================${RESET}"
}

# 检查 Snell 更新
check_snell_update() {
    echo -e "\n${CYAN}=============== 检查 Snell 更新 ===============${RESET}"
    
    # 检测当前安装的 Snell 版本
    local current_installed_version=$(detect_installed_snell_version)
    if [ "$current_installed_version" = "unknown" ]; then
        echo -e "${RED}无法检测当前 Snell 版本${RESET}"
        return 1
    fi
    
    echo -e "${YELLOW}当前安装版本: Snell ${current_installed_version}${RESET}"
    
    # 根据当前版本确定更新策略
    if [ "$current_installed_version" = "v4" ]; then
        # v4 用户：可升级到 v5 或 v6，或继续检查 v4 更新
        echo -e "\n${CYAN}检测到您当前使用的是 Snell v4，请选择目标版本：${RESET}"
        echo -e "${YELLOW}注意：v5/v6 为新版本，升级前请确认客户端支持${RESET}"
        echo -e "${GREEN}1.${RESET} 升级到 Snell v5"
        echo -e "${GREEN}2.${RESET} 升级到 Snell v6 (RC)"
        echo -e "${GREEN}3.${RESET} 继续使用 Snell v4（检查 v4 更新）"
        echo -e "${GREEN}4.${RESET} 取消更新"

        while true; do
            read -rp "请选择 [1-4]: " upgrade_choice
            case "$upgrade_choice" in
                1)
                    SNELL_VERSION_CHOICE="v5"
                    echo -e "${GREEN}已选择升级到 Snell v5${RESET}"
                    break
                    ;;
                2)
                    SNELL_VERSION_CHOICE="v6"
                    echo -e "${GREEN}已选择升级到 Snell v6 (RC)${RESET}"
                    echo -e "${YELLOW}注意：v6 仍为预发布版本，协议可能存在不兼容更新，且已移除 QUIC 代理模式与 obfs${RESET}"
                    break
                    ;;
                3)
                    SNELL_VERSION_CHOICE="v4"
                    echo -e "${GREEN}已选择继续使用 Snell v4${RESET}"
                    break
                    ;;
                4)
                    echo -e "${CYAN}已取消更新${RESET}"
                    return 0
                    ;;
                *)
                    echo -e "${RED}请输入正确的选项 [1-4]${RESET}"
                    ;;
            esac
        done
    elif [ "$current_installed_version" = "v5" ]; then
        # v5 用户：可升级到 v6 或继续检查 v5 更新
        echo -e "\n${CYAN}检测到您当前使用的是 Snell v5，请选择目标版本：${RESET}"
        echo -e "${GREEN}1.${RESET} 升级到 Snell v6 (RC)"
        echo -e "${GREEN}2.${RESET} 继续使用 Snell v5（检查 v5 更新）"
        echo -e "${GREEN}3.${RESET} 取消更新"

        while true; do
            read -rp "请选择 [1-3]: " upgrade_choice
            case "$upgrade_choice" in
                1)
                    SNELL_VERSION_CHOICE="v6"
                    echo -e "${GREEN}已选择升级到 Snell v6 (RC)${RESET}"
                    echo -e "${YELLOW}注意：v6 仍为预发布版本，协议可能存在不兼容更新，且已移除 QUIC 代理模式与 obfs${RESET}"
                    break
                    ;;
                2)
                    SNELL_VERSION_CHOICE="v5"
                    echo -e "${GREEN}已选择继续使用 Snell v5${RESET}"
                    break
                    ;;
                3)
                    echo -e "${CYAN}已取消更新${RESET}"
                    return 0
                    ;;
                *)
                    echo -e "${RED}请输入正确的选项 [1-3]${RESET}"
                    ;;
            esac
        done
    else
        # v6 用户：直接检查 v6 更新
        SNELL_VERSION_CHOICE="v6"
        echo -e "${GREEN}当前为 Snell v6，将检查 v6 更新${RESET}"
    fi
    
    # 获取最新版本信息
    get_latest_snell_version
    get_current_snell_version
    if [ $? -ne 0 ]; then
        return 1
    fi

    echo -e "${YELLOW}当前 Snell 版本: ${CURRENT_VERSION}${RESET}"
    echo -e "${YELLOW}最新 Snell 版本: ${SNELL_VERSION}${RESET}"

    # 检查是否需要更新
    if ! version_greater_equal "$CURRENT_VERSION" "$SNELL_VERSION"; then
        echo -e "\n${CYAN}发现新版本，更新说明：${RESET}"
        echo -e "${GREEN}✓ 这是更新操作，不是重新安装${RESET}"
        echo -e "${GREEN}✓ 所有现有配置将被保留（端口、密码、用户配置）${RESET}"
        echo -e "${GREEN}✓ 服务会自动重启${RESET}"
        echo -e "${GREEN}✓ 配置文件会自动备份${RESET}"
        echo -e "${CYAN}是否更新 Snell? [y/N]${RESET}"
        read -r choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            update_snell_binary
        else
            echo -e "${CYAN}已取消更新。${RESET}"
        fi
    else
        echo -e "${GREEN}当前已是最新版本 (${CURRENT_VERSION})。${RESET}"
    fi
}

# 更新脚本
update_script() {
    echo -e "${CYAN}正在检查脚本更新...${RESET}"
    
    # 创建临时文件
    TMP_SCRIPT=$(mktemp)
    
    # 下载最新版本
    if curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/refs/heads/main/snell-centos.sh -o "$TMP_SCRIPT"; then
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

# 主菜单
show_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}      Snell 管理脚本 v${current_version} (支持v4/v5/v6)${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}作者: jinqians${RESET}"
    echo -e "${GREEN}网站：https://jinqians.com${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    
    # 显示服务状态
    check_and_show_status
    
    echo -e "${YELLOW}=== 基础功能 ===${RESET}"
    echo -e "${GREEN}1.${RESET} 安装 Snell"
    echo -e "${GREEN}2.${RESET} 卸载 Snell"
    echo -e "${GREEN}3.${RESET} 查看配置"
    echo -e "${GREEN}4.${RESET} 重启服务"
    
    echo -e "\n${YELLOW}=== 系统功能 ===${RESET}"
    echo -e "${GREEN}5.${RESET} 更新Snell"
    echo -e "${GREEN}6.${RESET} 更新脚本"
    echo -e "${GREEN}7.${RESET} 查看服务状态"
    echo -e "${GREEN}0.${RESET} 退出脚本"
    
    echo -e "${CYAN}============================================${RESET}"
    read -rp "请输入选项 [0-7]: " num
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
            show_information
            ;;
        4)
            restart_snell
            ;;
        5)
            check_snell_update
            ;;
        6)
            update_script
            ;;
        7)
            check_and_show_status
            read -p "按任意键继续..."
            ;;
        0)
            echo -e "${GREEN}感谢使用，再见！${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}请输入正确的选项 [0-7]${RESET}"
            ;;
    esac
    echo -e "\n${CYAN}按任意键返回主菜单...${RESET}"
    read -n 1 -s -r
done 
