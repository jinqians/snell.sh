#!/bin/bash
# =========================================
# 作者: jinqians
# 日期: 2025年2月
# 网站：jinqians.com
# 描述: 这个脚本用于管理 Snell 代理的多用户配置
# =========================================

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 定义配置目录
SNELL_CONF_DIR="/etc/snell"
SNELL_CONF_FILE="${SNELL_CONF_DIR}/users/snell-main.conf"

# 定义目录和文件路径
INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
SNELL_SERVICE_USER="snell"
SNELL_SERVICE_GROUP="snell"

# Snell v6 加密模式：default / unshaped / unsafe-raw（客户端必须与服务端一致）
SNELL_MODE="default"

# 主服务的 systemd 单元（版本层用它定位主用户服务）
SYSTEMD_SERVICE_FILE="${SYSTEMD_DIR}/snell.service"

# 版本层里统一叫 get_snell_port，本脚本历史上叫 get_main_port
get_snell_port() {
    get_main_port
}

# =========================================
# 以下版本相关的公共逻辑与 snell.sh 保持一致。
# 本脚本以 bash <(curl ...) 独立运行，无法共享库文件，故按仓库既有约定复制一份。
# =========================================

# Snell 各通道的兜底版本（官网发布页解析失败时使用）
SNELL_V4_FALLBACK="v4.1.1"
SNELL_V5_FALLBACK="v5.0.1"
SNELL_V6_FALLBACK="v6.0.0rc2"

# Snell v6 加密模式与 DNS 解析偏好（客户端必须与服务端一致）
SNELL_DNS_IP_PREFERENCE=""
SNELL_V6_OPTIONS_SET="false"
# select_snell_v6_dns_preference 会读它来推导默认选项，调用前由 add_user 等赋值
IPV6_ENABLE="true"

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

# 读取主配置中的 mode（v6），读不到时回落到默认值
get_snell_mode() {
    local conf_file="${1:-$SNELL_CONF_FILE}"
    local mode=""
    if [ -f "$conf_file" ]; then
        mode=$(grep -E '^[[:space:]]*mode[[:space:]]*=' "$conf_file" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' ')
    fi
    if [ -z "$mode" ]; then
        mode="$SNELL_MODE"
    fi
    echo "$mode"
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

ensure_snell_service_user() {
    if ! getent group "${SNELL_SERVICE_GROUP}" >/dev/null 2>&1; then
        groupadd --system "${SNELL_SERVICE_GROUP}" 2>/dev/null || true
    fi

    if ! getent passwd "${SNELL_SERVICE_USER}" >/dev/null 2>&1; then
        useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin --gid "${SNELL_SERVICE_GROUP}" "${SNELL_SERVICE_USER}" 2>/dev/null || \
        useradd -r -M -s /usr/sbin/nologin -g "${SNELL_SERVICE_GROUP}" "${SNELL_SERVICE_USER}" 2>/dev/null || true
    fi
}

# 检查是否以 root 权限运行
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请以 root 权限运行此脚本.${RESET}"
        exit 1
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
    # 检查主配置文件
    if [ -f "${SNELL_CONF_DIR}/snell-server.conf" ]; then
        local main_port=$(grep -E '^listen' "${SNELL_CONF_DIR}/snell-server.conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
        if [ "$main_port" == "$port" ]; then
            return 1
        fi
    fi
    return 0
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

# 启动/重启服务并确认真的起来了；起不来打印日志尾部
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

# 切换/回滚用的备份统一放在 ${SNELL_CONF_DIR}/backup 下。
# 不能放进 users/ —— 多处循环是按 users/* 遍历的，备份文件会被当成真实用户。
snell_backup_path() {
    local src="$1"
    local stamp="$2"
    local dir="${SNELL_CONF_DIR}/backup"
    mkdir -p "$dir" 2>/dev/null || return 1
    echo "${dir}/$(basename "$src").${stamp}"
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
    echo -e "\n${YELLOW}=== 删除用户 ===${RESET}"
    
    # 显示用户列表
    list_users
    
    # 获取要删除的用户端口
    read -rp "请输入要删除的用户端口号: " del_port
    
    local user_conf="${SNELL_CONF_DIR}/users/snell-${del_port}.conf"
    local service_name="snell-${del_port}"
    
    if [ -f "$user_conf" ]; then
        # 停止并禁用服务
        systemctl stop "$service_name"
        systemctl disable "$service_name"
        
        # 删除服务文件
        rm -f "${SYSTEMD_DIR}/${service_name}.service"
        rm -f "/lib/systemd/system/${service_name}.service"
        # 删除配置文件
        rm -f "$user_conf"
        
        # 重载 systemd 配置
        systemctl daemon-reload
        
        echo -e "${GREEN}用户已成功删除${RESET}"
    else
        echo -e "${RED}未找到端口为 ${del_port} 的用户${RESET}"
    fi
}

# 修改用户配置
modify_user() {
    echo -e "\n${YELLOW}=== 修改用户配置 ===${RESET}"
    
    # 显示用户列表
    list_users
    
    # 获取要修改的用户端口
    read -rp "请输入要修改的用户端口号: " mod_port
    
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

                # 停止并注销旧服务
                systemctl stop "$service_name"
                systemctl disable "$service_name" 2>/dev/null

                # 修改配置文件中的端口
                sed -i "s/\(listen = .*:\)${mod_port}/\1${new_port}/" "$user_conf"

                # 重命名配置文件，服务文件整份重写（Description 带版本号，逐行 sed 已不适用）
                local new_conf="${SNELL_CONF_DIR}/users/snell-${new_port}.conf"
                mv "$user_conf" "$new_conf"
                rm -f "${SYSTEMD_DIR}/${service_name}.service"
                write_user_service_unit "$new_port" "$new_conf" "$mod_version"

                # 重载配置并启动服务
                systemctl daemon-reload
                systemctl enable "snell-${new_port}" 2>/dev/null
                if restart_and_verify_service "snell-${new_port}"; then
                    open_port "$new_port"
                    echo -e "${GREEN}端口修改成功: ${mod_port} -> ${new_port}${RESET}"
                else
                    echo -e "${RED}新端口服务启动失败，请检查上面的日志${RESET}"
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
                # 修改 DNS
                get_dns
                sed -i "s/dns = .*/dns = ${DNS}/" "$user_conf"
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
    
    # 获取要查看的用户端口
    read -rp "请输入要查看的用户端口号: " view_port
    
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
