#!/bin/bash
# 此文件由 tools/build.sh 从 src/menu.sh 和 src/lib 生成：请修改 src/ 下的文件后重新生成。
# =========================================
# 作者: jinqians
# 日期: 2026年7月
# 网站：jinqians.com
# 描述: 这个脚本用于统一管理 Snell、SS-Rust 和 ShadowTLS（将逐步和snell管理菜单分开）
# =========================================

# 共用部分（src/lib，发布时由 tools/build.sh 合进来）：颜色、root 检查、依赖安装、防火墙
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
SNELL_RAW_BASE="${SNELL_RAW_BASE:-https://raw.githubusercontent.com/jinqians/snell/main}"
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


# 当前版本号
current_version="4.6"

# systemd 服务目录
SYSTEMD_DIR="/etc/systemd/system"

# 中国大陆屏蔽脚本仓库地址
MAINLAND_BLOCK_URL="https://raw.githubusercontent.com/jinqians/ss-2022/refs/heads/main/block-mainland.sh"
MAINLAND_EXTRACT_URL="https://raw.githubusercontent.com/jinqians/ss-2022/refs/heads/main/extract-cn-ip-from-mmdb.py"
MAINLAND_SCRIPT_DIR="/usr/local/share/ss-2022"

# 安装全局命令
install_global_command() {
    echo -e "${CYAN}正在安装全局命令...${RESET}"

    # 先下载到临时文件，校验通过后再覆盖目标文件，避免下载失败破坏现有 menu 命令
    local tmp_file
    tmp_file=$(mktemp /tmp/menu_download.XXXXXX) || { echo -e "${RED}无法创建临时文件${RESET}"; return 1; }
    if ! fetch_verified_script "$SNELL_MENU_SCRIPT_URL" "$tmp_file"; then
        echo -e "${RED}menu 脚本下载校验失败，请检查网络连接${RESET}"
        return 1
    fi

    mv -f "$tmp_file" "/usr/local/bin/menu.sh"
    chmod +x "/usr/local/bin/menu.sh"
    
    # 创建软链接
    if [ -f "/usr/local/bin/menu" ]; then
        rm -f "/usr/local/bin/menu"
    fi
    ln -s "/usr/local/bin/menu.sh" "/usr/local/bin/menu"
    
    echo -e "${GREEN}安装成功！现在您可以在任何位置使用 'menu' 命令来启动管理脚本${RESET}"
}

# 获取 CPU 使用率
get_cpu_usage() {
    local pid=$1
    local cpu_usage=0
    
    # 获取 CPU 核心数
    local cpu_cores=$(nproc)
    
    # 使用 top 命令获取准确的 CPU 使用率
    if [ ! -z "$pid" ] && [ "$pid" != "0" ]; then
        cpu_usage=$(top -b -n 2 -d 0.2 -p "$pid" | tail -1 | awk '{print $9}')
        # 如果获取失败，使用 ps 命令作为备选
        if [ -z "$cpu_usage" ]; then
            cpu_usage=$(ps -p "$pid" -o %cpu= 2>/dev/null || echo 0)
        fi
        # 将 CPU 使用率除以核心数，得到平均使用率
        cpu_usage=$(echo "scale=2; $cpu_usage / $cpu_cores" | bc -l)
    fi
    
    echo "$cpu_usage"
}

