#!/bin/sh
# =========================================
# 作者: jinqians
# 日期: 2025年7月25日
# 描述: 这个脚本用于在 Alpine Linux 系统上安装和管理 Snell 代理
# =========================================

# --- 定义颜色代码 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
RESET='\033[0m'

# --- 脚本版本号 ---
current_version="2.3"

# --- 全局变量 ---
SNELL_VERSION_CHOICE=""
SNELL_VERSION=""

# Snell v6 加密模式：default / unshaped / unsafe-raw（客户端必须与服务端一致）
SNELL_MODE="default"

# Snell v6 DNS 解析地址族偏好：default / prefer-ipv4 / prefer-ipv6 / ipv4-only / ipv6-only
SNELL_DNS_IP_PREFERENCE="default"

# 抓取失败时的兜底版本号
SNELL_V4_FALLBACK="v4.1.1"
SNELL_V5_FALLBACK="v5.0.1"
SNELL_V6_FALLBACK="v6.0.0rc2"
SNELL_COMMAND="" # 用于存储最终确认的可执行命令

# --- 定义系统路径 (Alpine) ---
INSTALL_DIR="/usr/local/bin"
SNELL_CONF_DIR="/etc/snell"
SNELL_CONF_FILE="${SNELL_CONF_DIR}/users/snell-main.conf"
OPENRC_SERVICE_FILE="/etc/init.d/snell"

# --- 基础函数 ---

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

check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}错误: 请以 root 权限运行此脚本。${RESET}"
        exit 1
    fi
}

check_system() {
    if [ ! -f /etc/alpine-release ]; then
        echo -e "${RED}错误: 此脚本仅适用于 Alpine Linux 系统${RESET}"
        exit 1
    fi

    # Alpine 3.19+ 的 glibc 兼容方案失效，仅支持 3.18 及以下
    alpine_version=$(cat /etc/alpine-release)
    alpine_major=$(echo "$alpine_version" | cut -d. -f1)
    alpine_minor=$(echo "$alpine_version" | cut -d. -f2)
    if [ "$alpine_major" -gt 3 ] 2>/dev/null || { [ "$alpine_major" -eq 3 ] && [ "$alpine_minor" -ge 19 ]; } 2>/dev/null; then
        echo -e "${RED}错误: 检测到 Alpine ${alpine_version}，本脚本仅支持 Alpine 3.18 及以下版本${RESET}"
        echo -e "${YELLOW}Alpine 3.19+ 请使用 Docker 安装：${RESET}"
        echo ""
        echo -e "${CYAN}docker run -d --name snell-server \\
  --restart unless-stopped \\
  --network host \\
  -e SNELL_PORT=6160 \\
  -e SNELL_PSK=your_psk \\
  -e SNELL_VER=v5 \\
  jinqians/snell-server:latest${RESET}"
        echo ""
        exit 1
    fi
}

# --- 核心安装逻辑 ---

