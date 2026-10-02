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
