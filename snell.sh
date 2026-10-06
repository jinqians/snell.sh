#!/bin/bash
# 此文件由 tools/build.sh 从 src/snell.sh 和 src/lib 生成：请修改 src/ 下的文件后重新生成。
# =========================================
# 作者: jinqians
# 日期: 2025年2月
# 网站：jinqians.com
# 描述: 这个脚本用于安装、卸载、查看和更新 Snell 代理
#       Debian / Ubuntu / CentOS / RHEL / Rocky / AlmaLinux / Fedora（systemd）
# =========================================

# 共用部分（src/lib）。发布的 snell.sh 是 tools/build.sh 把它们合进来的单个文件，
# 直接运行 src/snell.sh 时从旁边的 lib 目录读。
# ── lib/common.sh ─────────────────────────────────────────────────────────────
# 所有脚本共用：颜色、root 检查、系统与包管理器、脚本的发布地址。
# 只用 POSIX sh 的写法：Alpine / Docker 版脚本在 ash、dash 下也要能用。

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 脚本的发布地址。短域名（*.jinqians.com）由 Cloudflare 重定向到仓库里的文件：
# snell / snell-centos / snell-alpine → 根目录，menu / snell-docker / install → scripts/。
# 菜单里调用的子脚本从 SNELL_RAW_BASE 下的 scripts/、docker/ 取。
# 脚本自身的更新与管理命令走短域名，运行才会被统计到。
# 可以用同名环境变量换成镜像地址（测试时指向本地的文件）。
SNELL_RAW_BASE="${SNELL_RAW_BASE:-https://raw.githubusercontent.com/jinqians/snell.sh/main}"
SNELL_SCRIPT_URL="${SNELL_SCRIPT_URL:-https://snell.jinqians.com}"                     # snell.sh（Debian / Ubuntu / CentOS / RHEL）
SNELL_ALPINE_SCRIPT_URL="${SNELL_ALPINE_SCRIPT_URL:-https://snell-alpine.jinqians.com}" # snell-alpine.sh
SNELL_DOCKER_SCRIPT_URL="${SNELL_DOCKER_SCRIPT_URL:-https://snell-docker.jinqians.com}" # snell-docker.sh
SNELL_MENU_SCRIPT_URL="${SNELL_MENU_SCRIPT_URL:-https://menu.jinqians.com}"             # menu.sh

# 检查是否以 root 权限运行
check_root() {
    if [ "$(id -u)" != "0" ]; then
        printf '%b\n' "${RED}请以 root 权限运行此脚本${RESET}"
        exit 1
    fi
}

# 识别系统：OS_FAMILY = debian | rhel | alpine | unknown，PKG = apt | dnf | yum | apk
OS_FAMILY=""
PKG=""
detect_os() {
    [ -n "$OS_FAMILY" ] && return 0
    OS_FAMILY="unknown"
    if [ -f /etc/os-release ]; then
        # 在子 shell 里读，os-release 的 NAME / VERSION 等变量不会覆盖脚本自己的
        case " $(. /etc/os-release; echo "$ID $ID_LIKE" | tr '[:upper:]' '[:lower:]') " in
            *" debian "*|*" ubuntu "*) OS_FAMILY="debian" ;;
            *" rhel "*|*" centos "*|*" fedora "*|*" rocky "*|*" almalinux "*) OS_FAMILY="rhel" ;;
            *" alpine "*) OS_FAMILY="alpine" ;;
        esac
    elif [ -f /etc/redhat-release ]; then
        OS_FAMILY="rhel"
    fi
    if command -v apt-get >/dev/null 2>&1; then PKG="apt"
    elif command -v dnf >/dev/null 2>&1; then PKG="dnf"
    elif command -v yum >/dev/null 2>&1; then PKG="yum"
    elif command -v apk >/dev/null 2>&1; then PKG="apk"
    fi
}

# 等待其他 apt 进程完成
wait_for_apt() {
    command -v fuser >/dev/null 2>&1 || return 0
    while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1; do
        printf '%b\n' "${YELLOW}等待其他 apt 进程完成...${RESET}"
        sleep 2
    done
}

# 用系统的包管理器安装软件包
pkg_install() {
    detect_os
    case "$PKG" in
        apt)
            wait_for_apt
            DEBIAN_FRONTEND=noninteractive apt-get update -q >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
            ;;
        dnf) dnf install -y "$@" ;;
        yum) yum install -y "$@" ;;
        apk) apk add --no-cache "$@" ;;
        *)
            printf '%b\n' "${RED}未识别的包管理器，请手动安装：$*${RESET}"
            return 1
            ;;
    esac
}

# 提供某个命令的软件包名（各发行版不同的在这里对上）
pkg_for_cmd() {
    detect_os
    case "$1" in
        ip|ss) if [ "$OS_FAMILY" = "rhel" ]; then echo "iproute"; else echo "iproute2"; fi ;;
        nft) echo "nftables" ;;
        fuser) echo "psmisc" ;;
        gpg) if [ "$OS_FAMILY" = "rhel" ]; then echo "gnupg2"; else echo "gnupg"; fi ;;
        sysctl) if [ "$OS_FAMILY" = "rhel" ]; then echo "procps-ng"; else echo "procps"; fi ;;
        modprobe) echo "kmod" ;;
        *) echo "$1" ;;
    esac
}

# 缺哪个命令就装哪个包；装不上返回非 0，由调用方决定是否退出
ensure_cmds() {
    _ec_missing=""
    for _ec_cmd in "$@"; do
        command -v "$_ec_cmd" >/dev/null 2>&1 || _ec_missing="${_ec_missing} $(pkg_for_cmd "$_ec_cmd")"
    done
    [ -z "$_ec_missing" ] && return 0
    printf '%b\n' "${YELLOW}正在安装依赖：${_ec_missing# }${RESET}"
    # shellcheck disable=SC2086 # 包名按空格分开传
    pkg_install $_ec_missing || return 1
    for _ec_cmd in "$@"; do
        if ! command -v "$_ec_cmd" >/dev/null 2>&1; then
            printf '%b\n' "${RED}安装后仍找不到 ${_ec_cmd}，请手动安装 $(pkg_for_cmd "$_ec_cmd")${RESET}"
            return 1
        fi
    done
}

# 下载远程脚本并做完整性校验：传输失败即停、非空、语法检查。
# 只能保证传输完整；仓库本身被篡改要靠发布签名来防。
fetch_verified_script() {   # <url> <dest>
    if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 "$1" -o "$2"; then
        printf '%b\n' "${RED}下载失败: $1${RESET}" >&2
        rm -f "$2"
        return 1
    fi
    if [ ! -s "$2" ]; then
        printf '%b\n' "${RED}下载的文件为空，已丢弃: $1${RESET}" >&2
        rm -f "$2"
        return 1
    fi
    # bash 能解析 sh 写法；没有 bash 的系统（Alpine）用 sh 检查
    if command -v bash >/dev/null 2>&1; then
        _fv_shell=bash
    else
        _fv_shell=sh
    fi
    if ! "$_fv_shell" -n "$2" 2>/dev/null; then
        printf '%b\n' "${RED}下载的脚本未通过语法检查，已丢弃: $1${RESET}" >&2
        rm -f "$2"
        return 1
    fi
    return 0
}

# ── lib/release.sh ────────────────────────────────────────────────────────────
# Snell 官方版本：从发布页取各大版本的最新版本号，生成下载地址。POSIX sh。

# 抓取失败时的兜底版本号
SNELL_V4_FALLBACK="v4.1.1"
SNELL_V5_FALLBACK="v5.0.1"
SNELL_V6_FALLBACK="v6.0.0rc2"

# Snell 官方发布页（旧的 manual.nssurge.com/others/snell.html 已下线）
SNELL_RELEASE_NOTES_URL="https://kb.nssurge.com/surge-knowledge-base/release-notes/snell"
SNELL_RELEASE_NOTES_URL_ZH="https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell"

# 抓取官方发布页内容
fetch_snell_release_notes() {
    local notes
    notes=$(curl -sL --max-time 15 "$SNELL_RELEASE_NOTES_URL")
    if [ -z "$notes" ]; then
        notes=$(curl -sL --max-time 15 "$SNELL_RELEASE_NOTES_URL_ZH")
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

# 解析指定通道的最新版本号（失败时回落到内置常量）
resolve_latest_version_for_channel() {
    case "$1" in
        v6) get_latest_snell_v6_version ;;
        v5) get_latest_snell_v5_version ;;
        v4) get_latest_snell_v4_version ;;
        *)  return 1 ;;
    esac
}

# 生成指定通道 + 版本号的下载地址；不支持的架构返回非 0（不 exit，调用方可继续）
snell_download_url_for() {
    local version_choice="$1"
    local resolved_version="$2"
    local arch
    arch=$(uname -m)

    case "$version_choice" in
        v4|v5|v6) ;;
        *)
            printf '%b\n' "${RED}不支持的 Snell 通道: ${version_choice}${RESET}" >&2
            return 1
            ;;
    esac

    if [ "$version_choice" = "v6" ] && { [ "$arch" = "armv7l" ] || [ "$arch" = "armv7" ]; }; then
        printf '%b\n' "${RED}Snell v6 暂不提供 armv7l 构建${RESET}" >&2
        return 1
    fi

    case "$arch" in
        "x86_64"|"amd64")  echo "https://dl.nssurge.com/snell/snell-server-${resolved_version}-linux-amd64.zip" ;;
        "i386"|"i686")     echo "https://dl.nssurge.com/snell/snell-server-${resolved_version}-linux-i386.zip" ;;
        "aarch64"|"arm64") echo "https://dl.nssurge.com/snell/snell-server-${resolved_version}-linux-aarch64.zip" ;;
        "armv7l"|"armv7")  echo "https://dl.nssurge.com/snell/snell-server-${resolved_version}-linux-armv7l.zip" ;;
        *)
            printf '%b\n' "${RED}不支持的架构: ${arch}${RESET}" >&2
            return 1
            ;;
    esac
}

# ── lib/netinfo.sh ────────────────────────────────────────────────────────────
# 本机公网地址与所在国家（生成客户端配置时用）。POSIX sh。

# 本机公网 IPv4 / IPv6（取不到时为空）
get_public_ipv4() { curl -s4 --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null; }
get_public_ipv6() { curl -s6 --connect-timeout 5 --max-time 10 https://api64.ipify.org 2>/dev/null; }

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

    for api in "https://ipinfo.io/${target}/country" \
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

# ── lib/firewall.sh ───────────────────────────────────────────────────────────
# 开放 / 关闭端口：firewalld、ufw、iptables + ip6tables、nftables，系统在用哪个就配哪个，
# 并持久化。所有脚本共用这一份（以前各脚本各有一份，CentOS 版才认 firewalld、
# Docker 版只开 TCP、重复安装会叠加重复规则）。POSIX sh。

# firewalld 正在运行
_fw_firewalld_active() {
    command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1
}

# ufw 已启用（-w：不把 inactive 当成 active）
_fw_ufw_active() {
    command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw "active"
}

# both | tcp | udp → 协议列表
_fw_protos() {
    case "$1" in
        tcp) echo "tcp" ;;
        udp) echo "udp" ;;
        *) echo "tcp udp" ;;
    esac
}

# iptables 规则持久化：Debian 的 /etc/iptables、RHEL 的 iptables-services、Alpine 的 init 脚本
_fw_iptables_save() {
    if [ -x /etc/init.d/iptables ] && command -v rc-update >/dev/null 2>&1; then
        /etc/init.d/iptables save >/dev/null 2>&1 || true
        rc-update add iptables boot >/dev/null 2>&1 || true
        if [ -x /etc/init.d/ip6tables ]; then
            /etc/init.d/ip6tables save >/dev/null 2>&1 || true
            rc-update add ip6tables boot >/dev/null 2>&1 || true
        fi
    elif [ -f /etc/sysconfig/iptables ]; then
        iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
        [ -f /etc/sysconfig/ip6tables ] && ip6tables-save > /etc/sysconfig/ip6tables 2>/dev/null || true
    else
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    fi
}

