#!/bin/bash
# 此文件由 tools/build.sh 从 src/bbr.sh 和 src/lib 生成：请修改 src/ 下的文件后重新生成。
# =========================================
# 作者: jinqians
# 网站：jinqians.com
# 描述: BBR 管理：启用内核自带的 BBR，或在 Debian / Ubuntu 上换 XanMod 内核（BBR v3）
# =========================================

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


check_root

BBR_SYSCTL="/etc/sysctl.d/99-snell-bbr.conf"
BBR_MODULES="/etc/modules-load.d/snell-bbr.conf"
XANMOD_KEY_URL="https://dl.xanmod.org/archive.key"
XANMOD_REPO="http://deb.xanmod.org"
XANMOD_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
XANMOD_LIST="/etc/apt/sources.list.d/xanmod-release.list"
# 测试用：BBR_APT_SIMULATE=1 只模拟安装内核（apt-get -s）；BBR_CPUINFO 换一份 cpuinfo
CPUINFO="${BBR_CPUINFO:-/proc/cpuinfo}"

current_cc()    { sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null; }
current_qdisc() { sysctl -n net.core.default_qdisc 2>/dev/null; }
available_cc()  { cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; }
bbr_available() { available_cc | grep -qw bbr; }

# 内核版本不低于 <主> <次>
kernel_at_least() {
    local v maj min
    v=$(uname -r); maj=${v%%.*}; v=${v#*.}; min=${v%%[!0-9]*}
    [ "$maj" -gt "$1" ] || { [ "$maj" -eq "$1" ] && [ "${min:-0}" -ge "$2" ]; }
}

# 跑在容器或 OpenVZ 里：内核是宿主机的，这里换不了内核，也未必改得了内核参数
in_container() {
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        systemd-detect-virt -c -q && return 0
        [ "$(systemd-detect-virt 2>/dev/null)" = "openvz" ] && return 0
        return 1
    fi
    [ -f /.dockerenv ] || [ -f /run/.containerenv ] && return 0
    grep -qa 'container=' /proc/1/environ 2>/dev/null && return 0   # LXC 等
    [ -d /proc/vz ] && [ ! -d /proc/bc ]                              # OpenVZ（宿主机上有 /proc/bc）
}

# 开了安全启动（Secure Boot）的机器只认签过名的内核；XanMod 没签名，装上就开不了机
secure_boot_on() {
    local f
    for f in /sys/firmware/efi/efivars/SecureBoot-*; do
        [ -r "$f" ] || continue
        [ "$(od -An -t u1 "$f" 2>/dev/null | awk '{print $NF}')" = "1" ] && return 0
    done
    return 1
}

xanmod_suite_ok() { [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${XANMOD_REPO}/dists/$1/Release")" = "200" ]; }

# 旧版脚本加的 XanMod 软件源是 releases，这个源已经没有了（404），apt-get update 会一直报错：
# 装上了 XanMod 的改成本系统版本的源（照常收到内核更新），没装上的删掉
fix_legacy_xanmod_repo() {
    [ -f "$XANMOD_LIST" ] && grep -q '^deb .*deb\.xanmod\.org releases' "$XANMOD_LIST" || return 0
    local codename
    codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
    if xanmod_installed && [ -n "$codename" ] && command -v curl >/dev/null 2>&1 && xanmod_suite_ok "$codename"; then
        sed -i "s#deb\.xanmod\.org releases#deb.xanmod.org ${codename}#" "$XANMOD_LIST"
        echo -e "${YELLOW}旧版脚本加的 XanMod 软件源（releases）已经没有了，改成了 ${codename}，内核照常更新。${RESET}"
    else
        rm -f "$XANMOD_LIST"
        echo -e "${YELLOW}旧版脚本加的 XanMod 软件源（releases）已经没有了，apt-get update 会因它报错，已删除。${RESET}"
    fi
}

xanmod_running() { uname -r | grep -qi xanmod; }
xanmod_installed() { dpkg-query -W -f='${Status} ${Package}\n' 'linux-image-*xanmod*' 2>/dev/null | grep -q '^install ok installed'; }

show_status() {
    local mine="无" kern
    [ -f "$BBR_SYSCTL" ] && mine="已写入 ${BBR_SYSCTL}"
    kern=$(uname -r)
    if xanmod_running; then kern="${kern}（XanMod）"
    elif xanmod_installed; then kern="${kern}（已装 XanMod，重启后生效）"
    fi
    echo -e "  内核        ${kern}"
    # 容器里看不到默认队列（只在宿主机的网络命名空间里有）
    local q; q=$(current_qdisc); q=${q:+   默认队列 $q}
    if [ "$(current_cc)" = "bbr" ]; then
        echo -e "  拥塞控制    ${GREEN}bbr${RESET}${q}"
    else
        echo -e "  拥塞控制    ${YELLOW}$(current_cc)${RESET}${q}   可用：$(available_cc)"
    fi
    echo -e "  本脚本设置  ${mine}"
}

BBR_KEYS="net.core.default_qdisc net.ipv4.tcp_congestion_control net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem"

# 写入的只有 BBR 本身（fq + bbr）和适合长距离高带宽的收发缓冲区；不碰转发等别的系统设置。
# 第一次写入时把这几项原来的值记在文件里（「# 原值」），「恢复默认」时还原；再写一次沿用记下的。
# 旧版写的同名文件先备份（sysctl 只读 *.conf，备份不会生效）；那时的值是旧版设的，不记。
write_bbr_sysctl() {
    local orig="" k v
    if [ -f "$BBR_SYSCTL" ] && grep -q '^# 原值 ' "$BBR_SYSCTL"; then
        orig=$(grep '^# 原值 ' "$BBR_SYSCTL")
    elif [ -f "$BBR_SYSCTL" ]; then
        cp -a "$BBR_SYSCTL" "${BBR_SYSCTL}.bak_$(date +%Y%m%d_%H%M%S)"
    else
        for k in $BBR_KEYS; do
            v=$(sysctl -n "$k" 2>/dev/null | tr -s '\t ' '  ')
            [ -n "$v" ] && orig="${orig:+$orig
}# 原值 ${k} = ${v}"
        done
    fi
    # 精简的系统（比如容器镜像）可能没有这两个目录
    mkdir -p "$(dirname "$BBR_SYSCTL")" "$(dirname "$BBR_MODULES")"
    {
        echo "# 由 snell.sh 的 BBR 管理写入。删除本文件并重启（或在菜单里选「恢复默认」）即恢复原来的设置。"
        [ -n "$orig" ] && printf '%s\n' "$orig"
        cat <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
EOF
    } > "$BBR_SYSCTL"
    # BBR 是模块时开机就加载它（编进内核的也无妨）
    echo "tcp_bbr" > "$BBR_MODULES"
}