# glibc 兼容环境安装函数
install_dependencies() {
    echo -e "${CYAN}正在更新软件源并安装依赖...${RESET}"
    apk update
    apk add curl wget unzip openssl iptables nftables openrc net-tools file
    
    echo -e "${CYAN}正在安装 glibc 兼容包（处理系统冲突）...${RESET}"
    
    apk add gcompat
    
    apk del glibc glibc-bin glibc-i18n 2>/dev/null || true
    
    GLIBC_VERSION="2.35-r0"
    
    curl -sL -o /etc/apk/keys/sgerrand.rsa.pub https://alpine-pkgs.sgerrand.com/sgerrand.rsa.pub
    
    echo -e "${CYAN}下载 glibc 核心包...${RESET}"
    curl -sL -o /tmp/glibc.apk "https://github.com/sgerrand/alpine-pkg-glibc/releases/download/${GLIBC_VERSION}/glibc-${GLIBC_VERSION}.apk"
    curl -sL -o /tmp/glibc-bin.apk "https://github.com/sgerrand/alpine-pkg-glibc/releases/download/${GLIBC_VERSION}/glibc-bin-${GLIBC_VERSION}.apk"
    curl -sL -o /tmp/glibc-i18n.apk "https://github.com/sgerrand/alpine-pkg-glibc/releases/download/${GLIBC_VERSION}/glibc-i18n-${GLIBC_VERSION}.apk"
    
    for file in glibc.apk glibc-bin.apk glibc-i18n.apk; do
        if [ ! -f "/tmp/$file" ]; then
            echo -e "${RED}$file 下载失败！${RESET}"
            return 1
        fi
    done
    
    echo -e "${CYAN}强制安装 glibc 包（可能有警告）...${RESET}"
    apk add --allow-untrusted --force-overwrite /tmp/glibc.apk /tmp/glibc-bin.apk /tmp/glibc-i18n.apk
    
    echo -e "${CYAN}配置语言环境...${RESET}"
    /usr/glibc-compat/bin/localedef -i en_US -f UTF-8 en_US.UTF-8 >/dev/null 2>&1
    
    rm -f /tmp/glibc*.apk
    
    case "$(uname -m)" in
        x86_64|amd64) glibc_loader="/usr/glibc-compat/lib/ld-linux-x86-64.so.2" ;;
        aarch64|arm64) glibc_loader="/usr/glibc-compat/lib/ld-linux-aarch64.so.1" ;;
        armv7l|armv7) glibc_loader="/usr/glibc-compat/lib/ld-linux-armhf.so.3" ;;
        *) glibc_loader="" ;;
    esac

    if [ -z "$glibc_loader" ] || [ ! -f "$glibc_loader" ]; then
        echo -e "${RED}glibc 安装验证失败！${RESET}"
        return 1
    fi
    
    echo -e "${CYAN}安装额外兼容包...${RESET}"
    apk add libc6-compat libstdc++ libgcc 2>/dev/null || true
    
    echo -e "${CYAN}持久化环境变量...${RESET}"
    if ! grep -q 'LD_LIBRARY_PATH' /etc/profile; then
        echo 'export LD_LIBRARY_PATH="/usr/glibc-compat/lib:${LD_LIBRARY_PATH}"' >> /etc/profile
    fi
    if ! grep -q 'GLIBC_TUNABLES' /etc/profile; then
        echo 'export GLIBC_TUNABLES=glibc.pthread.rseq=0' >> /etc/profile
    fi
    
    # 加载环境变量到当前会话
    . /etc/profile
    
    echo -e "${GREEN}依赖包安装完成。${RESET}"
    return 0
}

# --- 版本选择与下载 ---

select_snell_version() {
    echo -e "${CYAN}请选择要安装的 Snell 版本：${RESET}"
    echo -e "${GREEN}1.${RESET} Snell v4"
    echo -e "${GREEN}2.${RESET} Snell v5"
    echo -e "${GREEN}3.${RESET} Snell v6 (RC)"

    while true; do
        printf "请输入选项 [1-3]: "
        read -r version_choice
        case "$version_choice" in
            1) SNELL_VERSION_CHOICE="v4"; echo -e "${GREEN}已选择 Snell v4${RESET}"; break ;;
            2) SNELL_VERSION_CHOICE="v5"; echo -e "${GREEN}已选择 Snell v5${RESET}"; break ;;
            3) SNELL_VERSION_CHOICE="v6"; echo -e "${GREEN}已选择 Snell v6 (RC)${RESET}"; echo -e "${YELLOW}注意：v6 仍为预发布版本，协议可能存在不兼容更新${RESET}"; echo -e "${YELLOW}v6 已移除 QUIC 代理模式与 obfs，且不提供 armv7l 构建${RESET}"; echo -e "${YELLOW}加密模式：mode = ${SNELL_MODE}（客户端需配置相同的 mode）${RESET}"; break ;;
            *) echo -e "${RED}请输入正确的选项 [1-3]${RESET}" ;;
        esac
    done
}

# === Snell v6 参数选择（POSIX sh 写法）===
# 加密模式 (mode)：客户端必须配置完全相同的值，否则无法连接
select_snell_v6_mode() {
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
        printf "请选择加密模式 [1-3]（回车使用 1）: "
        read -r mode_choice
        [ -z "$mode_choice" ] && mode_choice="1"
        case "$mode_choice" in
            1) SNELL_MODE="default";  break ;;
            2) SNELL_MODE="unshaped"; break ;;
            3)
                SNELL_MODE="unsafe-raw"
                echo -e "${RED}警告：unsafe-raw 为明文传输，请确认该链路完全可信！${RESET}"
                printf "确认使用 unsafe-raw? [y/N]: "
                read -r raw_confirm
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
        printf "请选择 DNS 解析偏好 [1-5]（回车使用 1）: "
        read -r dns_pref_choice
        [ -z "$dns_pref_choice" ] && dns_pref_choice="1"
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