# iptables / ip6tables：没有同样的规则才插入
_fw_iptables_open() {   # <port> <protos>
    _fio_changed=false
    for _fio_t in iptables ip6tables; do
        command -v "$_fio_t" >/dev/null 2>&1 || continue
        "$_fio_t" -L INPUT -n >/dev/null 2>&1 || continue   # 内核或容器里不可用
        for _fio_p in $2; do
            if ! "$_fio_t" -C INPUT -p "$_fio_p" --dport "$1" -j ACCEPT 2>/dev/null; then
                "$_fio_t" -I INPUT -p "$_fio_p" --dport "$1" -j ACCEPT 2>/dev/null && _fio_changed=true
            fi
        done
    done
    if [ "$_fio_changed" = true ]; then
        printf '%b\n' "${CYAN}在 iptables 中开放端口 $1${RESET}"
        _fw_iptables_save
    fi
}

_fw_iptables_close() {   # <port>
    _fic_changed=false
    for _fic_t in iptables ip6tables; do
        command -v "$_fic_t" >/dev/null 2>&1 || continue
        for _fic_p in tcp udp; do
            while "$_fic_t" -C INPUT -p "$_fic_p" --dport "$1" -j ACCEPT 2>/dev/null; do
                "$_fic_t" -D INPUT -p "$_fic_p" --dport "$1" -j ACCEPT 2>/dev/null || break
                _fic_changed=true
            done
        done
    done
    [ "$_fic_changed" = true ] && _fw_iptables_save
    return 0
}

# 保存 nftables 规则（有持久化配置文件时）
save_nftables_rules() {
    command -v nft >/dev/null 2>&1 || return 0
    for _snr_f in /etc/nftables.conf /etc/sysconfig/nftables.conf /etc/nftables.nft; do
        [ -f "$_snr_f" ] || continue
        nft list ruleset > "$_snr_f" 2>/dev/null || true
        if command -v systemctl >/dev/null 2>&1; then
            systemctl enable nftables >/dev/null 2>&1 || true
        elif command -v rc-update >/dev/null 2>&1; then
            rc-update add nftables boot >/dev/null 2>&1 || true
        fi
        printf '%b\n' "${GREEN}nftables 规则已保存${RESET}"
        return 0
    done
    return 0
}

# nftables 里 hook 在 input 上的 filter 链（"族 表 链" 每行一条）。
# iptables-nft 自己的 ip/ip6 filter 表已由 iptables 处理，跳过，免得规则重复。
_fw_nft_input_chains() {
    nft -a list ruleset 2>/dev/null | awk -v skip_ipt="$1" '
        $1 == "table" { family = $2; table = $3; gsub(/[{}]/, "", table) }
        $1 == "chain" { chain = $2; gsub(/[{}]/, "", chain); in_chain = 1; next }
        in_chain && /type filter/ && /hook input/ {
            if (!(skip_ipt == "1" && (family == "ip" || family == "ip6") && table == "filter")) print family " " table " " chain
        }
        in_chain && /^[[:space:]]*}/ { in_chain = 0 }
    '
}

# 在 nftables 现有的 input 链里放行端口（没有 nftables 防火墙时什么都不做）
open_nftables_port() {   # <port> [both|tcp|udp]
    command -v nft >/dev/null 2>&1 || return 0
    _onp_skip=0
    command -v iptables >/dev/null 2>&1 && _onp_skip=1
    _onp_chains=$(_fw_nft_input_chains "$_onp_skip")
    [ -n "$_onp_chains" ] || return 0
    _onp_changed=false
    _onp_protos=$(_fw_protos "${2:-both}")
    while read -r _onp_family _onp_table _onp_chain; do
        [ -n "$_onp_family" ] || continue
        for _onp_p in $_onp_protos; do
            if ! nft list chain "$_onp_family" "$_onp_table" "$_onp_chain" 2>/dev/null | grep -q "$_onp_p dport $1 .*accept"; then
                nft insert rule "$_onp_family" "$_onp_table" "$_onp_chain" "$_onp_p" dport "$1" accept 2>/dev/null && _onp_changed=true
            fi
        done
    done <<EOF
$_onp_chains
EOF
    if [ "$_onp_changed" = true ]; then
        printf '%b\n' "${CYAN}在 nftables 中开放端口 $1${RESET}"
        save_nftables_rules
    fi
}

# 删掉 nftables 里放行该端口的规则
close_nftables_port() {   # <port>
    command -v nft >/dev/null 2>&1 || return 0
    _cnp_rules=$(nft -a list ruleset 2>/dev/null | awk -v port="$1" '
        $1 == "table" { family = $2; table = $3; gsub(/[{}]/, "", table) }
        $1 == "chain" { chain = $2; gsub(/[{}]/, "", chain) }
        ($0 ~ "(tcp|udp) dport " port " .*accept") && /# handle/ { print family " " table " " chain " " $NF }
    ')
    [ -n "$_cnp_rules" ] || return 0
    while read -r _cnp_family _cnp_table _cnp_chain _cnp_handle; do
        [ -n "$_cnp_handle" ] || continue
        nft delete rule "$_cnp_family" "$_cnp_table" "$_cnp_chain" handle "$_cnp_handle" 2>/dev/null || true
    done <<EOF
$_cnp_rules
EOF
    save_nftables_rules
}

# 开放端口：firewalld 在运行就只交给它；ufw 已启用就只交给它；否则配 iptables 与 nftables
open_port() {   # <port> [both|tcp|udp]
    _op_protos=$(_fw_protos "${2:-both}")
    if _fw_firewalld_active; then
        printf '%b\n' "${CYAN}在 firewalld 中开放端口 $1${RESET}"
        for _op_p in $_op_protos; do
            firewall-cmd --permanent --add-port="$1/${_op_p}" >/dev/null 2>&1 || true
            firewall-cmd --add-port="$1/${_op_p}" >/dev/null 2>&1 || true
        done
        return 0
    fi
    # ufw 装了但没启用时也写进去：以后启用 ufw 时端口仍是开的
    if command -v ufw >/dev/null 2>&1; then
        printf '%b\n' "${CYAN}在 UFW 中开放端口 $1${RESET}"
        for _op_p in $_op_protos; do
            ufw allow "$1/${_op_p}" >/dev/null 2>&1 || true
        done
        _fw_ufw_active && return 0
    fi
    _fw_iptables_open "$1" "$_op_protos"
    open_nftables_port "$1" "${2:-both}"
    return 0
}

# 关闭端口：各个防火墙里放行它的规则都删掉
close_port() {   # <port>
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        for _cp_p in tcp udp; do
            firewall-cmd --permanent --remove-port="$1/${_cp_p}" >/dev/null 2>&1 || true
            firewall-cmd --remove-port="$1/${_cp_p}" >/dev/null 2>&1 || true
        done
    fi
    if command -v ufw >/dev/null 2>&1; then
        ufw delete allow "$1/tcp" >/dev/null 2>&1 || true
        ufw delete allow "$1/udp" >/dev/null 2>&1 || true
        ufw delete allow "$1" >/dev/null 2>&1 || true
    fi
    _fw_iptables_close "$1"
    close_nftables_port "$1"
    return 0
}

# 端口在当前防火墙里是否放行（测试与状态显示用）：firewalld / ufw / iptables / nftables 任一处放行即算
port_allowed() {   # <port> <tcp|udp>
    if _fw_firewalld_active; then
        firewall-cmd --query-port="$1/$2" >/dev/null 2>&1
        return
    fi
    if _fw_ufw_active; then
        ufw status 2>/dev/null | grep -Eq "^$1(/$2)?[[:space:]]+ALLOW"
        return
    fi
    if command -v iptables >/dev/null 2>&1 && iptables -C INPUT -p "$2" --dport "$1" -j ACCEPT 2>/dev/null; then
        return 0
    fi
    command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q "$2 dport $1 .*accept"
}

# 端口是否有进程在监听（TCP 或 UDP）
is_port_in_use() {   # <port>
    if command -v ss >/dev/null 2>&1; then
        ss -H -ltn "( sport = :$1 )" 2>/dev/null | grep -q . && return 0
        ss -H -lun "( sport = :$1 )" 2>/dev/null | grep -q . && return 0
        return 1
    fi
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1 && return 0
        lsof -nP -iUDP:"$1" >/dev/null 2>&1
        return
    fi
    return 1
}

# 显示占用指定端口的进程
show_port_occupier() {   # <port>
    if command -v ss >/dev/null 2>&1; then
        ss -ltnp "( sport = :$1 )" 2>/dev/null | sed 's/^/  /'
        ss -lunp "( sport = :$1 )" 2>/dev/null | sed 's/^/  /'
        return
    fi
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | sed 's/^/  /'
        lsof -nP -iUDP:"$1" 2>/dev/null | sed 's/^/  /'
    fi
}

# ── lib/channels.sh ───────────────────────────────────────────────────────────
# systemd 安装的布局与多版本共存（v4 / v5 / v6）。snell.sh、multi-user.sh、
# shadowtls.sh 共用（bash）。
#
# 二进制布局：
#   ${INSTALL_DIR}/snell-server-v4|v5|v6   各通道的实体文件，systemd unit 直接指向它
#   ${INSTALL_DIR}/snell-server            软链，指向主用户所用通道（保留给旧的探测逻辑）
#
# 版本标记：
#   每个用户配置首行写 "#version-choice = vX"。注释形式，snell-server 不会解析到，
#   且随 .conf 一起被备份/还原，不需要额外的伴生文件。PSM 写的配置也带这个标记。

# 系统路径
INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
SNELL_CONF_DIR="/etc/snell"
USERS_DIR="${SNELL_CONF_DIR}/users"
SNELL_CONF_FILE="${USERS_DIR}/snell-main.conf"
SYSTEMD_SERVICE_FILE="${SYSTEMD_DIR}/snell.service"
SYSTEMD_SOCKET_FILE="${SYSTEMD_DIR}/snell.socket"
SYSTEMD_NETNS_FILE="${SYSTEMD_DIR}/snell-netns.service"
NETNS_SETUP_SCRIPT="${INSTALL_DIR}/snell-netns-setup.sh"

# 旧的配置文件路径（用于兼容性检查）
OLD_SNELL_CONF_FILE="${SNELL_CONF_DIR}/snell-server.conf"
OLD_SYSTEMD_SERVICE_FILE="/lib/systemd/system/snell.service"
SNELL_SERVICE_USER="snell"
SNELL_SERVICE_GROUP="snell"

SNELL_VERSION_MARKER_KEY="version-choice"
SNELL_ALL_VERSIONS="v4 v5 v6"

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

# 获取 Snell 端口
get_snell_port() {
    if [ -f "${SNELL_CONF_DIR}/users/snell-main.conf" ]; then
        grep -E '^listen' "${SNELL_CONF_DIR}/users/snell-main.conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p'
    fi
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

    # 下载与解压要用的命令，缺了先装（任何发行版）
    ensure_cmds curl unzip >&2 || return 1

    local tmp_dir
    tmp_dir=$(mktemp -d) || return 1

    local downloaded=false
    curl -fL --retry 3 --connect-timeout 10 --max-time 120 -o "${tmp_dir}/snell-server.zip" "$url" && downloaded=true

    if [ "$downloaded" != "true" ]; then
        echo -e "${RED}下载 Snell ${version} 失败: ${url}${RESET}" >&2
        rm -rf "$tmp_dir"
        return 1
    fi

    # 校验压缩包完整性（官方未发布 hash，只能做传输完整性检查）
    if ! unzip -t -q "${tmp_dir}/snell-server.zip" >/dev/null 2>&1; then
        echo -e "${RED}下载的压缩包已损坏，已丢弃: ${url}${RESET}" >&2
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
    # 存有 PSK 的配置文件仅属主可读写
    find "${SNELL_CONF_DIR}/users" -maxdepth 1 -name "*.conf" -exec chmod 600 {} + 2>/dev/null || true
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

# 写用户的 systemd 单元，ExecStart 指向该用户所选通道的二进制
write_user_service_unit() {
    local port="$1"
    local user_conf="$2"
    local version="$3"
    local snell_binary
    snell_binary=$(snell_binary_for_version "$version")

    cat > "${SYSTEMD_DIR}/snell-${port}.service" << EOF
[Unit]
Description=Snell Proxy Service (Port ${port}, ${version})
After=network.target

[Service]
Type=simple
User=${SNELL_SERVICE_USER}
Group=${SNELL_SERVICE_GROUP}
LimitNOFILE=32768
ExecStart=${snell_binary} -c ${user_conf}
AmbientCapabilities=CAP_NET_BIND_SERVICE
StandardOutput=journal
StandardError=journal
SyslogIdentifier=snell-server-${port}

[Install]
WantedBy=multi-user.target
EOF
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

# === 新增：备份和还原配置函数 ===
# 备份 Snell 配置（只保留最近 10 个备份，避免越积越多）
backup_snell_config() {
    local backup_dir="${SNELL_CONF_DIR}/backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    cp -a "${SNELL_CONF_DIR}/users"/*.conf "$backup_dir"/ 2>/dev/null
    ls -dt "${SNELL_CONF_DIR}"/backup_* 2>/dev/null | tail -n +11 | xargs -r rm -rf
    echo "$backup_dir"
}


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

# ── lib/routing.sh ────────────────────────────────────────────────────────────
# 规则分流：Snell 服务端照旧用官方 snell-server，它连出去的流量按规则集决定走向——
# 直连、拒绝，或者交给另一个出口（SOCKS5 / HTTP / Shadowsocks / WireGuard，比如家宽或 WARP）。
#
# 做法：nftables 只拦 snell 用户（所有 Snell 服务都以它运行）新发起的连接——TCP 重定向、
# UDP 用 TPROXY——交给本机一个 sing-box（官方版本，固定版本号），sing-box 识别出域名
# （TLS SNI / HTTP Host / QUIC）后按规则选出口。回给客户端的流量、sing-box 自己的流量、
# DNS 查询都不经过它。sing-box 停了（或崩了）拦截规则随之撤掉，Snell 回到直连，不会断网。
# 出口控制（netns）模式下 Snell 的流量不在本机发起，两者只能二选一。（bash）

ROUTER_DIR="/etc/snell-router"                 # 状态与生成的配置（不放 /etc/snell：那里整个属于 snell 用户）
ROUTER_STATE="${ROUTER_DIR}/state.json"
ROUTER_CONFIG="${ROUTER_DIR}/config.json"
ROUTER_BIN="${INSTALL_DIR}/snell-router"       # sing-box，单独一份，不影响机器上别的 sing-box（比如 PSM 的）
ROUTER_NET="${INSTALL_DIR}/snell-router-net"   # 拦截规则的 up / down
ROUTER_UNIT="${SYSTEMD_DIR}/snell-router.service"
ROUTER_DROPIN_NAME="snell-router.conf"         # 让以 root 运行的 Snell 服务（如 PSM 装的）改用 snell 用户
ROUTER_TCP_PORT=17391
ROUTER_UDP_PORT=17392
ROUTER_MARK=0x736e                             # "sn"
ROUTER_TABLE=7391
# 测试过的 sing-box 版本（它的配置格式在大版本之间会变，所以不追最新；可用环境变量换）
ROUTER_SINGBOX_VERSION="${SNELL_ROUTER_SINGBOX_VERSION:-1.14.2}"
GEOSITE_URL="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set"
GEOIP_URL="https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set"

router_installed() { [ -f "$ROUTER_UNIT" ]; }
router_active() { systemctl is-active --quiet snell-router 2>/dev/null; }

# 状态：{udp, rules: [sing-box 规则 + _label], outbounds: [...], endpoints: [...], rule_sets: {tag: url}}
router_state() {
    if [ -s "$ROUTER_STATE" ]; then cat "$ROUTER_STATE"
    else echo '{"udp": true, "rules": [], "outbounds": [], "endpoints": [], "rule_sets": {}}'; fi
}
router_save_state() {   # <json>
    mkdir -p "$ROUTER_DIR" && chmod 700 "$ROUTER_DIR"
    printf '%s\n' "$1" | jq '.' > "${ROUTER_STATE}.tmp" && mv "${ROUTER_STATE}.tmp" "$ROUTER_STATE"
}

# 规则集的标签 → 下载地址（geosite-* / geoip-* 用 SagerNet 的，其他从状态里查）
router_rule_set_url() {   # <tag>
    case "$1" in
        geosite-*) echo "${GEOSITE_URL}/$1.srs" ;;
        geoip-*)   echo "${GEOIP_URL}/$1.srs" ;;
        *)         router_state | jq -r --arg t "$1" '.rule_sets[$t] // empty' ;;
    esac
}