# 逐项应用；容器里有的参数改不了，说一声，不中断
apply_bbr_sysctl() {
    local out
    if ! out=$(sysctl -p "$BBR_SYSCTL" 2>&1); then
        echo -e "${YELLOW}有的参数没能生效（容器里改不了宿主机的设置）：${RESET}"
        printf '%s\n' "$out" | grep -i -E 'error|denied|cannot|read-only|invalid' | sed 's/^/  /'
    fi
}

# 旧版脚本把整段参数写进了 /etc/sysctl.conf（2026-09 以前，整个文件被覆盖）或 99-snell-bbr.conf，
# 顺带打开了 IP 转发和 route_localnet：前者让靠路由通告取 IPv6 地址的机器失去 IPv6，后者是安全隐患。
# 99-snell-bbr.conf 是本脚本的文件，接下来整个换掉；/etc/sysctl.conf 是系统的，问过再改。
cleanup_legacy_sysctl() {
    local f=/etc/sysctl.conf keys ans fixed=""
    keys='net\.ipv4\.conf\.all\.route_localnet|net\.ipv4\.ip_forward|net\.ipv4\.conf\.(all|default)\.forwarding|net\.ipv6\.conf\.(all|default)\.forwarding|net\.ipv4\.tcp_fack'
    if [ -f "$BBR_SYSCTL" ] && grep -q '^net\.ipv4\.conf\.all\.route_localnet = 1' "$BBR_SYSCTL"; then
        echo -e "${YELLOW}旧版写的 ${BBR_SYSCTL} 打开了 IP 转发和 route_localnet，换成只有 BBR 的设置（原文件会备份）。${RESET}"
        fixed=1
    fi
    if [ -f "$f" ] && grep -q '^net\.ipv4\.conf\.all\.route_localnet = 1' "$f"; then
        echo -e "${YELLOW}/etc/sysctl.conf 里有旧版 BBR 脚本写入的设置：打开了 IP 转发和 route_localnet。${RESET}"
        echo -e "${YELLOW}route_localnet 有安全隐患；IPv6 转发会让靠路由通告取 IPv6 地址的机器失去 IPv6。${RESET}"
        read -rp "把这几行注释掉吗？（原文件会备份）[Y/n]: " ans
        case "$ans" in
            [nN]*) ;;
            *)
                cp -a "$f" "${f}.bak_$(date +%Y%m%d_%H%M%S)"
                sed -i -E "s/^(($keys)[[:space:]]*=.*)$/# 已由 BBR 管理注释：\1/" "$f"
                fixed=1
                ;;
        esac
    fi
    [ -n "$fixed" ] || return 0
    sysctl -w net.ipv4.conf.all.route_localnet=0 >/dev/null 2>&1 || true
    echo -e "${GREEN}route_localnet 已立即关闭；转发的设置在下次重启后恢复默认（Docker 等需要转发的程序会自己打开）。${RESET}"
}

