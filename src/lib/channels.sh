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