# 一条规则的说明：匹配什么 → 去哪
router_rule_text() {   # <规则 JSON>
    printf '%s' "$1" | jq -r '
        (._label // ([.rule_set // [], .domain_suffix // [], .ip_cidr // []] | add | join(", "))) as $what
        | (if .action == "reject" then "拒绝" elif .outbound == "direct" then "直连" else "出口 " + .outbound end) as $to
        | "\($what) → \($to)"'
}

# 生成 sing-box 配置：先写临时文件让 sing-box 检查，通过了才替换
router_write_config() {
    local state tags tag url rule_sets tmp
    state=$(router_state)
    tags=$(printf '%s' "$state" | jq -r '[.rules[].rule_set // [] | .[]] | unique | .[]')
    rule_sets='[]'
    for tag in $tags; do
        url=$(router_rule_set_url "$tag")
        [ -n "$url" ] || { echo -e "${RED}规则集 ${tag} 没有下载地址${RESET}"; return 1; }
        rule_sets=$(printf '%s' "$rule_sets" | jq --arg t "$tag" --arg u "$url" \
            '. + [{type: "remote", tag: $t, format: "binary", url: $u, download_detour: "direct", update_interval: "1d"}]')
    done
    tmp="${ROUTER_CONFIG}.tmp"
    # 关了 IPv6 的机器上监听 :: 会失败
    local listen="::"
    [ -s /proc/net/if_inet6 ] || listen="0.0.0.0"
    printf '%s' "$state" | jq --argjson rs "$rule_sets" --argjson tp "$ROUTER_TCP_PORT" --argjson up "$ROUTER_UDP_PORT" --arg cache "${ROUTER_DIR}/cache.db" --arg l "$listen" '
        {
          log: {level: "warn", timestamp: true},
          dns: {servers: [{type: "local", tag: "local"}]},
          inbounds: ([{type: "redirect", tag: "snell-tcp", listen: $l, listen_port: $tp}]
                     + (if .udp then [{type: "tproxy", tag: "snell-udp", listen: $l, listen_port: $up, network: "udp"}] else [] end)),
          outbounds: ([{type: "direct", tag: "direct"}] + .outbounds),
          route: {
            default_domain_resolver: "local",
            rules: ([{action: "sniff"}] + [.rules[] | with_entries(select(.key | startswith("_") | not))]),
            rule_set: $rs,
            final: "direct"
          },
          experimental: {cache_file: {enabled: true, path: $cache}}
        }
        + (if (.endpoints | length) > 0 then {endpoints: .endpoints} else {} end)' > "$tmp" || return 1
    if ! "$ROUTER_BIN" check -c "$tmp" 2>"${tmp}.err"; then
        echo -e "${RED}sing-box 不接受生成的配置：${RESET}"
        sed 's/^/   /' "${tmp}.err"
        rm -f "$tmp" "${tmp}.err"
        return 1
    fi
    rm -f "${tmp}.err"
    chmod 600 "$tmp"
    mv "$tmp" "$ROUTER_CONFIG"
}

# 下载固定版本的 sing-box（官方发布）
router_install_singbox() {
    local arch tmp url
    if [ -x "$ROUTER_BIN" ] && "$ROUTER_BIN" version 2>/dev/null | grep -q "version ${ROUTER_SINGBOX_VERSION}\$"; then
        return 0
    fi
    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l|armv7) arch="armv7" ;;
        i386|i686) arch="386" ;;
        *) echo -e "${RED}不支持的架构：$(uname -m)${RESET}"; return 1 ;;
    esac
    ensure_cmds curl tar || return 1
    url="https://github.com/SagerNet/sing-box/releases/download/v${ROUTER_SINGBOX_VERSION}/sing-box-${ROUTER_SINGBOX_VERSION}-linux-${arch}.tar.gz"
    echo -e "${CYAN}正在下载 sing-box ${ROUTER_SINGBOX_VERSION}...${RESET}"
    tmp=$(mktemp -d) || return 1
    if ! curl -fL --retry 2 -o "${tmp}/sb.tar.gz" "$url" || ! tar -xzf "${tmp}/sb.tar.gz" -C "$tmp"; then
        echo -e "${RED}下载 sing-box 失败：${url}${RESET}"
        rm -rf "$tmp"
        return 1
    fi
    install -m 755 "${tmp}/sing-box-${ROUTER_SINGBOX_VERSION}-linux-${arch}/sing-box" "$ROUTER_BIN"
    rm -rf "$tmp"
    "$ROUTER_BIN" version | head -1
}

# 拦截规则的 up / down 脚本（服务起停时由 systemd 调用）
router_write_net_script() {
    local udp
    udp=$(router_state | jq -r '.udp')
    cat > "$ROUTER_NET" <<EOF
#!/bin/bash
# 由 snell.sh 生成：把 snell 用户新发起的连接交给 snell-router（sing-box）。
# up 时先等 sing-box 监听再接管；down 撤掉一切，Snell 回到直连。
SNELL_UID=\$(id -u ${SNELL_SERVICE_USER} 2>/dev/null) || { echo "没有 ${SNELL_SERVICE_USER} 用户" >&2; exit 1; }
TCP_PORT=${ROUTER_TCP_PORT}; UDP_PORT=${ROUTER_UDP_PORT}; MARK=${ROUTER_MARK}; TABLE=${ROUTER_TABLE}; UDP=${udp}

down() {
    nft delete table inet snell_router 2>/dev/null
    ip rule del fwmark \$MARK lookup \$TABLE pref \$TABLE 2>/dev/null
    ip -6 rule del fwmark \$MARK lookup \$TABLE pref \$TABLE 2>/dev/null
    ip route flush table \$TABLE 2>/dev/null
    ip -6 route flush table \$TABLE 2>/dev/null
    return 0
}

up() {
    down
    for i in \$(seq 1 50); do ss -Hltn "sport = :\$TCP_PORT" | grep -q . && break; sleep 0.2; done
    # 本机回环与 DNS 不拦：Snell 自己的域名解析照常；其余（含内网地址）交给规则决定
    nft -f - <<NFT || { down; exit 1; }
table inet snell_router {
    chain out_tcp {
        type nat hook output priority dstnat; policy accept;
        meta skuid \$SNELL_UID ct direction original meta l4proto tcp th dport 53 return
        meta skuid \$SNELL_UID ct direction original meta nfproto ipv4 meta l4proto tcp ip daddr != 127.0.0.0/8 redirect to :\$TCP_PORT
        meta skuid \$SNELL_UID ct direction original meta nfproto ipv6 meta l4proto tcp ip6 daddr != ::1 redirect to :\$TCP_PORT
    }
}
NFT
    [ "\$UDP" = true ] || return 0
    nft -f - <<NFT || { down; exit 1; }
table inet snell_router {
    chain out_udp {
        type route hook output priority mangle; policy accept;
        meta skuid \$SNELL_UID ct direction original meta l4proto udp th dport 53 return
        meta skuid \$SNELL_UID ct direction original meta nfproto ipv4 meta l4proto udp ip daddr != 127.0.0.0/8 meta mark set \$MARK
        meta skuid \$SNELL_UID ct direction original meta nfproto ipv6 meta l4proto udp ip6 daddr != ::1 meta mark set \$MARK
    }
    chain pre_udp {
        type filter hook prerouting priority mangle; policy accept;
        meta mark \$MARK meta nfproto ipv4 meta l4proto udp tproxy ip to 127.0.0.1:\$UDP_PORT accept
        meta mark \$MARK meta nfproto ipv6 meta l4proto udp tproxy ip6 to [::1]:\$UDP_PORT accept
    }
}
NFT
    ip rule add fwmark \$MARK lookup \$TABLE pref \$TABLE
    ip route add local 0.0.0.0/0 dev lo table \$TABLE
    if [ -s /proc/net/if_inet6 ]; then
        ip -6 rule add fwmark \$MARK lookup \$TABLE pref \$TABLE
        ip -6 route add local ::/0 dev lo table \$TABLE
    fi
    return 0
}

case "\$1" in
    up) up ;;
    down) down ;;
    *) echo "用法：\$0 up|down" >&2; exit 2 ;;