# 检查服务状态并显示
check_and_show_status() {
    # 获取 CPU 核心数
    local cpu_cores=$(nproc)
    
    echo -e "\n${CYAN}=== 服务状态检查 ===${RESET}"
    echo -e "${CYAN}系统 CPU 核心数：${cpu_cores}${RESET}"
    
    # 检查 Snell 状态
    if command -v snell-server &> /dev/null; then
        local user_count=0
        local running_count=0
        local total_snell_memory=0
        local total_snell_cpu=0
        
        # 检查主服务状态
        if systemctl is-active snell &> /dev/null; then
            user_count=$((user_count + 1))
            running_count=$((running_count + 1))
            
            local main_pid=$(systemctl show -p MainPID snell | cut -d'=' -f2)
            if [ ! -z "$main_pid" ] && [ "$main_pid" != "0" ]; then
                local mem=$(ps -o rss= -p $main_pid 2>/dev/null || echo 0)
                local cpu=$(get_cpu_usage "$main_pid")
                total_snell_memory=$((total_snell_memory + ${mem:-0}))
                if [ ! -z "$cpu" ]; then
                    total_snell_cpu=$(echo "$total_snell_cpu + ${cpu:-0}" | bc -l 2>/dev/null || echo "0")
                fi
            fi
        else
            user_count=$((user_count + 1))
        fi
        
        # 检查多用户状态
        if [ -d "/etc/snell/users" ]; then
            for user_conf in "/etc/snell/users"/*; do
                if [ -f "$user_conf" ] && [[ "$user_conf" != *"snell-main.conf" ]]; then
                    local port=$(grep -E '^listen' "$user_conf" | sed -n 's/.*:\([0-9][0-9]*\)[[:space:]]*$/\1/p')
                    if [ ! -z "$port" ]; then
                        user_count=$((user_count + 1))
                        if systemctl is-active --quiet "snell-${port}"; then
                            running_count=$((running_count + 1))
                            
                            local user_pid=$(systemctl show -p MainPID "snell-${port}" | cut -d'=' -f2)
                            if [ ! -z "$user_pid" ] && [ "$user_pid" != "0" ]; then
                                local mem=$(ps -o rss= -p $user_pid 2>/dev/null || echo 0)
                                local cpu=$(get_cpu_usage "$user_pid")
                                total_snell_memory=$((total_snell_memory + ${mem:-0}))
                                if [ ! -z "$cpu" ]; then
                                    total_snell_cpu=$(echo "$total_snell_cpu + ${cpu:-0}" | bc -l 2>/dev/null || echo "0")
                                fi
                            fi
                        fi
                    fi
                fi
            done
        fi
        
        # 确保所有数值都有效
        total_snell_memory=${total_snell_memory:-0}
        total_snell_cpu=${total_snell_cpu:-0}
        
        local total_snell_memory_mb=$(echo "scale=2; $total_snell_memory/1024" | bc -l 2>/dev/null || echo "0")
        printf "${GREEN}Snell 已安装${RESET}  ${YELLOW}CPU：%.2f%% (每核)${RESET}  ${YELLOW}内存：%.2f MB${RESET}  ${GREEN}运行中：${running_count}/${user_count}${RESET}\n" "${total_snell_cpu:-0}" "${total_snell_memory_mb:-0}"
    else
        echo -e "${YELLOW}Snell 未安装${RESET}"
    fi
    
    # 检查 SS-2022 状态
    if [[ -e "/usr/local/bin/ss-rust" ]]; then
        local ss_memory=0
        local ss_cpu=0
        local ss_running=0
        
        if systemctl is-active ss-rust &> /dev/null; then
            ss_running=1
            local ss_pid=$(systemctl show -p MainPID ss-rust | cut -d'=' -f2)
            if [ ! -z "$ss_pid" ] && [ "$ss_pid" != "0" ]; then
                ss_memory=$(ps -o rss= -p $ss_pid 2>/dev/null || echo 0)
                ss_cpu=$(get_cpu_usage "$ss_pid")
            fi
        fi
        
        local ss_memory_mb=$(echo "scale=2; $ss_memory/1024" | bc)
        printf "${GREEN}SS-2022 已安装${RESET}  ${YELLOW}CPU：%.2f%% (每核)${RESET}  ${YELLOW}内存：%.2f MB${RESET}  ${GREEN}运行中：${ss_running}/1${RESET}\n" "$ss_cpu" "$ss_memory_mb"
    else
        echo -e "${YELLOW}SS-2022 未安装${RESET}"
    fi
    
    # 检查 ShadowTLS 状态
    if systemctl list-units --type=service | grep -q "shadowtls-"; then
        local stls_total=0
        local stls_running=0
        local total_stls_memory=0
        local total_stls_cpu=0
        
        while IFS= read -r service; do
            stls_total=$((stls_total + 1))
            if systemctl is-active "$service" &> /dev/null; then
                stls_running=$((stls_running + 1))
                
                local stls_pid=$(systemctl show -p MainPID "$service" | cut -d'=' -f2)
                if [ ! -z "$stls_pid" ] && [ "$stls_pid" != "0" ]; then
                    local mem=$(ps -o rss= -p $stls_pid 2>/dev/null || echo 0)
                    local cpu=$(get_cpu_usage "$stls_pid")
                    total_stls_memory=$((total_stls_memory + mem))
                    total_stls_cpu=$(echo "$total_stls_cpu + $cpu" | bc -l)
                fi
            fi
        done < <(systemctl list-units --type=service --all --no-legend | grep "shadowtls-" | awk '{print $1}')
        
        if [ $stls_total -gt 0 ]; then
            local total_stls_memory_mb=$(echo "scale=2; $total_stls_memory/1024" | bc)
            printf "${GREEN}ShadowTLS 已安装${RESET}  ${YELLOW}CPU：%.2f%% (每核)${RESET}  ${YELLOW}内存：%.2f MB${RESET}  ${GREEN}运行中：${stls_running}/${stls_total}${RESET}\n" "$total_stls_cpu" "$total_stls_memory_mb"
        else
            echo -e "${YELLOW}ShadowTLS 未安装${RESET}"
        fi
    else
        echo -e "${YELLOW}ShadowTLS 未安装${RESET}"
    fi
    
    echo -e "${CYAN}====================${RESET}\n"
}

# 更新脚本
update_script() {
    echo -e "${CYAN}正在检查脚本更新...${RESET}"
    
    # 创建临时文件
    TMP_SCRIPT=$(mktemp)
    
    # 下载最新版本（带完整性校验）
    if fetch_verified_script "$SNELL_MENU_SCRIPT_URL" "$TMP_SCRIPT"; then
        # 获取新版本号
        # 只认行首的赋值：这一行自己也含 current_version=，不锚定会读出两个「版本」，永远提示有更新
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

# 安装/管理 Snell
manage_snell() {
    bash <(curl -fsSL "$SNELL_SCRIPT_URL")
}

# 安装/管理 SS-2022
manage_ss_rust() {
    bash <(curl -sL https://raw.githubusercontent.com/jinqians/ss-2022/main/ss-2022.sh)
}

# 管理中国大陆IP屏蔽
manage_mainland_block() {
    echo -e "${CYAN}正在从仓库获取大陆IP屏蔽脚本...${RESET}"

    mkdir -p "${MAINLAND_SCRIPT_DIR}"

    if ! curl -fL -s "${MAINLAND_BLOCK_URL}" -o "${MAINLAND_SCRIPT_DIR}/block-mainland.sh"; then
        echo -e "${RED}下载 block-mainland.sh 失败${RESET}"
        return 1
    fi

    if ! curl -fL -s "${MAINLAND_EXTRACT_URL}" -o "${MAINLAND_SCRIPT_DIR}/extract-cn-ip-from-mmdb.py"; then
        echo -e "${RED}下载 extract-cn-ip-from-mmdb.py 失败${RESET}"
        return 1
    fi

    chmod +x "${MAINLAND_SCRIPT_DIR}/block-mainland.sh" "${MAINLAND_SCRIPT_DIR}/extract-cn-ip-from-mmdb.py"
    PYTHONIOENCODING=UTF-8 bash "${MAINLAND_SCRIPT_DIR}/block-mainland.sh"
}

# 安装/管理 ShadowTLS
manage_shadowtls() {
    bash <(curl -fsSL "${SNELL_RAW_BASE}/scripts/shadowtls.sh")
}

# 安装/管理 VLESS Reality（已整合到 PSM）
manage_vless() {
    echo -e "${CYAN}VLESS Reality 的安装管理已由 PSM（Proxy Stack Manager）提供，正在启动 PSM...${RESET}"
    if ! bash <(curl -fsSL https://psm.jinqians.com); then
        echo -e "${RED}PSM 启动失败，请检查网络后重试，或手动执行：bash <(curl -fsSL https://psm.jinqians.com)${RESET}"
        return 1
    fi
}
# 卸载 Snell
uninstall_snell() {
    echo -e "${CYAN}正在卸载 Snell${RESET}"

    # 规则分流（snell.sh 菜单 12）一起删掉：拦截规则、服务、配置
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
    if [ -d "/etc/snell/users" ]; then
        for user_conf in "/etc/snell/users"/*; do
            if [ -f "$user_conf" ]; then
                local port=$(grep -E '^listen' "$user_conf" | sed -n 's/.*:\([0-9][0-9]*\)[[:space:]]*$/\1/p')
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
    rm -f "/lib/systemd/system/snell.service"
    rm -f "${SYSTEMD_DIR}/snell.service"
    rm -f "${SYSTEMD_DIR}/snell.socket"
    rm -f "${SYSTEMD_DIR}/snell-netns.service"
    rm -f "/usr/local/bin/snell-netns-setup.sh"

    # 删除可执行文件和配置目录
    rm -f /usr/local/bin/snell-server
    rm -rf /etc/snell
    rm -f /usr/local/bin/snell  # 删除管理脚本

    if ! find "${SYSTEMD_DIR}" -maxdepth 1 -name "shadowtls-*.service" 2>/dev/null | grep -q .; then
        rm -f /usr/local/bin/shadow-tls
    fi

    # 重载 systemd 配置
    systemctl daemon-reload

    echo -e "${GREEN}Snell 及其所有多用户配置已成功卸载${RESET}"
}

# 卸载 SS-2022
uninstall_ss_rust() {
    echo -e "${CYAN}正在卸载 SS-2022...${RESET}"

    # 获取主服务端口，用于关闭防火墙
    local main_port=""
    if [ -f "/etc/ss-rust/config.json" ]; then
        main_port=$(grep -oE '"server_port"[[:space:]]*:[[:space:]]*[0-9]+' /etc/ss-rust/config.json | grep -oE '[0-9]+' | head -n 1)
    fi

    # 停止并禁用主服务
    systemctl stop ss-rust 2>/dev/null
    systemctl disable ss-rust 2>/dev/null
    rm -f "${SYSTEMD_DIR}/ss-rust.service"
    if [ -n "$main_port" ]; then
        close_port "$main_port"
    fi

    # 清理多端口节点服务
    local extra_service
    for extra_service in "${SYSTEMD_DIR}"/ss-rust-*.service; do
        [ -f "$extra_service" ] || continue
        local svc_name=$(basename "$extra_service" .service)
        local extra_port="${svc_name#ss-rust-}"
        echo -e "${YELLOW}正在停止多端口服务 (端口: ${extra_port})${RESET}"
        systemctl stop "$svc_name" 2>/dev/null
        systemctl disable "$svc_name" 2>/dev/null
        rm -f "$extra_service"
        case "$extra_port" in
            ''|*[!0-9]*) ;;
            *) close_port "$extra_port" ;;
        esac
    done

    # 删除二进制文件和配置目录
    rm -f "/usr/local/bin/ss-rust"
    rm -rf "/etc/ss-rust"

    # 重新加载 systemd
    systemctl daemon-reload

    echo -e "${GREEN}SS-2022 卸载完成！${RESET}"
}

# 卸载 ShadowTLS
uninstall_shadowtls() {
    echo -e "${CYAN}正在卸载 ShadowTLS...${RESET}"

    # 停止并禁用所有 ShadowTLS 服务
    while IFS= read -r service; do
        [ -z "$service" ] && continue
        local service_file="${SYSTEMD_DIR}/${service}"
        local listen_port=""
        if [ -f "$service_file" ]; then
            listen_port=$(sed -n 's/.*--listen [^ ]*:\([0-9][0-9]*\).*/\1/p' "$service_file" | head -n 1)
        fi
        systemctl stop "$service" 2>/dev/null
        systemctl disable "$service" 2>/dev/null
        rm -f "$service_file"
        if [ -n "$listen_port" ]; then
            close_port "$listen_port"
        fi
    done < <(systemctl list-units --type=service --all --no-legend | grep "shadowtls-" | awk '{print $1}')
    
    # 删除二进制文件
    rm -f "/usr/local/bin/shadow-tls"
    
    # 重新加载 systemd
    systemctl daemon-reload
    
    echo -e "${GREEN}ShadowTLS 卸载完成！${RESET}"
}