enable_bbr() {
    ensure_cmds sysctl modprobe || return 1
    if ! kernel_at_least 4 9; then
        echo -e "${RED}内核 $(uname -r) 太旧：BBR 需要 4.9 及以上。Debian / Ubuntu 可以选「2」换 XanMod 内核。${RESET}"
        return 1
    fi
    modprobe tcp_bbr 2>/dev/null || true
    if ! bbr_available; then
        if in_container; then
            echo -e "${RED}BBR 没有加载（可用的拥塞控制：$(available_cc)）。这里是容器或 OpenVZ，模块只能由宿主机加载：${RESET}"
            echo -e "${YELLOW}在宿主机上执行 modprobe tcp_bbr 后再试；OpenVZ 请联系服务商。${RESET}"
        else
            echo -e "${RED}这个内核没有 BBR（可用的拥塞控制：$(available_cc)）。Debian / Ubuntu 可以选「2」换 XanMod 内核。${RESET}"
        fi
        return 1
    fi
    cleanup_legacy_sysctl
    write_bbr_sysctl
    apply_bbr_sysctl
    if [ "$(current_cc)" = "bbr" ]; then
        echo -e "${GREEN}✓ BBR 已启用（拥塞控制 bbr，默认队列 $(current_qdisc)），重启后保持。${RESET}"
    else
        echo -e "${RED}没能切换到 BBR，当前拥塞控制仍是 $(current_cc)。${RESET}"
        return 1
    fi
}

# CPU 支持的 x86-64 指令集级别（1–4），XanMod 按它分包
cpu_level() {
    local flags f
    flags=" $(grep -m1 '^flags' "$CPUINFO" | cut -d: -f2) "
    has() { for f in "$@"; do case "$flags" in *" $f "*) ;; *) return 1 ;; esac; done; }
    has cx16 lahf_lm popcnt pni sse4_1 sse4_2 ssse3 || { echo 1; return; }
    has avx avx2 bmi1 bmi2 f16c fma abm movbe xsave || { echo 2; return; }
    has avx512f avx512bw avx512cd avx512dq avx512vl || { echo 3; return; }
    echo 4
}