esac
EOF
    chmod 755 "$ROUTER_NET"
}

router_write_unit() {
    cat > "$ROUTER_UNIT" <<EOF
[Unit]
Description=Snell 规则分流（sing-box）
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${ROUTER_BIN} run -c ${ROUTER_CONFIG}
ExecStartPost=${ROUTER_NET} up
ExecStopPost=${ROUTER_NET} down
Restart=on-failure
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
}

# 各个 Snell 服务（snell、snell-<端口>）
router_snell_units() {
    local f n
    for f in "${SYSTEMD_DIR}"/snell*.service; do
        [ -f "$f" ] || continue
        n=$(basename "$f" .service)
        [[ "$n" =~ ^snell(-[0-9]+)?$ ]] && echo "$n"
    done
    return 0
}

# 不是以 snell 用户运行的 Snell 服务（比如 PSM 装的）：加一个 drop-in 改用 snell 用户，
# 启动前把它的配置交给 snell 用户读（PSM 重写配置后也自己修好）
router_fix_service_users() {
    local unit user conf changed=false
    for unit in $(router_snell_units); do
        [ -f "${SYSTEMD_DIR}/${unit}.service.d/${ROUTER_DROPIN_NAME}" ] && continue
        user=$(systemctl show -p User --value "$unit" 2>/dev/null)
        [ "$user" = "$SNELL_SERVICE_USER" ] && continue
        conf=$(sed -n 's/^ExecStart=[^ ]* -c \([^ ]*\).*/\1/p' "${SYSTEMD_DIR}/${unit}.service" | head -n 1)
        ensure_snell_service_user
        mkdir -p "${SYSTEMD_DIR}/${unit}.service.d"
        {
            echo "# 由 snell.sh 规则分流添加：分流按 snell 用户识别 Snell 的流量"
            echo "[Service]"
            echo "User=${SNELL_SERVICE_USER}"
            echo "Group=${SNELL_SERVICE_GROUP}"
            echo "AmbientCapabilities=CAP_NET_BIND_SERVICE"
            [ -n "$conf" ] && echo "ExecStartPre=+/bin/chown ${SNELL_SERVICE_USER}:${SNELL_SERVICE_GROUP} ${conf}"
        } > "${SYSTEMD_DIR}/${unit}.service.d/${ROUTER_DROPIN_NAME}"
        echo -e "${YELLOW}${unit} 原先以 ${user:-root} 运行，已改为 ${SNELL_SERVICE_USER} 用户（drop-in，原服务文件不动）${RESET}"
        changed=true
        UNITS_TO_RESTART="${UNITS_TO_RESTART} ${unit}"
    done
    if [ "$changed" = true ]; then systemctl daemon-reload; fi
}

router_remove_dropins() {
    local d unit
    for d in "${SYSTEMD_DIR}"/snell*.service.d; do
        [ -f "${d}/${ROUTER_DROPIN_NAME}" ] || continue
        rm -f "${d}/${ROUTER_DROPIN_NAME}"
        rmdir "$d" 2>/dev/null || true
        unit=$(basename "$d" .service.d)
        systemctl daemon-reload
        systemctl is-active --quiet "$unit" && systemctl restart "$unit"
    done
    return 0
}

# 启用（或按当前规则重新生成并重启）
router_enable() {
    if systemctl is-enabled --quiet snell.socket 2>/dev/null || systemctl is-active --quiet snell.socket 2>/dev/null; then
        echo -e "${RED}出口控制（netns）开着：那时 Snell 的流量不在本机发起，分流拦不到。请先在菜单 11 关闭出口控制。${RESET}"
        return 1
    fi
    if [ -z "$(router_snell_units)" ]; then
        echo -e "${RED}没有找到 Snell 服务，请先安装 Snell。${RESET}"
        return 1
    fi
    ensure_cmds jq nft ip ss || return 1
    router_install_singbox || return 1
    [ -s "$ROUTER_STATE" ] || router_save_state "$(router_state)"
    router_write_config || return 1
    router_write_net_script
    router_write_unit
    UNITS_TO_RESTART=""
    router_fix_service_users
    systemctl daemon-reload
    systemctl enable snell-router >/dev/null 2>&1
    if ! restart_and_verify_service snell-router; then
        echo -e "${RED}snell-router 没有起来，拦截规则已撤掉，Snell 仍是直连。${RESET}"
        return 1
    fi
    local unit
    for unit in $UNITS_TO_RESTART; do restart_and_verify_service "$unit" || true; done
    echo -e "${GREEN}✓ 规则分流已启用（$(router_state | jq '.rules | length') 条规则，其余直连）${RESET}"
}

# 停用：服务、拦截规则、drop-in 都撤掉，规则与出口保留（再启用时还在）
router_disable() {
    systemctl stop snell-router 2>/dev/null
    systemctl disable snell-router 2>/dev/null
    [ -x "$ROUTER_NET" ] && "$ROUTER_NET" down
    router_remove_dropins
    echo -e "${GREEN}✓ 规则分流已停用，Snell 直连。规则与出口保留，再次启用即恢复。${RESET}"
}

# 卸载 Snell 时一起删干净
router_remove() {
    router_installed || [ -d "$ROUTER_DIR" ] || return 0
    systemctl stop snell-router 2>/dev/null
    systemctl disable snell-router 2>/dev/null
    [ -x "$ROUTER_NET" ] && "$ROUTER_NET" down
    router_remove_dropins
    rm -f "$ROUTER_UNIT" "$ROUTER_NET" "$ROUTER_BIN"
    rm -rf "$ROUTER_DIR"
    systemctl daemon-reload 2>/dev/null || true
}

# 规则变了：正在运行就重新生成并重启
router_apply_if_active() {
    if router_active || systemctl is-enabled --quiet snell-router 2>/dev/null; then
        router_write_config && restart_and_verify_service snell-router && echo -e "${GREEN}✓ 已生效${RESET}"
    else
        echo -e "${YELLOW}已保存。分流尚未启用：在本菜单选「启用」后生效。${RESET}"
    fi
}

router_pick_outbound() {   # → ROUTER_PICK（direct / reject / 出口标签）
    local state tags i=3 pick
    state=$(router_state)
    tags=$(printf '%s' "$state" | jq -r '(.outbounds + .endpoints)[].tag')
    echo -e "${CYAN}匹配到的流量：${RESET}"
    echo -e "${GREEN}1.${RESET} 拒绝"
    echo -e "${GREEN}2.${RESET} 直连"
    local list=()
    for t in $tags; do
        echo -e "${GREEN}${i}.${RESET} 出口：${t}"
        list+=("$t")
        i=$((i + 1))
    done
    read -rp "请选择 [1-$((i - 1))]: " pick
    case "$pick" in
        1) ROUTER_PICK="reject" ;;
        2) ROUTER_PICK="direct" ;;
        *)
            if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 3 ] && [ "$pick" -lt "$i" ]; then
                ROUTER_PICK="${list[$((pick - 3))]}"
            else
                echo -e "${RED}无效选项${RESET}"
                return 1
            fi
            ;;
    esac
}

# 逗号分隔 → JSON 数组（去空格、去空项）
router_list_json() { printf '%s' "$1" | jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))'; }

router_add_rule() {
    local pick match label value
    echo -e "\n${CYAN}=== 添加规则：匹配什么 ===${RESET}"
    echo -e "${GREEN}1.${RESET} 广告与跟踪（geosite category-ads-all）"
    echo -e "${GREEN}2.${RESET} 中国大陆的网站与 IP（geosite cn + geoip cn）"
    echo -e "${GREEN}3.${RESET} 内网与局域网地址（防止客户端借服务器访问内网、云厂商元数据）"
    echo -e "${GREEN}4.${RESET} BT 下载"
    echo -e "${GREEN}5.${RESET} AI（OpenAI、Anthropic、Gemini、Perplexity）"
    echo -e "${GREEN}6.${RESET} 流媒体（Netflix、Disney+、HBO、Prime Video、Hulu）"
    echo -e "${GREEN}7.${RESET} geosite 分类（输入名称，如 google、telegram，可多个）"
    echo -e "${GREEN}8.${RESET} geoip 国家 / 地区（输入代码，如 cn、ir，可多个）"
    echo -e "${GREEN}9.${RESET} 域名后缀（如 example.com，可多个，逗号分隔）"
    echo -e "${GREEN}10.${RESET} IP 段（如 1.2.3.0/24，可多个）"
    echo -e "${GREEN}11.${RESET} 远程规则集（sing-box .srs 的地址）"
    echo -e "${GREEN}0.${RESET} 返回"
    read -rp "请选择 [0-11]: " pick
    case "$pick" in
        1) match='{"rule_set": ["geosite-category-ads-all"]}'; label="广告与跟踪" ;;
        2) match='{"rule_set": ["geosite-cn", "geoip-cn"]}'; label="中国大陆" ;;
        3) match='{"ip_is_private": true}'; label="内网地址" ;;
        4) match='{"protocol": ["bittorrent"]}'; label="BT 下载" ;;
        5) match='{"rule_set": ["geosite-openai", "geosite-anthropic", "geosite-google-gemini", "geosite-perplexity"]}'; label="AI" ;;
        6) match='{"rule_set": ["geosite-netflix", "geosite-disney", "geosite-hbo", "geosite-primevideo", "geosite-hulu"]}'; label="流媒体" ;;
        7|8)
            local kind; [ "$pick" = 7 ] && kind="geosite" || kind="geoip"
            read -rp "输入 ${kind} 名称（逗号分隔）: " value
            match=$(router_list_json "$value" | jq -c --arg k "$kind" 'map(ascii_downcase | select(test("^[a-z0-9@!._-]+$")) | "\($k)-\(.)") | {rule_set: .}')
            label="${kind} ${value}"
            ;;
        9)
            read -rp "输入域名后缀（逗号分隔）: " value
            match=$(router_list_json "$value" | jq -c '{domain_suffix: .}')
            label="域名 ${value}"
            ;;
        10)
            read -rp "输入 IP 段（逗号分隔）: " value
            match=$(router_list_json "$value" | jq -c '{ip_cidr: .}')
            label="IP ${value}"
            ;;
        11)
            read -rp "规则集地址（https://…）: " value
            if [[ ! "$value" =~ ^https://[^[:space:]]+$ ]]; then echo -e "${RED}要一个 https 地址${RESET}"; return 1; fi
            local tag="custom-$(printf '%s' "$value" | sha256sum | cut -c1-8)"
            router_save_state "$(router_state | jq --arg t "$tag" --arg u "$value" '.rule_sets[$t] = $u')"
            match=$(jq -nc --arg t "$tag" '{rule_set: [$t]}')
            label="规则集 ${value##*/}"
            ;;
        0|"") return 0 ;;
        *) echo -e "${RED}无效选项${RESET}"; return 1 ;;
    esac
    if [ -z "$match" ] || printf '%s' "$match" | jq -e 'to_entries[0].value | (type == "array" and length == 0)' >/dev/null; then
        echo -e "${RED}没有可用的匹配项${RESET}"
        return 1
    fi
    router_pick_outbound || return 1
    local rule
    if [ "$ROUTER_PICK" = "reject" ]; then
        rule=$(printf '%s' "$match" | jq -c --arg l "$label" '. + {action: "reject", _label: $l}')
    else
        rule=$(printf '%s' "$match" | jq -c --arg l "$label" --arg o "$ROUTER_PICK" '. + {outbound: $o, _label: $l}')
    fi
    router_save_state "$(router_state | jq --argjson r "$rule" '.rules += [$r]')"
    echo -e "${GREEN}✓ 已添加：$(router_rule_text "$rule")${RESET}"
    router_apply_if_active
}

router_delete_rule() {
    local n pick
    n=$(router_state | jq '.rules | length')
    if [ "$n" -eq 0 ]; then echo -e "${YELLOW}还没有规则${RESET}"; return 0; fi
    router_list_rules
    read -rp "删除第几条 [1-${n}]（0 返回）: " pick
    [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "$n" ] || return 0
    router_save_state "$(router_state | jq --argjson i "$((pick - 1))" 'del(.rules[$i])')"
    echo -e "${GREEN}✓ 已删除${RESET}"
    router_apply_if_active
}

