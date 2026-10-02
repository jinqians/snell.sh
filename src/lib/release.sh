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