# 这个系统版本的源里有哪些 XanMod 内核包：各版本不一样（Debian 12 只有 LTS 版）
xanmod_packages() {   # <codename>
    curl -fsSL --retry 2 --max-time 60 "${XANMOD_REPO}/dists/$1/main/binary-amd64/Packages.gz" | gzip -dc 2>/dev/null |
        sed -n 's/^Package: \(linux-xanmod-[a-z0-9-]*\)$/\1/p' | sort -u
}

# 级别 → 包：先主线，没有就 LTS，再没有就低一级的（低级别的内核在新 CPU 上照样能跑）。
# 主线只有 x64v2、x64v3（v4 的 CPU 用 v3），v1 只剩 LTS 版
xanmod_package() {   # <级别> <源里有的包，每行一个>
    local c want
    case "$1" in
        1) want="lts-x64v1" ;;
        2) want="x64v2 lts-x64v2 lts-x64v1" ;;
        *) want="x64v3 lts-x64v3 x64v2 lts-x64v2 lts-x64v1" ;;
    esac
    for c in $want; do
        printf '%s\n' "$2" | grep -qx "linux-xanmod-$c" && { echo "linux-xanmod-$c"; return 0; }
    done
    return 1
}

install_xanmod() {
    detect_os
    if [ "$(uname -m)" != "x86_64" ]; then
        echo -e "${RED}XanMod 只提供 x86_64 内核，这台是 $(uname -m)。可以选「1」用内核自带的 BBR。${RESET}"; return 1
    fi
    if [ "$OS_FAMILY" != "debian" ]; then
        echo -e "${RED}XanMod 只提供 Debian / Ubuntu 的软件包。可以选「1」用内核自带的 BBR。${RESET}"; return 1
    fi
    # 模拟安装（测试用）不碰内核，容器里也可以走一遍
    if in_container && [ "${BBR_APT_SIMULATE:-}" != "1" ]; then
        echo -e "${RED}这里是容器或 OpenVZ：内核是宿主机的，换不了。${RESET}"; return 1
    fi
    if secure_boot_on; then
        echo -e "${RED}这台机器开了安全启动（Secure Boot）：XanMod 内核没有签名，装上会开不了机。${RESET}"
        echo -e "${YELLOW}要换内核，先在服务商的控制面板里关掉安全启动；或者选「1」用内核自带的 BBR。${RESET}"; return 1
    fi
    ensure_cmds curl gpg gzip || return 1
    local codename level pkg ans
    codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
    if [ -z "$codename" ] || ! xanmod_suite_ok "$codename"; then
        echo -e "${RED}XanMod 没有这个系统版本（${codename:-未知}）的软件源。支持的有 Debian 12 / 13、Ubuntu 24.04 等。${RESET}"; return 1
    fi
    level=$(cpu_level)
    if ! pkg=$(xanmod_package "$level" "$(xanmod_packages "$codename")"); then
        echo -e "${RED}XanMod 的 ${codename} 源里没有适合这颗 CPU（x86-64-v${level}）的内核包，或者包列表没能下载。${RESET}"; return 1
    fi
    echo -e "${CYAN}CPU 指令集级别：x86-64-v${level}  →  安装 ${pkg}（系统：${codename}）${RESET}"
    echo -e "${YELLOW}会装一个新内核并设为默认启动，重启后生效；当前内核保留在启动菜单里。${RESET}"
    read -rp "继续吗？[y/N]: " ans
    case "$ans" in [yY]*) ;; *) echo "已取消。"; return 0 ;; esac

    mkdir -p "$(dirname "$XANMOD_KEYRING")"
    if ! curl -fsSL --retry 3 --max-time 60 "$XANMOD_KEY_URL" | gpg --dearmor --yes -o "$XANMOD_KEYRING"; then
        echo -e "${RED}下载 XanMod 签名密钥失败。${RESET}"; return 1
    fi
    echo "deb [signed-by=${XANMOD_KEYRING}] ${XANMOD_REPO} ${codename} main" > "$XANMOD_LIST"
    wait_for_apt
    if ! apt-get update -qq; then
        echo -e "${RED}apt-get update 失败。${RESET}"; return 1
    fi
    local sim=""
    [ "${BBR_APT_SIMULATE:-}" = "1" ] && sim="-s"
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y $sim "$pkg"; then
        echo -e "${RED}安装 ${pkg} 失败。${RESET}"; return 1
    fi
    if [ -n "$sim" ]; then
        echo -e "${YELLOW}（模拟安装，没有真的装内核）${RESET}"; return 0
    fi
    # XanMod 的默认拥塞控制就是 BBR v3；参数照样写好，重启后两边一致
    cleanup_legacy_sysctl
    write_bbr_sysctl
    echo -e "${GREEN}✓ ${pkg} 已安装，重启后用上新内核与 BBR v3。${RESET}"
    read -rp "现在重启吗？[y/N]: " ans
    case "$ans" in [yY]*) reboot ;; esac
}