# 统一入口：安装 v6 时调用
configure_snell_v6_options() {
    select_snell_v6_mode
    select_snell_v6_dns_preference
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
    notes=$(curl -s --max-time 15 "$SNELL_RELEASE_NOTES_URL")
    if [ -z "$notes" ]; then
        notes=$(curl -s --max-time 15 "$SNELL_RELEASE_NOTES_URL_ZH")
    fi
    echo "$notes"
}

# 把版本号转成定长可排序键，排序优先级：beta < rc < 正式版
snell_version_sort_key() {
    echo "${1#v}" | awk '{
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
    major="$1"
    notes="$2"

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

get_latest_snell_v4_version() {
    ver=$(pick_latest_snell_version 4 "$(fetch_snell_release_notes)")
    if [ -n "$ver" ]; then echo "v${ver}"; else echo "${SNELL_V4_FALLBACK}"; fi
}

get_latest_snell_v5_version() {
    ver=$(pick_latest_snell_version 5 "$(fetch_snell_release_notes)")
    if [ -n "$ver" ]; then echo "v${ver}"; else echo "${SNELL_V5_FALLBACK}"; fi
}

get_latest_snell_v6_version() {
    ver=$(pick_latest_snell_version 6 "$(fetch_snell_release_notes)")
    if [ -n "$ver" ]; then echo "v${ver}"; else echo "${SNELL_V6_FALLBACK}"; fi
}

get_latest_snell_version() {
    if [ "$SNELL_VERSION_CHOICE" = "v6" ]; then SNELL_VERSION=$(get_latest_snell_v6_version);
    elif [ "$SNELL_VERSION_CHOICE" = "v5" ]; then SNELL_VERSION=$(get_latest_snell_v5_version);
    else SNELL_VERSION=$(get_latest_snell_v4_version); fi
    echo -e "${GREEN}获取到版本: ${SNELL_VERSION}${RESET}"
}

get_snell_download_url() {
    local arch=$(uname -m)
    local arch_suffix=""
    case ${arch} in
        "x86_64"|"amd64") arch_suffix="amd64" ;;
        "aarch64"|"arm64") arch_suffix="aarch64" ;;
        "armv7l"|"armv7")
            if [ "$SNELL_VERSION_CHOICE" = "v6" ]; then
                echo -e "${RED}Snell v6 暂不支持 armv7l 架构${RESET}" >&2
                exit 1
            fi
            arch_suffix="armv7l" ;;
        *) echo -e "${RED}不支持的架构: ${arch}${RESET}" >&2; exit 1 ;;
    esac
    echo "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-${arch_suffix}.zip"
}

get_user_port() {
    while true; do
        printf "请输入要使用的端口号 (1-65535), 回车默认 [随机]: "
        read -r PORT
        if [ -z "$PORT" ]; then PORT=$(shuf -i 20000-65000 -n 1); echo -e "${YELLOW}使用随机端口: $PORT${RESET}"; break; fi
        case "$PORT" in ''|*[!0-9]*) echo -e "${RED}无效输入，请输入纯数字。${RESET}"; continue;; esac
        if [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then echo -e "${GREEN}已选择端口: $PORT${RESET}"; break; else echo -e "${RED}无效端口号，请输入 1 到 65535 之间的数字。${RESET}"; fi
    done
}

save_nftables_rules() {
    if ! command -v nft >/dev/null 2>&1; then
        return
    fi

    if [ -f "/etc/nftables.nft" ]; then
        nft list ruleset > /etc/nftables.nft 2>/dev/null || true
        rc-update add nftables boot >/dev/null 2>&1 || true
        echo -e "${GREEN}nftables 规则已保存${RESET}"
    elif [ -f "/etc/nftables.conf" ]; then
        nft list ruleset > /etc/nftables.conf 2>/dev/null || true
        rc-update add nftables boot >/dev/null 2>&1 || true
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

    echo -e "${CYAN}正在配置防火墙 (nftables)...${RESET}"

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

        if ! nft list chain "$family" "$table" "$chain" 2>/dev/null | grep -q "tcp dport $port .*accept"; then
            nft insert rule "$family" "$table" "$chain" tcp dport "$port" accept 2>/dev/null || true
        fi
        if ! nft list chain "$family" "$table" "$chain" 2>/dev/null | grep -q "udp dport $port .*accept"; then
            nft insert rule "$family" "$table" "$chain" udp dport "$port" accept 2>/dev/null || true
        fi
        chain_opened=true
    done << EOF
$chains
EOF

    if [ "$chain_opened" = false ]; then
        nft add table inet snell_filter 2>/dev/null || true
        nft list chain inet snell_filter input >/dev/null 2>&1 || nft add chain inet snell_filter input '{ type filter hook input priority -5; policy accept; }'
        if ! nft list chain inet snell_filter input 2>/dev/null | grep -q "tcp dport $port .*accept"; then
            nft add rule inet snell_filter input tcp dport "$port" accept 2>/dev/null || true
        fi
        if ! nft list chain inet snell_filter input 2>/dev/null | grep -q "udp dport $port .*accept"; then
            nft add rule inet snell_filter input udp dport "$port" accept 2>/dev/null || true
        fi
    fi

    save_nftables_rules
}