# 主菜单
show_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}          统一管理脚本 v${current_version}${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}作者: jinqian${RESET}"
    echo -e "${GREEN}网站：https://jinqians.com${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    
    # 显示服务状态
    check_and_show_status
    
    echo -e "${YELLOW}=== 安装管理 ===${RESET}"
    echo -e "${GREEN}1.${RESET} Snell 安装管理"
    echo -e "${GREEN}2.${RESET} SS-2022 安装管理"
    echo -e "${GREEN}3.${RESET} VLESS Reality 安装管理"
    echo -e "${GREEN}4.${RESET} ShadowTLS 安装管理"
    
    echo -e "\n${YELLOW}=== 卸载功能 ===${RESET}"
    echo -e "${GREEN}5.${RESET} 卸载 Snell"
    echo -e "${GREEN}6.${RESET} 卸载 SS-2022"
    echo -e "${GREEN}7.${RESET} 卸载 ShadowTLS"
    
    echo -e "\n${YELLOW}=== 系统功能 ===${RESET}"
    echo -e "${GREEN}8.${RESET} 更新脚本"
    echo -e "${GREEN}9.${RESET} 流量管理（推荐使用 PSM 管理）"
    echo -e "${GREEN}10.${RESET} 中国大陆屏蔽管理(ss-2022)"
    echo -e "${GREEN}0.${RESET} 退出"
    
    echo -e "${CYAN}============================================${RESET}"

    echo -e "${GREEN}退出脚本后，输入menu可进入脚本${RESET}"

    echo -e "${CYAN}============================================${RESET}"
    read -rp "请输入选项 [0-10]: " num
}