router_list_rules() {
    local i=1 rule
    while IFS= read -r rule; do
        [ -n "$rule" ] || continue
        echo -e "  ${GREEN}${i}.${RESET} $(router_rule_text "$rule")"
        i=$((i + 1))
    done < <(router_state | jq -c '.rules[]')
    echo -e "  ${CYAN}其余 → 直连${RESET}"
}

router_add_outbound() {
    local pick tag server port user pass method ob
    echo -e "\n${CYAN}=== 添加出口 ===${RESET}"
    echo -e "${GREEN}1.${RESET} SOCKS5"
    echo -e "${GREEN}2.${RESET} HTTP 代理"
    echo -e "${GREEN}3.${RESET} Shadowsocks"
    echo -e "${GREEN}4.${RESET} WireGuard（如 Cloudflare WARP，填 wgcf 等工具生成的参数）"
    echo -e "${GREEN}0.${RESET} 返回"
    read -rp "请选择 [0-4]: " pick
    [ "$pick" = "0" ] || [ -z "$pick" ] && return 0
    read -rp "出口名称（字母、数字、- _）: " tag
    if [[ ! "$tag" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || [ "$tag" = "direct" ]; then echo -e "${RED}名称无效${RESET}"; return 1; fi
    if router_state | jq -e --arg t "$tag" '(.outbounds + .endpoints) | any(.tag == $t)' >/dev/null; then
        echo -e "${RED}已有同名出口${RESET}"; return 1
    fi
    case "$pick" in
        1|2|3)
            read -rp "服务器地址: " server
            read -rp "端口: " port
            [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { echo -e "${RED}端口无效${RESET}"; return 1; }
            ;;
    esac
    case "$pick" in
        1|2)
            read -rp "用户名（没有就回车）: " user
            read -rp "密码（没有就回车）: " pass
            ob=$(jq -nc --arg ty "$([ "$pick" = 1 ] && echo socks || echo http)" --arg t "$tag" --arg s "$server" --argjson p "$port" --arg u "$user" --arg pw "$pass" '
                {type: $ty, tag: $t, server: $s, server_port: $p}
                + (if $ty == "socks" then {version: "5"} else {} end)
                + (if $u != "" then {username: $u, password: $pw} else {} end)')
            router_save_state "$(router_state | jq --argjson o "$ob" '.outbounds += [$o]')"
            ;;
        3)
            read -rp "加密方式（如 2022-blake3-aes-128-gcm、aes-256-gcm）: " method
            read -rp "密码: " pass
            ob=$(jq -nc --arg t "$tag" --arg s "$server" --argjson p "$port" --arg m "$method" --arg pw "$pass" \
                '{type: "shadowsocks", tag: $t, server: $s, server_port: $p, method: $m, password: $pw}')
            router_save_state "$(router_state | jq --argjson o "$ob" '.outbounds += [$o]')"
            ;;
        4)
            local key addr peer_key endpoint reserved
            read -rp "本机私钥（PrivateKey）: " key
            read -rp "本机地址（Address，多个用逗号，如 172.16.0.2/32,2606:4700:110:8a36::1/128）: " addr
            read -rp "对端公钥（PublicKey）: " peer_key
            read -rp "对端地址:端口（Endpoint，如 162.159.192.1:2408）: " endpoint
            read -rp "reserved（WARP 用，如 1,2,3；没有就回车）: " reserved
            [[ "$endpoint" =~ ^(.+):([0-9]+)$ ]] || { echo -e "${RED}Endpoint 要写成 地址:端口${RESET}"; return 1; }
            ob=$(jq -nc --arg t "$tag" --arg k "$key" --argjson a "$(router_list_json "$addr")" --arg pk "$peer_key" \
                    --arg h "$(echo "${BASH_REMATCH[1]}" | tr -d '[]')" --argjson p "${BASH_REMATCH[2]}" --argjson r "$(router_list_json "$reserved" | jq -c 'map(tonumber)')" '
                {type: "wireguard", tag: $t, address: $a, private_key: $k, mtu: 1280,
                 peers: [{address: $h, port: $p, public_key: $pk, allowed_ips: ["0.0.0.0/0", "::/0"]}
                         + (if ($r | length) == 3 then {reserved: $r} else {} end)]}')
            router_save_state "$(router_state | jq --argjson o "$ob" '.endpoints += [$o]')"
            ;;
        *) echo -e "${RED}无效选项${RESET}"; return 1 ;;
    esac
    echo -e "${GREEN}✓ 已添加出口 ${tag}。在「添加规则」里选它，匹配的流量就从这里出去。${RESET}"
    router_apply_if_active
}

router_delete_outbound() {
    local tags pick i=1 list=()
    tags=$(router_state | jq -r '(.outbounds + .endpoints)[].tag')
    [ -n "$tags" ] || { echo -e "${YELLOW}还没有出口${RESET}"; return 0; }
    for t in $tags; do echo -e "  ${GREEN}${i}.${RESET} ${t}"; list+=("$t"); i=$((i + 1)); done
    read -rp "删除第几个（0 返回）: " pick
    [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -lt "$i" ] || return 0
    local tag="${list[$((pick - 1))]}"
    if router_state | jq -e --arg t "$tag" 'any(.rules[]; .outbound == $t)' >/dev/null; then
        echo -e "${RED}还有规则用着 ${tag}，先删掉那些规则${RESET}"
        return 1
    fi
    router_save_state "$(router_state | jq --arg t "$tag" '.outbounds |= map(select(.tag != $t)) | .endpoints |= map(select(.tag != $t))')"
    echo -e "${GREEN}✓ 已删除出口 ${tag}${RESET}"
    router_apply_if_active
}

router_toggle_udp() {
    local udp
    udp=$(router_state | jq -r '.udp')
    if [ "$udp" = true ]; then udp=false; else udp=true; fi
    router_save_state "$(router_state | jq --argjson u "$udp" '.udp = $u')"
    echo -e "${GREEN}✓ UDP 分流：$([ "$udp" = true ] && echo 开 || echo 关（UDP 直连）)${RESET}"
    if router_active; then router_enable; fi
}

# 菜单
router_menu() {
    ensure_cmds jq || return 1
    while true; do
        echo -e "\n${CYAN}=============== 规则分流（sing-box）===============${RESET}"
        echo -e "${YELLOW}Snell 仍是官方 snell-server；它连出去的流量按下面的规则走，其余直连。${RESET}"
        if router_active; then
            echo -e "${GREEN}状态：运行中（sing-box ${ROUTER_SINGBOX_VERSION}，UDP $(router_state | jq -r 'if .udp then "也分流" else "直连" end')）${RESET}"
        elif router_installed; then
            echo -e "${YELLOW}状态：已停用${RESET}"
        else
            echo -e "${YELLOW}状态：未启用${RESET}"
        fi
        echo -e "${CYAN}规则（从上往下，先匹配到的生效）：${RESET}"
        router_list_rules
        local obs
        obs=$(router_state | jq -r '[(.outbounds + .endpoints)[] | "\(.tag)（\(.type)）"] | join("、")')
        [ -n "$obs" ] && echo -e "${CYAN}出口：${RESET}${obs}"
        echo -e "\n${GREEN}1.${RESET} 启用 / 重新生成并重启"
        echo -e "${GREEN}2.${RESET} 添加规则"
        echo -e "${GREEN}3.${RESET} 删除规则"
        echo -e "${GREEN}4.${RESET} 添加出口（SOCKS5 / HTTP / Shadowsocks / WireGuard）"
        echo -e "${GREEN}5.${RESET} 删除出口"
        echo -e "${GREEN}6.${RESET} UDP 分流 开 / 关"
        echo -e "${GREEN}7.${RESET} 停用分流（恢复直连）"
        echo -e "${GREEN}8.${RESET} 查看日志"
        echo -e "${GREEN}0.${RESET} 返回"
        local choice
        read -rp "请选择 [0-8]: " choice || return 0
        case "$choice" in
            1) router_enable ;;
            2) router_add_rule ;;
            3) router_delete_rule ;;
            4) router_add_outbound ;;
            5) router_delete_outbound ;;
            6) router_toggle_udp ;;
            7) router_disable ;;
            8) journalctl -u snell-router -n 40 --no-pager 2>/dev/null ;;
            0|"") return 0 ;;
            *) echo -e "${RED}无效选项${RESET}" ;;
        esac
    done
}


#当前版本号
current_version="6.2"

# 出口控制（netns + socket activation）默认参数
EGRESS_FEATURE_ENABLED="false"
EGRESS_IFACE=""
EGRESS_NS="snell-egress"
EGRESS_HOST_IP=""
EGRESS_NS_IP=""
EGRESS_SUBNET=""
EGRESS_GW=""

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
# 服务加固：snell-server 只读配置、不写文件系统（与 netns 版 unit 保持一致）
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
ProtectKernelModules=yes
ReadOnlyPaths=/etc/snell
LimitNOFILE=32768
ExecStart=${snell_binary} -c ${SNELL_CONF_FILE}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
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
            mkdir -p "${SNELL_CONF_DIR}/users"
            # 设置正确的目录权限（配置文件含 PSK，仅属主可读写）
            ensure_snell_service_user
            chown -R "${SNELL_SERVICE_USER}:${SNELL_SERVICE_GROUP}" "${SNELL_CONF_DIR}"
            find "${SNELL_CONF_DIR}" -type d -exec chmod 755 {} +
            find "${SNELL_CONF_DIR}" -name "*.conf" -exec chmod 600 {} +
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