open_port() {
    local port=$1

    open_nftables_port "$port"

    if command -v iptables >/dev/null 2>&1; then
        echo -e "${CYAN}正在配置防火墙 (iptables)...${RESET}"
        iptables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT
        iptables -I INPUT 1 -p udp --dport "$port" -j ACCEPT
        /etc/init.d/iptables save > /dev/null
        rc-update add iptables boot > /dev/null
    fi

    echo -e "${GREEN}防火墙端口 ${port} 已开放并设为开机自启${RESET}"
}

# 创建snell脚本
create_management_script() {
    echo -e "${CYAN}正在创建 'snell' 管理命令...${RESET}"
    local SCRIPT_URL="https://raw.githubusercontent.com/jinqians/snell.sh/main/snell-alpine.sh"
    
    cat > /usr/local/bin/snell << EOF
#!/bin/sh
# Snell 管理命令包装器
RED='\\033[0;31m'; CYAN='\\033[0;36m'; RESET='\\033[0m'
if [ "\$(id -u)" != "0" ]; then echo -e "\${RED}请以 root 权限运行此命令 (e.g., sudo snell)\${RESET}"; exit 1; fi
echo -e "\${CYAN}正在从 GitHub 获取最新的管理脚本...${RESET}"
TMP_SCRIPT=\$(mktemp)
if curl -sL "${SCRIPT_URL}" -o "\$TMP_SCRIPT"; then
    sh "\$TMP_SCRIPT"
    rm -f "\$TMP_SCRIPT"
else
    echo -e "\${RED}下载脚本失败，请检查网络连接。${RESET}"; rm -f "\$TMP_SCRIPT"; exit 1
fi
EOF

    if [ $? -eq 0 ]; then
        chmod +x /usr/local/bin/snell
        echo -e "${GREEN}✓ 'snell' 管理命令创建成功。${RESET}"
        echo -e "${YELLOW}您现在可以在任何地方输入 'sudo snell' 来运行此管理脚本。${RESET}"
    else
        echo -e "${RED}✗ 创建 'snell' 管理命令失败。${RESET}"
    fi
}


show_manual_debug_info() {
    echo -e "${YELLOW}========== 手动调试信息 ==========${RESET}"
    echo -e "${CYAN}请尝试以下命令进行手动调试:${RESET}"
    echo "1. 检查文件类型: file ${INSTALL_DIR}/snell-server"
    echo "2. 检查依赖关系: ldd ${INSTALL_DIR}/snell-server"
    echo "3. 直接运行测试: ${INSTALL_DIR}/snell-server --help"
    echo "4. 使用 glibc 链接器: /usr/glibc-compat/lib/ld-linux-x86-64.so.2 ${INSTALL_DIR}/snell-server --help"
    echo -e "${YELLOW}===================================${RESET}"
}