reset_bbr() {
    if [ ! -f "$BBR_SYSCTL" ] && [ ! -f "$BBR_MODULES" ]; then
        echo -e "${YELLOW}本脚本没有写过 BBR 设置。${RESET}"; return 0
    fi
    local orig="" line
    [ -f "$BBR_SYSCTL" ] && orig=$(sed -n 's/^# 原值 //p' "$BBR_SYSCTL")
    rm -f "$BBR_SYSCTL" "$BBR_MODULES"
    if [ -n "$orig" ]; then
        printf '%s\n' "$orig" | while IFS= read -r line; do
            sysctl -w "${line%% = *}=${line#* = }" >/dev/null 2>&1 || true
        done
    else
        sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
    fi
    # 再按系统自己的配置（sysctl.d 里其他文件）走一遍，和开机时一样
    sysctl --system >/dev/null 2>&1 || true
    echo -e "${GREEN}✓ 已移除本脚本的 BBR 设置，拥塞控制 $(current_cc)，默认队列 $(current_qdisc)。${RESET}"
    if [ "$(current_cc)" = "bbr" ] && ! xanmod_running; then
        local where
        where=$(grep -lsE '^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=[[:space:]]*bbr' /etc/sysctl.conf /etc/sysctl.d/*.conf | tr '\n' ' ')
        [ -n "$where" ] && echo -e "${YELLOW}拥塞控制仍是 bbr：${where}里也设置了它（不是本脚本写的，没有动）。${RESET}"
    fi
    xanmod_installed && echo -e "${YELLOW}XanMod 内核还在；要换回原内核：apt-get remove 'linux-image-*xanmod*' 'linux-headers-*xanmod*' 后重启。${RESET}"
    return 0
}

main_menu() {
    local choice
    fix_legacy_xanmod_repo
    while true; do
        echo
        echo -e "${CYAN}── BBR 管理 ──────────────────────────────────${RESET}"
        show_status
        echo -e "${CYAN}──────────────────────────────────────────────${RESET}"
        echo -e "  ${GREEN}1${RESET}  启用 BBR（内核自带）"
        echo -e "  ${GREEN}2${RESET}  换 XanMod 内核（BBR v3，Debian / Ubuntu x86_64）"
        echo -e "  ${GREEN}3${RESET}  恢复默认（移除本脚本的 BBR 设置）"
        echo -e "  ${GREEN}0${RESET}  返回"
        if ! read -rp "请选择 [0-3]: " choice; then
            echo; return 0
        fi
        case "$choice" in
            1) enable_bbr ;;
            2) install_xanmod ;;
            3) reset_bbr ;;
            0) return 0 ;;
            *) echo -e "${RED}无效的选择${RESET}" ;;
        esac
    done
}

main_menu