check_root

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

    # 白名单校验：这两个值会被写入 root 执行的初始化脚本，
    # 非法字符可能导致脚本损坏或命令注入
    if ! [[ "$EGRESS_IFACE" =~ ^[a-zA-Z0-9_.-]{1,15}$ ]]; then
        echo -e "${RED}接口名称不合法（只允许字母、数字、_ . -，最长 15 字符），已恢复为自动检测值${RESET}"
        auto_detect_egress_iface
    fi
    if ! [[ "$EGRESS_NS" =~ ^[a-zA-Z0-9_.-]{1,16}$ ]]; then
        echo -e "${YELLOW}命名空间名称不合法（只允许字母、数字、_ . -），已恢复默认值 snell-egress${RESET}"
        EGRESS_NS="snell-egress"
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

    ensure_cmds ip nft || exit 1
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
# listen_addr 可选：不传时从主配置的 listen 行推导，保证 socket 监听地址族与配置一致
# （之前写死 0.0.0.0，IPv6 用户开 egress 后 IPv6 监听会静默丢失）
write_snell_socket_service_units() {
    local listen_port=$1
    local listen_addr="${2:-}"
    local snell_binary
    snell_binary=$(main_snell_binary)

    if [ -z "$listen_addr" ] && [ -f "$SNELL_CONF_FILE" ]; then
        listen_addr=$(grep -E '^[[:space:]]*listen[[:space:]]*=' "$SNELL_CONF_FILE" | head -n 1 \
            | sed -n 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*\(.*\):[0-9][0-9]*[[:space:]]*$/\1/p')
    fi
    [ -z "$listen_addr" ] && listen_addr="0.0.0.0"

    local socket_stream="ListenStream=0.0.0.0:${listen_port}"
    local socket_datagram="ListenDatagram=0.0.0.0:${listen_port}"
    if [[ "$listen_addr" == *:* ]]; then
        socket_stream="ListenStream=[::]:${listen_port}"
        socket_datagram="ListenDatagram=[::]:${listen_port}"
    fi

    cat > ${SYSTEMD_SOCKET_FILE} << EOF
[Unit]
Description=Snell v5 (socket-activated)

[Socket]
${socket_stream}
${socket_datagram}
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

# 按端口释放监听进程：只自动处理 snell 相关进程；
# 非 snell 进程必须经用户明确确认才会结束，避免误杀 nginx/sshd 等服务
force_release_port_by_pid() {
    local port="$1"
    local pids pid cmd
    local snell_pids="" other_pids=""

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
            snell_pids="${snell_pids}${pid} "
        else
            other_pids="${other_pids}${pid} "
        fi
    done

    for pid in $snell_pids; do
        kill -TERM "$pid" 2>/dev/null || true
    done

    sleep 0.2

    if is_port_in_use "$port"; then
        if [ -n "$other_pids" ]; then
            echo -e "${RED}端口 ${port} 仍被以下非 Snell 进程占用:${RESET}"
            for pid in $other_pids; do
                echo -e "  PID ${pid}: $(ps -p "$pid" -o args= 2>/dev/null)"
            done
            echo -e "${YELLOW}是否强制结束这些进程以释放端口? [y/N]${RESET}"
            read -r kill_choice
            case "$kill_choice" in
                [yY]|[yY][eE][sS]) ;;
                *)
                    echo -e "${YELLOW}已取消，未释放端口 ${port}${RESET}"
                    return 1
                    ;;
            esac
            for pid in $other_pids; do
                kill -KILL "$pid" 2>/dev/null || true
            done
        else
            for pid in $snell_pids; do
                kill -KILL "$pid" 2>/dev/null || true
            done
        fi
    fi
    return 0
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
    # 用户拒绝释放非 snell 进程时直接中止，不再盲等 20 次
    force_release_port_by_pid "$port" || return 1

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
# 写管理命令 /usr/local/bin/snell：每次运行都经短域名取最新脚本（地址由 Cloudflare 重定向，
# 脚本在仓库里换位置也不用改这里）
write_management_script() {
    mkdir -p /usr/local/bin
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

# 下载并执行最新版本的脚本（带完整性校验：传输失败即停、非空、语法检查）
echo -e "${CYAN}正在获取最新版本的管理脚本...${RESET}"
TMP_SCRIPT=$(mktemp)
if curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 https://snell.jinqians.com -o "$TMP_SCRIPT" \
    && [ -s "$TMP_SCRIPT" ] && bash -n "$TMP_SCRIPT" 2>/dev/null; then
    bash "$TMP_SCRIPT"
    rm -f "$TMP_SCRIPT"
else
    echo -e "${RED}下载或校验脚本失败，请检查网络连接。${RESET}"
    rm -f "$TMP_SCRIPT"
    exit 1
fi
EOFSCRIPT
    chmod +x /usr/local/bin/snell
}

# 旧版写的管理命令直连 raw.githubusercontent.com 上的固定路径（snell.sh / snell-centos.sh），
# 换成走短域名的新写法；不是本脚本写的文件不动
upgrade_management_script() {
    [ -f /usr/local/bin/snell ] || return 0
    grep -q 'raw.githubusercontent.com/jinqians/snell.sh/' /usr/local/bin/snell 2>/dev/null || return 0
    write_management_script && echo -e "${GREEN}已更新 snell 管理命令（改为经 snell.jinqians.com 获取最新脚本）${RESET}"
}

# 读主配置里 key = value 的值（取第一个 = 之后的全部，base64 PSK 里的 = 不会被截掉）
main_conf_value() {
    grep -E "^[[:space:]]*$1[[:space:]]*=" "$SNELL_CONF_FILE" 2>/dev/null | head -n 1 \
        | sed -e 's/^[^=]*=[[:space:]]*//' -e 's/[[:space:]]*$//'
}

install_snell() {
    echo -e "${CYAN}正在安装 Snell${RESET}"

    # 已存在主配置时先让用户选择，避免误触重装导致端口/PSK 被静默轮换
    local keep_existing_conf="false"
    if [ -f "$SNELL_CONF_FILE" ]; then
        local old_port old_ver
        old_port=$(get_snell_port)
        old_ver=$(get_conf_snell_version "$SNELL_CONF_FILE" 2>/dev/null)
        echo -e "${YELLOW}检测到已存在主用户配置：${SNELL_CONF_FILE}${RESET}"
        [ -n "$old_port" ] && echo -e "${YELLOW}  当前端口: ${old_port}${RESET}"
        [ -n "$old_ver" ] && echo -e "${YELLOW}  当前版本通道: ${old_ver}${RESET}"
        echo -e "${GREEN}1.${RESET} 保留现有端口和 PSK（仅重装二进制/修复服务）"
        echo -e "${GREEN}2.${RESET} 全新安装（重新生成端口和 PSK）"
        echo -e "${GREEN}0.${RESET} 取消"
        local reinstall_choice
        if ! read -rp "请输入选项 [0-2]: " reinstall_choice; then
            echo
            echo -e "${YELLOW}已取消安装。${RESET}"
            return 0
        fi
        case "$reinstall_choice" in
            1) keep_existing_conf="true" ;;
            2) keep_existing_conf="false" ;;
            0)
                echo -e "${YELLOW}已取消安装。${RESET}"
                return 0
                ;;
            *)
                echo -e "${RED}无效的选项，已取消安装。${RESET}"
                return 1
                ;;
        esac
    fi

    if [ "$keep_existing_conf" = "true" ]; then
        # 沿用已有配置的版本通道重装二进制，不重新询问安装参数
        SNELL_VERSION_CHOICE=$(get_conf_snell_version "$SNELL_CONF_FILE" 2>/dev/null)
        case "$SNELL_VERSION_CHOICE" in
            v4|v5|v6) ;;
            *)
                echo -e "${YELLOW}无法识别已有配置的版本通道，请手动选择要重装的版本。${RESET}"
                select_snell_version
                ;;
        esac
        # 从已有配置读取端口/PSK 等信息，供后续开防火墙、启服务、展示配置使用
        PORT=$(get_snell_port)
        PSK=$(main_conf_value psk)
        IPV6_ENABLE=$(main_conf_value ipv6)
        if [ -z "$IPV6_ENABLE" ]; then
            # v6 配置没有 ipv6 键，按 dns-ip-preference 推断（仅用于安装总结展示，不改配置）
            if [ "$(main_conf_value dns-ip-preference)" = "ipv4-only" ]; then
                IPV6_ENABLE="false"
            else
                IPV6_ENABLE="true"
            fi
        fi
        DNS=$(main_conf_value dns)
        [ -z "$DNS" ] && DNS="8.8.8.8"
        if [ -z "$PORT" ] || [ -z "$PSK" ]; then
            echo -e "${RED}已有配置缺少端口或 PSK，可能已损坏，请选择全新安装。${RESET}"
            return 1
        fi
        # 磁盘上已有 socket 单元说明之前启用了出口控制，沿用该模式
        # （netns 初始化脚本不重写：重写需要安装时的接口/子网参数，磁盘上的已是正确的）
        if [ -f "$SYSTEMD_SOCKET_FILE" ]; then
            EGRESS_FEATURE_ENABLED="true"
            # 从磁盘上的 netns 初始化脚本还原接口/命名空间名，socket 单元与安装总结要用
            if [ -f "${NETNS_SETUP_SCRIPT}" ]; then
                local keep_ns keep_iface
                keep_ns=$(sed -n 's/^ip netns add \([A-Za-z0-9_.-]\{1,\}\).*/\1/p' "${NETNS_SETUP_SCRIPT}" | head -n 1)
                [ -n "$keep_ns" ] && EGRESS_NS="$keep_ns"
                keep_iface=$(grep -o 'oifname "[^"]*"' "${NETNS_SETUP_SCRIPT}" 2>/dev/null | head -n 1 | cut -d'"' -f2)
                [ -n "$keep_iface" ] && EGRESS_IFACE="$keep_iface"
            fi
        else
            EGRESS_FEATURE_ENABLED="false"
        fi
        echo -e "${GREEN}将保留现有端口和 PSK，仅重装二进制并重写服务单元。${RESET}"
    else
        # 选择 Snell 版本
        select_snell_version
    fi

    ensure_cmds curl unzip || exit 1

    # 若机器上还是旧的单版本布局，先迁成版本化布局，避免装新通道时覆盖掉在用的二进制
    migrate_snell_binary_layout

    # 安装（或强制重装）所选通道的二进制，其他通道原样保留
    if ! install_snell_binary_for_version "$SNELL_VERSION_CHOICE" "true"; then
        echo -e "${RED}安装 Snell ${SNELL_VERSION_CHOICE} 失败。${RESET}"
        exit 1
    fi

    # 主用户所用通道决定 snell-server 软链指向
    update_snell_symlink "$SNELL_VERSION_CHOICE"

    if [ "$keep_existing_conf" != "true" ]; then
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
    fi

    write_main_systemd_service

    if [ "$EGRESS_FEATURE_ENABLED" = "true" ]; then
        # 保留模式沿用磁盘上的 netns 初始化脚本；snell.service 刚被改写成普通版，
        # socket 版的单元要重新写回（监听地址从配置里推导）
        if [ "$keep_existing_conf" != "true" ]; then
            write_snell_netns_service
            write_snell_socket_service_units "$PORT" "$LISTEN_ADDR"
        else
            write_snell_socket_service_units "$PORT"
        fi
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
    echo -e "${YELLOW}IPv6: ${IPV6_ENABLE}${RESET}"
    echo -e "${YELLOW}DNS 服务器: ${DNS}${RESET}"
    echo -e "${CYAN}--------------------------------${RESET}"

    # 获取并显示服务器IP地址
    echo -e "\n${GREEN}服务器地址信息：${RESET}"
    
    # 获取 IPv4 地址
    IPV4_ADDR=$(get_public_ipv4)
    if [ $? -eq 0 ] && [ ! -z "$IPV4_ADDR" ]; then
        IP_COUNTRY_IPV4=$(get_ip_country "${IPV4_ADDR}")
        echo -e "${GREEN}IPv4 地址: ${RESET}${IPV4_ADDR} ${GREEN}所在国家: ${RESET}${IP_COUNTRY_IPV4}"
    fi

    # 获取 IPv6 地址
    IPV6_ADDR=$(get_public_ipv6)
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
    if write_management_script; then
        echo -e "\n${GREEN}管理脚本安装成功！${RESET}"
        echo -e "${YELLOW}您可以在终端输入 'snell' 进入管理菜单。${RESET}"
        echo -e "${YELLOW}注意：需要使用 sudo snell 或以 root 身份运行。${RESET}\n"
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
            if router_active; then
                echo -e "${RED}规则分流正在运行：出口控制把 Snell 放进单独的网络命名空间后，分流就拦不到它的流量。请先在菜单 12 停用分流。${RESET}"
                return 1
            fi
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
            if [ "$installed_version" = "v6" ]; then
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

    # 规则分流（sing-box）一起删掉：拦截规则、服务、配置
    router_remove

    # 停止并删除依赖 Snell 后端的 ShadowTLS 服务，避免留下无后端的监听服务
    local snell_shadowtls_services
    snell_shadowtls_services=$(find "${SYSTEMD_DIR}" -maxdepth 1 -name "shadowtls-snell-*.service" 2>/dev/null)
    if [ -n "$snell_shadowtls_services" ]; then
        while IFS= read -r service_file; do
            [ -z "$service_file" ] && continue
            local service_name
            service_name=$(basename "$service_file")
            local shadowtls_port
            shadowtls_port=$(sed -n 's/.*--listen [^ ]*:\([0-9][0-9]*\).*/\1/p' "$service_file" | head -n 1)
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

    # 清理出口控制残留：netns / veth / nft 表 / FORWARD 规则 / /etc/netns（不存在时静默跳过）
    # 命名空间名以 netns 初始化脚本中的实际值为准（用户可能自定义过），取不到则用默认值
    local egress_ns="${EGRESS_NS:-snell-egress}"
    if [ -f "${NETNS_SETUP_SCRIPT}" ]; then
        local script_ns
        script_ns=$(sed -n 's/^ip netns add \([A-Za-z0-9_.-]\{1,\}\).*/\1/p' "${NETNS_SETUP_SCRIPT}" | head -n 1)
        [ -n "$script_ns" ] && egress_ns="$script_ns"
    fi
    if command -v ip >/dev/null 2>&1; then
        [ -n "$egress_ns" ] && ip netns del "$egress_ns" 2>/dev/null || true
        # 删除 veth 对（删除一端，另一端自动消失）
        ip link del veth-host 2>/dev/null || true
    fi
    if [ -n "$egress_ns" ]; then
        rm -rf "/etc/netns/${egress_ns}" 2>/dev/null
    fi
    if command -v nft >/dev/null 2>&1; then
        # 精确删除本脚本建过的两张表（netns 初始化脚本建表处可查）
        nft delete table ip snell_nat 2>/dev/null || true
        nft delete table inet snell_filter 2>/dev/null || true
    fi
    if command -v iptables >/dev/null 2>&1; then
        # netns 脚本只加过含 veth-host 的 FORWARD 规则，按系统实际规则逐条精确删除
        local fwd_del
        while fwd_del=$(iptables -S FORWARD 2>/dev/null | grep -- '-A FORWARD.*veth-host' | head -n 1 | sed 's/^-A /-D /'); do
            [ -z "$fwd_del" ] && break
            # shellcheck disable=SC2086
            iptables $fwd_del 2>/dev/null || break
        done
    fi

    # 删除服务文件（含旧版 CentOS 脚本写的 preset）
    rm -f /lib/systemd/system/snell.service
    rm -f ${SYSTEMD_SERVICE_FILE}
    rm -f ${SYSTEMD_SOCKET_FILE}
    rm -f ${SYSTEMD_NETNS_FILE}
    rm -f ${NETNS_SETUP_SCRIPT}
    rm -f /usr/lib/systemd/system-preset/90-snell.preset

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

    # snell 系统用户/组默认保留，询问后才删除
    echo -e "${YELLOW}是否同时删除 snell 系统用户和用户组？[y/N]${RESET}"
    local del_snell_user
    if ! read -r del_snell_user; then
        del_snell_user=""
    fi
    if [[ "$del_snell_user" =~ ^[Yy]$ ]]; then
        if getent passwd snell >/dev/null 2>&1; then
            userdel snell 2>/dev/null && echo -e "${GREEN}已删除系统用户 snell${RESET}"
        fi
        if getent group snell >/dev/null 2>&1; then
            groupdel snell 2>/dev/null && echo -e "${GREEN}已删除用户组 snell${RESET}"
        fi
    else
        echo -e "${YELLOW}已保留 snell 系统用户和用户组。${RESET}"
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

    # 规则分流（只在启用过时显示）
    if router_active; then
        echo -e "${GREEN}规则分流 运行中${RESET}  ${YELLOW}$(jq '.rules | length' "$ROUTER_STATE" 2>/dev/null || echo 0) 条规则${RESET}"
    elif router_installed; then
        echo -e "${YELLOW}规则分流 已停用${RESET}"
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
    IPV4_ADDR=$(get_public_ipv4)
    if [ $? -eq 0 ] && [ ! -z "$IPV4_ADDR" ]; then
        IP_COUNTRY_IPV4=$(get_ip_country "${IPV4_ADDR}")
        echo -e "${GREEN}IPv4 地址: ${RESET}${IPV4_ADDR} ${GREEN}所在国家: ${RESET}${IP_COUNTRY_IPV4}"
    fi

    # 获取 IPv6 地址
    IPV6_ADDR=$(get_public_ipv6)
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