install_snell() {
    check_root
    if [ -f "$OPENRC_SERVICE_FILE" ]; then echo -e "${YELLOW}Snell 已安装，如需重装请先卸载。${RESET}"; return; fi
    
    # 修正：将依赖安装从主菜单移到安装流程内部
    install_dependencies
    
    select_snell_version
    get_latest_snell_version
    
    SNELL_URL=$(get_snell_download_url)
    echo -e "${CYAN}正在下载 Snell ${SNELL_VERSION}...${RESET}"
    mkdir -p "${INSTALL_DIR}"
    cd /tmp
    curl -L -o snell-server.zip "${SNELL_URL}" || { echo -e "${RED}下载失败!${RESET}"; exit 1; }
    unzip -o snell-server.zip || { echo -e "${RED}解压失败!${RESET}"; exit 1; }
    mv snell-server "${INSTALL_DIR}/"
    chmod +x "${INSTALL_DIR}/snell-server"
    rm -f snell-server.zip
    
    echo -e "${CYAN}开始执行兼容性测试...${RESET}"
    # 设置环境变量以供测试
    export LD_LIBRARY_PATH="/usr/glibc-compat/lib:${LD_LIBRARY_PATH}"
    export GLIBC_TUNABLES="glibc.pthread.rseq=0"

    if timeout 5s ${INSTALL_DIR}/snell-server --help >/dev/null 2>&1; then
        echo -e "${GREEN}✓ 兼容性测试通过：程序可直接运行。${RESET}"
        SNELL_COMMAND="${INSTALL_DIR}/snell-server"
    elif timeout 5s /usr/glibc-compat/lib/ld-linux-x86-64.so.2 ${INSTALL_DIR}/snell-server --help >/dev/null 2>&1; then
        echo -e "${GREEN}✓ 兼容性测试通过：使用 glibc 动态加载器运行。${RESET}"
        cat > ${INSTALL_DIR}/snell-server-wrapper << EOF
#!/bin/sh
export LD_LIBRARY_PATH="/usr/glibc-compat/lib:\${LD_LIBRARY_PATH}"
export GLIBC_TUNABLES="glibc.pthread.rseq=0"
exec /usr/glibc-compat/lib/ld-linux-x86-64.so.2 ${INSTALL_DIR}/snell-server "\$@"
EOF
        chmod +x ${INSTALL_DIR}/snell-server-wrapper
        SNELL_COMMAND="${INSTALL_DIR}/snell-server-wrapper"
    else
        echo -e "${RED}✗ 所有自动测试均失败！${RESET}"
        show_manual_debug_info
        exit 1
    fi

    # --- 修正：将后续安装流程移到这里 ---
    echo -e "${CYAN}正在创建配置文件和服务...${RESET}"
    mkdir -p "${SNELL_CONF_DIR}/users"
    mkdir -p "/var/log/snell"
    get_user_port
    # v6 需要额外选择 mode 与 dns-ip-preference
    if [ "$SNELL_VERSION_CHOICE" = "v6" ]; then
        configure_snell_v6_options
    fi
    PSK=$(openssl rand -base64 16)

    # v6 使用 mode / dns-ip-preference，ipv6 参数在 v6 已废弃
    {
        echo "[snell-server]"
        echo "listen = 0.0.0.0:${PORT}"
        echo "psk = ${PSK}"
        if [ "$SNELL_VERSION_CHOICE" = "v6" ]; then
            echo "mode = ${SNELL_MODE}"
            echo "dns-ip-preference = ${SNELL_DNS_IP_PREFERENCE}"
        else
            echo "ipv6 = true"
            echo "tfo = true"
        fi
        echo "version-choice = ${SNELL_VERSION_CHOICE}"
    } > ${SNELL_CONF_FILE}

    # 修正：使用您脚本中更健壮的 OpenRC 服务文件
    cat > ${OPENRC_SERVICE_FILE} << EOF
#!/sbin/openrc-run

name="Snell Server"
description="Snell proxy server"

command="${SNELL_COMMAND}"
command_args="-c /etc/snell/users/snell-main.conf"
command_user="nobody"
command_background="yes"
pidfile="/run/snell.pid"

start_stop_daemon_args="--make-pidfile --stdout /var/log/snell/snell.log --stderr /var/log/snell/snell.log"

depend() {
    need net
    after firewall
}

start_pre() {
    # 设置环境变量
    export LD_LIBRARY_PATH="/usr/glibc-compat/lib:\${LD_LIBRARY_PATH}"
    export GLIBC_TUNABLES="glibc.pthread.rseq=0"
    
    # 确保日志目录存在
    checkpath --directory --owner nobody:nobody --mode 0755 /var/log/snell
    
    # 检查配置文件
    if [ ! -f "/etc/snell/users/snell-main.conf" ]; then
        eerror "配置文件不存在: /etc/snell/users/snell-main.conf"
        return 1
    fi
    
    # 检查命令文件
    if [ ! -x "${SNELL_COMMAND}" ]; then
        eerror "Snell 可执行文件不存在或无执行权限: ${SNELL_COMMAND}"
        return 1
    fi
}

stop_post() {
    # 清理 PID 文件
    [ -f "\${pidfile}" ] && rm -f "\${pidfile}"
}
EOF

    chmod +x ${OPENRC_SERVICE_FILE}

    echo -e "${CYAN}正在启动 Snell 服务...${RESET}"
    rc-update add snell default
    rc-service snell start

    sleep 2
    if rc-service snell status | grep -q "started"; then
        echo -e "${GREEN}✓ Snell 服务运行正常${RESET}"
        open_port "$PORT"
        create_management_script
        show_information
    else
        echo -e "${RED}✗ 服务启动后状态异常${RESET}"
        echo -e "${YELLOW}请查看日志: tail /var/log/snell/snell.log${RESET}"
    fi
}