# 初始检查
check_root
# bc：状态里的 CPU / 内存合计
ensure_cmds curl bc || exit 1
install_global_command

# 主循环
while true; do
    show_menu
    case "$num" in
        1)
            manage_snell
            ;;
        2)
            manage_ss_rust
            ;;
        3)
            manage_vless
            ;;
        4)
            manage_shadowtls
            ;;
        5)
            uninstall_snell
            ;;
        6)
            uninstall_ss_rust
            ;;
        7)
            uninstall_shadowtls
            ;;
        8)
            update_script
            ;;
        9)
            echo -e "\n${YELLOW}=== 流量管理 ===${RESET}"
            echo -e "本脚本内置的流量管理功能尚不完善，推荐使用 ${GREEN}PSM（Proxy Stack Manager）${RESET} 进行流量管理。"
            echo -e "\nPSM 支持 Snell / SS2022 / Xray 等协议的统一流量限额管理，功能包括："
            echo -e "  • 设置月度流量上限（GB）及自动重置日"
            echo -e "  • 超限自动暂停节点，恢复后自动解封"
            echo -e "  • iptables 精确计数，数据持久化保存"
            echo -e "\n安装 PSM："
            echo -e "  ${CYAN}bash <(curl -fsSL https://psm.jinqians.com)${RESET}"
            echo -e "\n进入 PSM 后选择：${GREEN}15. 流量管理${RESET} 即可添加 SS2022 节点并配置限额。"
            read -p "按任意键继续..."
            ;;
        10)
            if ! manage_mainland_block; then
                echo -e "${YELLOW}请检查仓库地址或网络连接后重试${RESET}"
                read -p "按任意键继续..."
            fi
            ;;
        0)
            echo -e "${GREEN}感谢使用，再见！${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}请输入正确的选项 [0-10]${RESET}"
            ;;
    esac
    echo -e "\n${CYAN}按任意键返回主菜单...${RESET}"
    read -n 1 -s -r
done 