# 更新脚本
update_script() {
    echo -e "${CYAN}正在检查脚本更新...${RESET}"
    
    # 创建临时文件
    local TMP_SCRIPT
    TMP_SCRIPT=$(mktemp)

    # 下载最新版本（带完整性校验）
    if fetch_verified_script "$SNELL_SCRIPT_URL" "$TMP_SCRIPT"; then
        # 获取新版本号
        new_version=$(grep -m1 -E '^current_version="' "$TMP_SCRIPT" | cut -d'"' -f2)

        # 版本号格式必须合法，防止下载到错误内容后误更新
        if ! [[ "$new_version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
            echo -e "${RED}下载的脚本版本号格式异常，已中止更新${RESET}"
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

# 初始检查
initial_check() {
    check_root
    # bc：状态里的 CPU / 内存合计
    ensure_cmds curl bc || exit 1
    check_and_migrate_config
    # 旧的单版本布局迁到按通道分开存；已经是新布局时什么都不做
    if [ -e "${INSTALL_DIR}/snell-server" ]; then
        migrate_snell_binary_layout
    fi
    sync_existing_main_service_unit
    upgrade_management_script
}

# 运行初始检查
initial_check

# 下载子脚本到临时文件，校验通过后再执行
run_remote_script() {   # <url> <名称>
    local tmp_script
    tmp_script=$(mktemp) || return 1
    if fetch_verified_script "$1" "$tmp_script"; then
        bash "$tmp_script"
    else
        echo -e "${RED}${2}下载校验失败，已取消执行。${RESET}"
    fi
    rm -f "$tmp_script"
}

# 多用户管理
setup_multi_user() {
    echo -e "${CYAN}正在执行多用户管理脚本...${RESET}"
    run_remote_script "${SNELL_RAW_BASE}/scripts/multi-user.sh" "多用户管理脚本"

    # 多用户管理脚本执行完毕后会自动返回这里
    echo -e "${GREEN}多用户管理操作完成${RESET}"
    sleep 1  # 给用户一点时间看到提示
}

# ── 修改配置：端口 / PSK / DNS（主用户与多用户） ─────────────────────────────
# 配置里某个键的值（取第一个 = 之后的全部，base64 PSK 里的 = 不会被截掉）
conf_value() {   # <conf> <key>
    grep -E "^[[:space:]]*$2[[:space:]]*=" "$1" 2>/dev/null | head -n 1 \
        | sed -e 's/^[^=]*=[[:space:]]*//' -e 's/[[:space:]]*$//'
}
conf_port() { conf_value "$1" listen | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p'; }

# 把配置里某个键改成新值（没有这个键就加在末尾）；写回原文件，属主和权限不变
conf_set() {   # <conf> <key> <value>
    local tmp rc
    tmp=$(mktemp) || return 1
    awk -v k="$2" -v v="$3" '
        BEGIN { done = 0 }
        $0 ~ "^[[:space:]]*" k "[[:space:]]*=" && !done { print k " = " v; done = 1; next }
        { print }
        END { if (!done) print k " = " v }
    ' "$1" > "$tmp" && cat "$tmp" > "$1"
    rc=$?
    rm -f "$tmp"
    return $rc
}

# 改之前的样子：配置与相关 unit 各备一份（放在 /tmp 下的临时目录），失败时整体放回
_edit_backup_dir=""
edit_backup() {   # <文件>…
    local f
    _edit_backup_dir=$(mktemp -d /tmp/snell-edit.XXXXXX) || return 1
    for f in "$@"; do
        [ -e "$f" ] || continue
        mkdir -p "${_edit_backup_dir}$(dirname "$f")"
        cp -a "$f" "${_edit_backup_dir}${f}"
    done
}
edit_restore() {
    local f
    case "$_edit_backup_dir" in /tmp/snell-edit.*) ;; *) return 0 ;; esac
    while IFS= read -r f; do
        cp -a "${_edit_backup_dir}${f}" "$f"
    done < <(cd "$_edit_backup_dir" && find . -type f | sed 's|^\.||')
    edit_forget_backup
}
edit_forget_backup() {
    case "$_edit_backup_dir" in /tmp/snell-edit.*) rm -rf -- "${_edit_backup_dir:?}" ;; esac
    _edit_backup_dir=""
}

# 端口给了另一个 Snell 配置用
port_taken_by_snell() {   # <port> <除外的 conf>
    local f
    for f in "$SNELL_CONF_FILE" "${SNELL_CONF_DIR}"/users/*.conf; do
        [ -f "$f" ] && [ "$f" != "$2" ] && [ "$(conf_port "$f")" = "$1" ] && return 0
    done
    return 1
}

edit_snell_port() {   # <conf> <service>
    local conf="$1" service="$2" old new host version ns
    old=$(conf_port "$conf")
    host=$(conf_value "$conf" listen | sed 's/:[0-9]*$//')
    while true; do
        read -rp "新端口（1-65535，直接回车取消）: " new || return 0
        [ -z "$new" ] && return 0
        if ! [[ "$new" =~ ^[0-9]+$ ]] || [ "$new" -lt 1 ] || [ "$new" -gt 65535 ]; then
            echo -e "${RED}端口要是 1 到 65535 之间的数字${RESET}"; continue
        fi
        [ "$new" = "$old" ] && { echo -e "${YELLOW}和现在的端口一样${RESET}"; continue; }
        if port_taken_by_snell "$new" "$conf"; then
            echo -e "${RED}端口 ${new} 已经给另一个 Snell 用户用了${RESET}"; continue
        fi
        if is_port_in_use "$new"; then
            echo -e "${RED}端口 ${new} 正被别的程序占用：${RESET}"; show_port_occupier "$new"; continue
        fi
        break
    done

    local unit_dir="${SYSTEMD_DIR:?}"
    local stls_old="${unit_dir}/shadowtls-snell-${old}.service"
    local stls_new="${unit_dir}/shadowtls-snell-${new}.service"
    local new_conf="$conf" new_service="snell"
    version=$(get_conf_snell_version "$conf")
    if [ "$service" != "snell" ]; then
        new_conf="${SNELL_CONF_DIR:?}/users/snell-${new}.conf"; new_service="snell-${new}"
    fi
    local socket_mode=false
    [ "$service" = "snell" ] && systemctl is-enabled --quiet snell.socket 2>/dev/null && socket_mode=true
    edit_backup "$conf" "${unit_dir}/${service}.service" "$SYSTEMD_SOCKET_FILE" "$stls_old"

    # 先停，改完一起起来
    [ -f "$stls_old" ] && systemctl stop "shadowtls-snell-${old}" 2>/dev/null
    if $socket_mode; then systemctl stop snell snell.socket 2>/dev/null; else systemctl stop "$service" 2>/dev/null; fi

    local ok=true
    conf_set "$conf" listen "${host}:${new}" || ok=false
    if $ok && [ "$service" != "snell" ]; then
        # 多用户：配置与 unit 都按端口命名
        systemctl disable "$service" 2>/dev/null
        if mv "$conf" "$new_conf"; then
            rm -f -- "${unit_dir}/snell-${old}.service"
            write_user_service_unit "$new" "$new_conf" "$version"
            [ -d "${unit_dir}/snell-${old}.service.d" ] && mv "${unit_dir}/snell-${old}.service.d" "${unit_dir}/snell-${new}.service.d"
            systemctl daemon-reload
            systemctl enable "$new_service" 2>/dev/null
        else
            ok=false
        fi
    fi
    if $ok && [ -f "$stls_old" ]; then
        # 前面的 ShadowTLS：后端改成新端口，unit 跟着端口改名
        systemctl disable "shadowtls-snell-${old}" 2>/dev/null
        if sed "s|--server 127.0.0.1:${old} |--server 127.0.0.1:${new} |" "$stls_old" > "$stls_new"; then
            rm -f -- "$stls_old"
            systemctl daemon-reload
            systemctl enable "shadowtls-snell-${new}" 2>/dev/null
        else
            ok=false
        fi
    fi

    if $ok; then
        if $socket_mode; then
            # 出口控制（socket 激活）：按新端口重写 socket 单元再拉起
            if [ -f "${NETNS_SETUP_SCRIPT}" ]; then
                ns=$(sed -n 's/^ip netns add \([A-Za-z0-9_.-]\{1,\}\).*/\1/p' "${NETNS_SETUP_SCRIPT}" | head -n 1)
                [ -n "$ns" ] && EGRESS_NS="$ns"
            fi
            write_snell_socket_service_units "$new"
            systemctl daemon-reload
            start_egress_runtime "$new" >/dev/null || ok=false
        else
            restart_and_verify_service "$new_service" || ok=false
        fi
    fi
    if $ok && [ -f "$stls_new" ]; then
        restart_and_verify_service "shadowtls-snell-${new}" || ok=false
    fi

    if ! $ok; then
        echo -e "${RED}改端口没成功，正在还原…${RESET}"
        systemctl stop "$new_service" "shadowtls-snell-${new}" 2>/dev/null
        systemctl disable "$new_service" "shadowtls-snell-${new}" 2>/dev/null
        if [ "$service" != "snell" ]; then
            rm -f -- "${unit_dir}/snell-${new}.service" "${SNELL_CONF_DIR:?}/users/snell-${new}.conf"
            [ -d "${unit_dir}/snell-${new}.service.d" ] && mv "${unit_dir}/snell-${new}.service.d" "${unit_dir}/snell-${old}.service.d"
        fi
        [ -f "$stls_new" ] && rm -f -- "$stls_new"
        edit_restore
        systemctl daemon-reload
        systemctl enable "$service" 2>/dev/null
        [ -f "$stls_old" ] && systemctl enable "shadowtls-snell-${old}" 2>/dev/null
        if $socket_mode; then start_egress_runtime "$old" >/dev/null; else restart_and_verify_service "$service" >/dev/null; fi
        [ -f "$stls_old" ] && systemctl restart "shadowtls-snell-${old}" 2>/dev/null
        echo -e "${YELLOW}已还原为端口 ${old}${RESET}"
        return 1
    fi
    edit_forget_backup

    # 防火墙：只在 Snell 自己对外监听时开关（前面有 ShadowTLS 时它只听 127.0.0.1）
    if [ "$host" != "127.0.0.1" ]; then
        close_port "$old" >/dev/null 2>&1
        open_port "$new"
    fi
    echo -e "${GREEN}✓ 端口已改为 ${new}${RESET}"
    [ -f "$stls_new" ] && echo -e "${YELLOW}前面有 ShadowTLS：客户端仍连 ShadowTLS 的端口，不用改${RESET}"
    EDIT_CONF="$new_conf"; EDIT_SERVICE="$new_service"
}

edit_snell_psk() {   # <conf> <service>
    local conf="$1" service="$2" psk
    while true; do
        read -rp "新 PSK（直接回车随机生成）: " psk || return 0
        [ -z "$psk" ] && psk=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
        [[ "$psk" =~ ^[A-Za-z0-9._~+/=-]{8,128}$ ]] && break
        echo -e "${RED}PSK 要 8 到 128 个字符，只能是字母、数字和 . _ ~ + / = -${RESET}"
    done
    edit_backup "$conf"
    if conf_set "$conf" psk "$psk" && restart_and_verify_service "$service"; then
        edit_forget_backup
        echo -e "${GREEN}✓ PSK 已改为 ${psk}${RESET}"
        echo -e "${YELLOW}客户端要改用新的 PSK${RESET}"
    else
        edit_restore; restart_and_verify_service "$service" >/dev/null
        echo -e "${RED}改 PSK 没成功，已还原${RESET}"; return 1
    fi
}

edit_snell_dns() {   # <conf> <service>
    local conf="$1" service="$2"
    get_dns
    edit_backup "$conf"
    if conf_set "$conf" dns "$DNS" && restart_and_verify_service "$service"; then
        edit_forget_backup
        echo -e "${GREEN}✓ DNS 已改为 ${DNS}${RESET}"
    else
        edit_restore; restart_and_verify_service "$service" >/dev/null
        echo -e "${RED}改 DNS 没成功，已还原${RESET}"; return 1
    fi
}

# 菜单 4：选一个用户（只有主用户时直接进），再改它的端口、PSK 或 DNS
edit_snell_config() {
    local confs=() f i choice
    [ -f "$SNELL_CONF_FILE" ] && confs+=("$SNELL_CONF_FILE")
    for f in "${SNELL_CONF_DIR}"/users/snell-*.conf; do
        [ -f "$f" ] && [ "$f" != "$SNELL_CONF_FILE" ] && confs+=("$f")
    done
    if [ ${#confs[@]} -eq 0 ]; then
        echo -e "${YELLOW}还没有安装 Snell${RESET}"; return 0
    fi
    EDIT_CONF="${confs[0]}"
    if [ ${#confs[@]} -gt 1 ]; then
        echo -e "${CYAN}改哪一个：${RESET}"
        for i in "${!confs[@]}"; do
            f="${confs[$i]}"
            printf "  ${GREEN}%2d${RESET}  %s 端口 %-6s %s\n" $((i + 1)) "$([ "$f" = "$SNELL_CONF_FILE" ] && echo "主用户" || echo "用户  ")" "$(conf_port "$f")" "$(get_conf_snell_version "$f")"
        done
        echo -e "  ${GREEN} 0${RESET}  返回"
        read -rp "请选择 [0-${#confs[@]}]: " choice || return 0
        [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#confs[@]} ] || return 0
        EDIT_CONF="${confs[$((choice - 1))]}"
    fi
    EDIT_SERVICE=$(snell_service_for_port "$(conf_port "$EDIT_CONF")")
    while true; do
        echo
        echo -e "${CYAN}  ${EDIT_SERVICE}：端口 $(conf_port "$EDIT_CONF")   PSK $(conf_value "$EDIT_CONF" psk)   DNS $(conf_value "$EDIT_CONF" dns)   $(get_conf_snell_version "$EDIT_CONF")${RESET}"
        echo -e "  ${GREEN}1${RESET}  端口    ${GREEN}2${RESET}  PSK    ${GREEN}3${RESET}  DNS    ${GREEN}0${RESET}  返回"
        read -rp "改哪一项 [0-3]: " choice || return 0
        case "$choice" in
            1) edit_snell_port "$EDIT_CONF" "$EDIT_SERVICE" ;;
            2) edit_snell_psk "$EDIT_CONF" "$EDIT_SERVICE" ;;
            3) edit_snell_dns "$EDIT_CONF" "$EDIT_SERVICE" ;;
            0|"") break ;;
            *) echo -e "${RED}无效的选择${RESET}" ;;
        esac
    done
    echo -e "${CYAN}新的客户端配置见「3. 查看配置」${RESET}"
}

# 菜单里中文占两格：按显示宽度补齐（与 locale 无关：非 ASCII 字符按 3 字节、2 格算）
_dw() {
    local a b
    a=$(printf '%s' "$1" | LC_ALL=C tr -d '\200-\377' | LC_ALL=C wc -c)
    b=$(printf '%s' "$1" | LC_ALL=C wc -c)
    echo $(( a + 2 * (b - a) / 3 ))
}
_pad() {   # <文字> <宽度>：文字后补空格到这个宽度
    local w; w=$(_dw "$1")
    printf '%s%*s' "$1" $(( $2 > w ? $2 - w : 0 )) ''
}
# 一行菜单：<组名> <编号> <名称> [<编号> <名称>]
_menu_line() {
    local line
    line="  ${CYAN}$(_pad "$1" 6)${RESET}"
    line="${line}${GREEN}$(printf '%3s' "$2")${RESET}  $(_pad "$3" 22)"
    [ -n "${4:-}" ] && line="${line}${GREEN}$(printf '%3s' "$4")${RESET}  $5"
    echo -e "$line"
}
_dot() { if [ "$1" = "on" ]; then printf '%b' "${GREEN}●${RESET}"; else printf '%b' "${YELLOW}○${RESET}"; fi; }

# 菜单顶部的状态：两行，只看有没有在跑、跑了几个
menu_status() {
    local port conf units=() unit running=0 total=0 mem=0 pid rss ch chs="" line
    if command -v snell-server >/dev/null 2>&1 || ls "${INSTALL_DIR}"/snell-server-v[456] >/dev/null 2>&1; then
        # 主用户的配置也在 users/ 下（snell-main.conf），每个配置只数一次
        for conf in "${SNELL_CONF_DIR}"/users/*.conf; do
            [ -f "$conf" ] || continue
            port=$(sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p' "$conf" | head -n 1)
            [ -n "$port" ] || continue
            unit=$(snell_service_for_port "$port")
            total=$((total + 1))
            if systemctl is-active --quiet "$unit" || { [ "$unit" = "snell" ] && systemctl is-active --quiet snell.socket; }; then
                running=$((running + 1))
                pid=$(systemctl show -p MainPID --value "$unit" 2>/dev/null)
                rss=$( [ -n "$pid" ] && [ "$pid" != "0" ] && ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
                mem=$((mem + ${rss:-0}))
            fi
        done
        for ch in $(list_installed_snell_versions); do
            chs="${chs}${ch}×$(list_services_using_version "$ch" | grep -c .) "
        done
        if [ "$total" -gt 0 ] && [ "$running" -eq "$total" ]; then line="$(_dot on) 运行中 ${running}/${total}"
        elif [ "$total" -gt 0 ]; then line="$(_dot off) 运行中 ${running}/${total}"
        else line="$(_dot off) 已安装，未配置"; fi
        echo -e "  $(_pad Snell 11)${line}   ${chs}  内存 $(awk -v k="$mem" 'BEGIN { printf "%.1f", k / 1024 }') MB"
    else
        echo -e "  $(_pad Snell 11)$(_dot off) 未安装"
    fi
    local stls bbr route n=0 r=0 f
    if [ -x /usr/local/bin/shadow-tls ]; then
        for f in "${SYSTEMD_DIR}"/shadowtls-*.service; do
            [ -f "$f" ] || continue
            n=$((n + 1)); systemctl is-active --quiet "$(basename "$f")" && r=$((r + 1))
        done
        if [ "$n" -gt 0 ] && [ "$r" -eq "$n" ]; then stls="$(_dot on) 运行中 ${r}/${n}"; else stls="$(_dot off) 运行中 ${r}/${n}"; fi
    else
        stls="$(_dot off) 未安装"
    fi
    if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]; then bbr="$(_dot on) 已启用"; else bbr="$(_dot off) 未启用"; fi
    if systemctl is-active --quiet snell-router 2>/dev/null; then route="$(_dot on) 已启用"
    elif router_installed; then route="$(_dot off) 已停用"
    else route="$(_dot off) 未启用"; fi
    echo -e "  $(_pad ShadowTLS 11)${stls}    BBR ${bbr}    分流 ${route}"
}

# 主菜单
show_menu() {
    local rule="  ──────────────────────────────────────────────────────────"
    clear
    echo -e "${CYAN}  Snell 管理脚本 v${current_version}${RESET}$(printf '%*s' 27 '')${CYAN}jinqians.com${RESET}"
    echo -e "${CYAN}${rule}${RESET}"
    menu_status
    echo -e "${CYAN}${rule}${RESET}"
    _menu_line "安装" 1 "安装 Snell" 2 "卸载 Snell"
    _menu_line "配置" 3 "查看配置" 4 "修改端口 / PSK / DNS"
    _menu_line "" 5 "多用户管理" 6 "版本管理（v4 / v5 / v6）"
    _menu_line "服务" 7 "重启服务" 8 "服务状态"
    _menu_line "增强" 9 "ShadowTLS" 10 "BBR"
    _menu_line "" 11 "规则分流（sing-box）" 12 "出口控制（v5 / v6）"
    _menu_line "脚本" 13 "更新脚本" 0 "退出"
    echo -e "${CYAN}${rule}${RESET}"
    if ! read -rp "  请选择 [0-13]: " num; then
        echo
        echo -e "${YELLOW}未读取到输入，已退出 Snell 菜单。${RESET}"
        exit 0
    fi
}

#开启bbr
setup_bbr() {
    echo -e "${CYAN}正在获取并执行 BBR 管理脚本...${RESET}"

    # 下载到本地校验通过后再执行
    run_remote_script "${SNELL_RAW_BASE}/scripts/bbr.sh" "BBR 脚本"

    # BBR 脚本执行完毕后会自动返回这里
    echo -e "${GREEN}BBR 管理操作完成${RESET}"
    sleep 1  # 给用户一点时间看到提示
}

# ShadowTLS管理
setup_shadowtls() {
    echo -e "${CYAN}正在执行 ShadowTLS 管理脚本...${RESET}"
    run_remote_script "${SNELL_RAW_BASE}/scripts/shadowtls.sh" "ShadowTLS 脚本"

    # ShadowTLS 脚本执行完毕后会自动返回这里
    echo -e "${GREEN}ShadowTLS 管理操作完成${RESET}"
    sleep 1  # 给用户一点时间看到提示
}

# 主循环
while true; do
    show_menu
    case "$num" in
        1) install_snell ;;
        2) uninstall_snell ;;
        3) view_snell_config ;;
        4) edit_snell_config ;;
        5) setup_multi_user ;;
        6) check_snell_update ;;
        7) restart_snell ;;
        8) check_and_show_status ;;
        9) setup_shadowtls ;;
        10) setup_bbr ;;
        11) router_menu ;;
        12) configure_v5_egress_control ;;
        13) update_script ;;
        0)
            echo -e "${GREEN}感谢使用，再见！${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}请输入正确的选项 [0-13]${RESET}"
            ;;
    esac
    echo -e "\n${CYAN}按任意键返回主菜单...${RESET}"
    read -n 1 -s -r || exit 0
done