uninstall_snell() {
    check_root
    if [ ! -f "$OPENRC_SERVICE_FILE" ]; then echo -e "${YELLOW}Snell 未安装。${RESET}"; return; fi
    echo -e "${CYAN}正在卸载 Snell...${RESET}"
    rc-service snell stop 2>/dev/null
    rc-update del snell default 2>/dev/null
    if [ -f "${SNELL_CONF_FILE}" ]; then
        PORT_TO_CLOSE=$(grep 'listen' ${SNELL_CONF_FILE} | sed 's/.*://' | tr -d ' ')
        if [ -n "$PORT_TO_CLOSE" ]; then iptables -D INPUT -p tcp --dport "$PORT_TO_CLOSE" -j ACCEPT 2>/dev/null; fi
    fi
    rm -f ${OPENRC_SERVICE_FILE} ${INSTALL_DIR}/snell-server ${INSTALL_DIR}/snell-server-wrapper
    rm -rf ${SNELL_CONF_DIR} /var/log/snell
    echo -e "${GREEN}Snell 已成功卸载。${RESET}"
}

show_information() {
    if [ ! -f "${SNELL_CONF_FILE}" ]; then echo -e "${RED}未找到配置文件。${RESET}"; return; fi
    
    PORT=$(grep 'listen' ${SNELL_CONF_FILE} | sed 's/.*://')
    PSK=$(grep 'psk' ${SNELL_CONF_FILE} | sed 's/^[^=]*=[[:space:]]*//')
    INSTALLED_VERSION_CHOICE=$(grep 'version-choice' ${SNELL_CONF_FILE} | sed 's/version-choice\s*=\s*//')
    [ -z "$INSTALLED_VERSION_CHOICE" ] && INSTALLED_VERSION_CHOICE="v4"
    INSTALLED_MODE=$(grep -E '^[[:space:]]*mode[[:space:]]*=' ${SNELL_CONF_FILE} | head -n 1 | sed 's/^[^=]*=[[:space:]]*//')
    [ -z "$INSTALLED_MODE" ] && INSTALLED_MODE="${SNELL_MODE}"
    
    IPV4_ADDR=$(curl -s4 --connect-timeout 5 https://api.ipify.org)
    IPV6_ADDR=$(curl -s6 --connect-timeout 5 https://api64.ipify.org)
    
    clear
    echo -e "${BLUE}============================================${RESET}"
    echo -e "${GREEN}Snell 配置信息:${RESET}"
    echo -e "${BLUE}============================================${RESET}"

    if [ -n "$IPV4_ADDR" ]; then
        IP_COUNTRY_IPV4=$(get_ip_country "${IPV4_ADDR}")
        echo -e "${GREEN}--- IPv4 Surge 配置 (Snell ${INSTALLED_VERSION_CHOICE}) ---${RESET}"
        if [ "$INSTALLED_VERSION_CHOICE" = "v6" ]; then
            echo -e "${GREEN}${IP_COUNTRY_IPV4} = snell, ${IPV4_ADDR}, ${PORT}, psk=${PSK}, version=6, mode=${INSTALLED_MODE}, reuse=true, tfo=true${RESET}"
        elif [ "$INSTALLED_VERSION_CHOICE" = "v5" ]; then
            echo -e "${GREEN}${IP_COUNTRY_IPV4}_v4 = snell, ${IPV4_ADDR}, ${PORT}, psk=${PSK}, version=4, reuse=true, tfo=true${RESET}"
            echo -e "${GREEN}${IP_COUNTRY_IPV4}_v5 = snell, ${IPV4_ADDR}, ${PORT}, psk=${PSK}, version=5, reuse=true, tfo=true${RESET}"
        else
            echo -e "${GREEN}${IP_COUNTRY_IPV4} = snell, ${IPV4_ADDR}, ${PORT}, psk=${PSK}, version=4, reuse=true, tfo=true${RESET}"
        fi
    fi

    if [ -n "$IPV6_ADDR" ]; then
        IP_COUNTRY_IPV6=$(get_ip_country "${IPV6_ADDR}")
        echo -e "\n${GREEN}--- IPv6 Surge 配置 (Snell ${INSTALLED_VERSION_CHOICE}) ---${RESET}"
        if [ "$INSTALLED_VERSION_CHOICE" = "v6" ]; then
            echo -e "${GREEN}${IP_COUNTRY_IPV6} = snell, ${IPV6_ADDR}, ${PORT}, psk=${PSK}, version=6, mode=${INSTALLED_MODE}, reuse=true, tfo=true${RESET}"
        elif [ "$INSTALLED_VERSION_CHOICE" = "v5" ]; then
            echo -e "${GREEN}${IP_COUNTRY_IPV6}_v4 = snell, ${IPV6_ADDR}, ${PORT}, psk=${PSK}, version=4, reuse=true, tfo=true${RESET}"
            echo -e "${GREEN}${IP_COUNTRY_IPV6}_v5 = snell, ${IPV6_ADDR}, ${PORT}, psk=${PSK}, version=5, reuse=true, tfo=true${RESET}"
        else
            echo -e "${GREEN}${IP_COUNTRY_IPV6} = snell, ${IPV6_ADDR}, ${PORT}, psk=${PSK}, version=4, reuse=true, tfo=true${RESET}"
        fi
    fi

    echo ""
    echo -e "${YELLOW}服务器端口: ${RESET}${PORT}"
    echo -e "${YELLOW}PSK 密钥: ${RESET}${PSK}"
    echo -e "\n${YELLOW}配置文件: ${RESET}${SNELL_CONF_FILE}"
    echo -e "${YELLOW}日志文件: ${RESET}/var/log/snell/snell.log"
    echo -e "${BLUE}============================================${RESET}"
}

restart_snell() {
    check_root
    echo -e "${YELLOW}正在重启 Snell 服务...${RESET}"
    rc-service snell restart; sleep 2
    if rc-service snell status | grep -q "started"; then echo -e "${GREEN}Snell 服务重启成功${RESET}"; else echo -e "${RED}Snell 服务重启失败${RESET}"; fi
}

check_status() {
    check_root
    echo -e "${CYAN}=== Snell 服务状态 ===${RESET}"
    rc-service snell status
    echo -e "\n${CYAN}=== 最新日志 (最后10行) ===${RESET}"
    if [ -f "/var/log/snell/snell.log" ]; then tail -10 /var/log/snell/snell.log; else echo "日志文件不存在"; fi
}

# --- 主菜单与循环 ---
show_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}     Snell for Alpine 管理脚本 v${current_version}${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    if [ -f "$OPENRC_SERVICE_FILE" ]; then
        if rc-service snell status | grep -q "started"; then echo -e "服务状态: ${GREEN}运行中${RESET}"; else echo -e "服务状态: ${RED}已停止${RESET}"; fi
    else echo -e "服务状态: ${YELLOW}未安装${RESET}"; fi
    echo -e "${CYAN}--------------------------------------------${RESET}"
    echo -e "${GREEN}1.${RESET} 安装 Snell"
    echo -e "${GREEN}2.${RESET} 卸载 Snell"
    echo -e "${GREEN}3.${RESET} 重启服务"
    echo -e "${GREEN}4.${RESET} 查看配置信息"
    echo -e "${GREEN}5.${RESET} 查看详细状态"
    echo -e "${GREEN}0.${RESET} 退出脚本"
    echo -e "${CYAN}============================================${RESET}"
    printf "请输入选项 [0-5]: "
    read -r num
}

check_root
check_system

while true; do
    show_menu
    case "$num" in
        1) install_snell ;;
        2) uninstall_snell ;;
        3) restart_snell ;;
        4) show_information ;;
        5) check_status ;;
        0) echo -e "${GREEN}感谢使用，再见！${RESET}"; exit 0 ;;
        *) echo -e "${RED}请输入正确的选项 [0-5]${RESET}";;
    esac
    echo ""
    printf "${CYAN}按任意键返回主菜单...${RESET}"
    read -r dummy
done
