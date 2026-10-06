#!/bin/bash
# 此文件由 tools/build.sh 从 src/shadowtls.sh 和 src/lib 生成：请修改 src/ 下的文件后重新生成。
# =========================================
# 作者: jinqians
# 日期: 2025年3月16
# 网站：jinqians.com
# 描述: 这个脚本用于安装和管理 ShadowTLS V3
# =========================================

# 共用部分（src/lib，发布时由 tools/build.sh 合进来）：颜色、防火墙、
# Snell 的路径与通道信息（每个用户配置首行的 "#version-choice = vX" 标明该端口跑的是哪个版本）
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



# ShadowTLS 自己的路径
CONFIG_DIR="/etc/shadowtls"
SERVICE_FILE="${SYSTEMD_DIR}/shadowtls.service"

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

# 安装必要的工具
install_requirements() {
    ensure_cmds wget curl jq || exit 1
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
        # 备份放 /etc/snell/backup：不能放进 users/，那里每个文件都会被当成一个用户
        cp -a "$conf" "$(snell_backup_path "$conf" "$(date +%Y%m%d%H%M%S)")"
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
        # 先校验端口为 1-65535 的纯数字，防止非法值或注入
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            echo -e "${RED}端口不合法，请输入 1-65535 的数字${RESET}" >&2
            return 1
        fi

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

# 校验 TLS 伪装域名白名单（防 systemd unit 参数注入与换行注入）
is_valid_tls_domain() {
    [[ "$1" =~ ^[A-Za-z0-9.-]{1,253}$ ]]
}

# 交互式读取 TLS 伪装域名，非法输入拒绝并要求重输
prompt_tls_domain() {
    while true; do
        read -rp "请输入 TLS 伪装域名 (直接回车默认为 www.microsoft.com): " tls_domain
        if [ -z "$tls_domain" ]; then
            tls_domain="www.microsoft.com"
            return 0
        fi
        if is_valid_tls_domain "$tls_domain"; then
            return 0
        fi
        echo -e "${RED}域名格式非法：仅允许字母、数字、点号和连字符（最长 253 字符），请重新输入${RESET}"
    done
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

# 启动服务并验证运行状态；失败时报错并提示 journalctl，不再静默吞掉错误
start_and_verify_service() {
    local unit="$1"
    # unit 文件刚写入，先 reload 让 systemd 感知
    systemctl daemon-reload 2>/dev/null
    if ! systemctl start "$unit"; then
        echo -e "${RED}服务 ${unit} 启动失败${RESET}"
        echo -e "${YELLOW}请执行 journalctl -u ${unit} 查看详细错误${RESET}"
        return 1
    fi
    if ! systemctl enable "$unit" 2>/dev/null; then
        echo -e "${YELLOW}服务 ${unit} 设置开机自启失败，可手动执行 systemctl enable ${unit}${RESET}"
    fi
    if ! systemctl is-active --quiet "$unit"; then
        echo -e "${RED}服务 ${unit} 启动后未能保持运行${RESET}"
        echo -e "${YELLOW}请执行 journalctl -u ${unit} 查看详细错误${RESET}"
        return 1
    fi
    return 0
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

    # 尝试下载：先直连 GitHub；ghproxy 为不受信第三方镜像，仅用户明确确认后才使用
    binary_name="shadow-tls-${arch}"
    github_url="https://github.com/ihciah/shadow-tls/releases/download/${version}/${binary_name}"
    proxy_url="https://ghproxy.com/${github_url}"

    echo -e "${CYAN}正在下载 ShadowTLS ${version} (${arch})...${RESET}"
    echo -e "${YELLOW}下载地址: ${github_url}${RESET}"

    if ! wget --timeout=30 --tries=2 -q "$github_url" -O "/tmp/shadow-tls.tmp" 2>/dev/null; then
        echo -e "${YELLOW}直连 GitHub 失败。${RESET}"
        echo -e "${YELLOW}注意：ghproxy.com 是不受信任的第三方镜像站，经其下载的二进制无法验证来源，存在供应链风险。${RESET}"
        read -rp "是否使用 ghproxy 镜像继续下载？[y/N] " use_proxy
        if [[ ! "$use_proxy" =~ ^[Yy]$ ]]; then
            echo -e "${RED}已取消下载${RESET}"
            rm -f "/tmp/shadow-tls.tmp"
            exit 1
        fi
        echo -e "${YELLOW}镜像地址: ${proxy_url}${RESET}"
        if ! wget --timeout=60 --tries=3 "$proxy_url" -O "/tmp/shadow-tls.tmp"; then
            echo -e "${RED}下载 ShadowTLS 失败，请检查网络连接后重试${RESET}"
            rm -f "/tmp/shadow-tls.tmp"
            exit 1
        fi
    fi

    # 验证下载的文件不为空（注：上游未发布哈希/签名，此处仅做非空检查，无法验证来源真实性）
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
    
    # 获取 TLS 伪装域名（白名单校验，防止 unit 注入）
    prompt_tls_domain
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
        open_port "$ss_listen_port" tcp
        start_and_verify_service "shadowtls-ss" || return 1
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
                open_port "$stls_port" tcp
                start_and_verify_service "shadowtls-snell-${port}" || return 1
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
            open_port "$stls_port" tcp
            start_and_verify_service "shadowtls-snell-${selected_port}" || return 1
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
        ss_listen_port=$(sed -n 's/.*--listen [^ ]*:\([0-9][0-9]*\).*/\1/p' "${SYSTEMD_DIR}/shadowtls-ss.service" | head -n 1)
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
            listen_port=$(sed -n 's/.*--listen [^ ]*:\([0-9][0-9]*\).*/\1/p' "$service_file" | head -n 1)
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

    # 清理日志文件
    rm -f /var/log/shadowtls-*.log

    # 清理 TCP Fast Open 内核参数文件（系统级，删除前询问用户）
    if [ -f /etc/sysctl.d/99-tcp-fastopen.conf ]; then
        echo -e "${YELLOW}检测到 /etc/sysctl.d/99-tcp-fastopen.conf，这是系统级内核参数文件（net.ipv4.tcp_fastopen），是否删除？[y/N]${RESET}"
        read -r del_tfo_conf
        if [[ "$del_tfo_conf" =~ ^[Yy]$ ]]; then
            rm -f /etc/sysctl.d/99-tcp-fastopen.conf
            echo -e "${GREEN}已删除 /etc/sysctl.d/99-tcp-fastopen.conf${RESET}"
        else
            echo -e "${YELLOW}已保留 /etc/sysctl.d/99-tcp-fastopen.conf${RESET}"
        fi
    fi

    # 清理 nftables 表（不存在时静默跳过）
    if command -v nft >/dev/null 2>&1; then
        nft delete table inet shadowtls_filter 2>/dev/null || true
    fi

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
                # 获取 TLS 伪装域名（白名单校验，防止 unit 注入）
                prompt_tls_domain
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
                open_port "$ss_listen_port" tcp
                start_and_verify_service "shadowtls-ss" || return 1
                
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
                # 获取 TLS 伪装域名（白名单校验，防止 unit 注入）
                prompt_tls_domain
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
                        open_port "$stls_port" tcp
                        start_and_verify_service "shadowtls-snell-${port}" || return 1
                        
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
                    open_port "$stls_port" tcp
                    start_and_verify_service "shadowtls-snell-${selected_port}" || return 1
                    
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
# 旧版 snell-server.conf 迁到 users/snell-main.conf（以前藏在 get_snell_port 里，每次读端口都做一遍）
migrate_legacy_snell_config >/dev/null 2>&1 || true

# 如果直接运行此脚本，则显示主菜单
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_menu
fi
