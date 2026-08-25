#!/bin/sh
set -e

# =============================================================================
# Snell Server 容器入口脚本
#   1. 首次启动时按环境变量生成 /etc/snell/snell-server.conf
#   2. 每次启动都读取配置并输出可直接粘贴到 Surge 的客户端配置
#   3. 可选拉起 ShadowTLS v3 与 Snell 一起运行
# =============================================================================

CONFIG_DIR="/etc/snell"
CONFIG_FILE="${CONFIG_DIR}/snell-server.conf"
SHADOWTLS_PASSWORD_FILE="${CONFIG_DIR}/shadowtls-password"
CLIENT_FILE="${CONFIG_DIR}/client-config.txt"

is_enabled() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

# 从配置文件读取 key = value 形式的字段
config_get() {
    [ -f "$CONFIG_FILE" ] || return 0
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p" "$CONFIG_FILE" | tail -n 1
}

config_listen_port() {
    config_get listen | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p'
}

# 探测公网 IP：优先环境变量，其次外部接口，失败则留占位符
detect_public_ip() {
    if [ -n "${SNELL_SERVER_IP:-}" ]; then
        printf '%s' "$SNELL_SERVER_IP"
        return 0
    fi

    if ! is_enabled "${SNELL_IP_LOOKUP:-1}"; then
        printf '%s' "服务器IP"
        return 0
    fi

    for url in "http://ipv4.icanhazip.com" "http://api.ipify.org" "http://ifconfig.me/ip"; do
        ip=$(wget -q -T 3 -O - "$url" 2>/dev/null | tr -d '\r\n[:space:]')
        case "$ip" in
            *[0-9].[0-9]*)
                printf '%s' "$ip"
                return 0
                ;;
        esac
    done

    printf '%s' "服务器IP"
}

# 输出 Surge 客户端配置（同时写入 CLIENT_FILE 方便随时查看）
print_client_config() {
    snell_port="$(config_listen_port)"
    snell_port="${snell_port:-6160}"
    psk="$(config_get psk)"
    mode="$(config_get mode)"
    mode="${mode:-default}"
    node_name="${SNELL_NODE_NAME:-Snell}"
    server_ip="$(detect_public_ip)"

    if is_enabled "${SHADOWTLS_ENABLE:-0}"; then
        client_port="${SHADOWTLS_PORT:-8443}"
        stls_sni="${SHADOWTLS_SNI:-www.microsoft.com}"
        stls_pwd="${SHADOWTLS_PASSWORD:-}"
        if [ -z "$stls_pwd" ] && [ -f "$SHADOWTLS_PASSWORD_FILE" ]; then
            stls_pwd="$(cat "$SHADOWTLS_PASSWORD_FILE")"
        fi
        stls_suffix=", shadow-tls-password = ${stls_pwd}, shadow-tls-sni = ${stls_sni}, shadow-tls-version = 3"
    else
        client_port="$snell_port"
        stls_suffix=""
    fi

    {
        echo "=============================================================="
        echo "  Snell 客户端配置 (Surge 格式)"
        echo "=============================================================="
        echo "  服务器          : ${server_ip}"
        echo "  端口            : ${client_port}"
        echo "  PSK             : ${psk}"
        echo "  Snell 版本      : ${SNELL_VER#v}"
        if [ "$SNELL_VER" = "v6" ]; then
            echo "  加密模式        : ${mode}  (客户端必须一致)"
        fi
        if is_enabled "${SHADOWTLS_ENABLE:-0}"; then
            echo "  ShadowTLS       : v3, SNI = ${stls_sni}"
            echo "  ShadowTLS 密码  : ${stls_pwd}"
            echo "  Snell 后端端口  : ${snell_port} (仅容器内监听)"
        fi
        echo "--------------------------------------------------------------"
        case "$SNELL_VER" in
            v6)
                echo "${node_name} = snell, ${server_ip}, ${client_port}, psk = ${psk}, version = 6, mode = ${mode}, reuse = true, tfo = true${stls_suffix}"
                ;;
            v5)
                echo "${node_name} = snell, ${server_ip}, ${client_port}, psk = ${psk}, version = 5, reuse = true, tfo = true${stls_suffix}"
                echo "${node_name}-v4 = snell, ${server_ip}, ${client_port}, psk = ${psk}, version = 4, reuse = true, tfo = true${stls_suffix}"
                ;;
            *)
                echo "${node_name} = snell, ${server_ip}, ${client_port}, psk = ${psk}, version = 4, reuse = true, tfo = true${stls_suffix}"
                ;;
        esac
        echo "--------------------------------------------------------------"
        echo "  端口以宿主机实际映射为准，若映射端口不同请自行替换"
        echo "  以上内容已保存到 ${CLIENT_FILE}"
        echo "=============================================================="
    } | tee "$CLIENT_FILE" 2>/dev/null || true
}

mkdir -p "$CONFIG_DIR"

SNELL_VER="${SNELL_VER:-v4}"

# --- 1. 生成配置文件（仅首次启动） ---
if [ ! -f "$CONFIG_FILE" ]; then
    echo "配置文件不存在，按环境变量自动生成..."

    # 端口: 优先使用环境变量，默认 6160
    SNELL_PORT="${SNELL_PORT:-6160}"

    # PSK: 优先使用环境变量，否则自动生成
    if [ -z "${SNELL_PSK:-}" ]; then
        SNELL_PSK=$(head -c 16 /dev/urandom | base64)
    fi

    # Snell 版本: v4/v5/v6 配置有差异
    if [ "$SNELL_VER" = "v6" ]; then
        # v6: ipv6 参数已废弃，改用 mode / dns-ip-preference
        SNELL_MODE="${SNELL_MODE:-default}"
        DNS_IP_PREFERENCE="${SNELL_DNS_IP_PREFERENCE:-}"
        if [ -z "$DNS_IP_PREFERENCE" ]; then
            case "${SNELL_IPV6:-true}" in
                0|false|FALSE|no|NO|off|OFF) DNS_IP_PREFERENCE="ipv4-only" ;;
                *) DNS_IP_PREFERENCE="default" ;;
            esac
        fi
        cat > "$CONFIG_FILE" << CONF
[snell-server]
listen = ${SNELL_LISTEN_HOST:-0.0.0.0}:${SNELL_PORT}
psk = ${SNELL_PSK}
mode = ${SNELL_MODE}
dns-ip-preference = ${DNS_IP_PREFERENCE}
CONF
        if [ -n "${SNELL_DNS:-}" ]; then
            echo "dns = ${SNELL_DNS}" >> "$CONFIG_FILE"
        fi
    elif [ "$SNELL_VER" = "v5" ]; then
        cat > "$CONFIG_FILE" << CONF
[snell-server]
listen = ${SNELL_LISTEN_HOST:-0.0.0.0}:${SNELL_PORT}
psk = ${SNELL_PSK}
CONF
    else
        IPV6="${SNELL_IPV6:-true}"
        TFO="${SNELL_TFO:-true}"
        cat > "$CONFIG_FILE" << CONF
[snell-server]
listen = ${SNELL_LISTEN_HOST:-0.0.0.0}:${SNELL_PORT}
psk = ${SNELL_PSK}
ipv6 = ${IPV6}
tfo = ${TFO}
CONF
    fi

    echo "配置文件已生成: $CONFIG_FILE"
fi

# --- 2. 环境变量与已有配置不一致时给出提示 ---
# 配置文件已存在时不会被环境变量覆盖，否则会静默改掉正在使用的参数
warn_env_ignored() {
    key="$1"; env_value="$2"
    [ -n "$env_value" ] || return 0
    current="$(config_get "$key")"
    [ -n "$current" ] || return 0
    [ "$current" = "$env_value" ] && return 0
    echo "提示: 环境变量指定 ${key} = ${env_value}，但现有配置为 ${key} = ${current}"
    echo "      配置文件已存在，不会被环境变量覆盖，本次仍使用 ${current}"
    echo "      如需修改：编辑 ${CONFIG_FILE} 后重启容器，或删除该文件让容器重新生成（PSK 会变）"
}

if [ "$SNELL_VER" = "v6" ]; then
    warn_env_ignored "mode" "${SNELL_MODE:-}"
    warn_env_ignored "dns-ip-preference" "${SNELL_DNS_IP_PREFERENCE:-}"
fi
warn_env_ignored "psk" "${SNELL_PSK:-}"

# --- 3. 输出服务端配置 ---
echo
echo "===== 服务端配置 (${CONFIG_FILE}) ====="
cat "$CONFIG_FILE"
echo

# --- 4. ShadowTLS 密码准备（需在打印客户端配置之前完成） ---
if is_enabled "${SHADOWTLS_ENABLE:-0}"; then
    if [ -z "${SHADOWTLS_PASSWORD:-}" ]; then
        if [ -f "$SHADOWTLS_PASSWORD_FILE" ]; then
            SHADOWTLS_PASSWORD="$(cat "$SHADOWTLS_PASSWORD_FILE")"
        else
            SHADOWTLS_PASSWORD=$(head -c 16 /dev/urandom | base64)
            printf '%s\n' "$SHADOWTLS_PASSWORD" > "$SHADOWTLS_PASSWORD_FILE"
            chmod 600 "$SHADOWTLS_PASSWORD_FILE"
        fi
    fi
fi

# --- 5. 输出客户端配置 ---
print_client_config
echo

# --- 6. 启动服务 ---
if is_enabled "${SHADOWTLS_ENABLE:-0}"; then
    CONFIG_SNELL_PORT="$(config_listen_port || true)"
    SNELL_PORT="${SNELL_PORT:-${CONFIG_SNELL_PORT:-6160}}"
    SHADOWTLS_PORT="${SHADOWTLS_PORT:-8443}"
    SHADOWTLS_SNI="${SHADOWTLS_SNI:-www.microsoft.com}"

    echo "启动 Snell 后端: 127.0.0.1:${SNELL_PORT}"
    /app/snell-server -c "$CONFIG_FILE" &
    snell_pid=$!

    echo "启动 ShadowTLS v3: 0.0.0.0:${SHADOWTLS_PORT} -> 127.0.0.1:${SNELL_PORT}, SNI=${SHADOWTLS_SNI}"
    /app/shadow-tls --v3 server \
        --listen "0.0.0.0:${SHADOWTLS_PORT}" \
        --server "127.0.0.1:${SNELL_PORT}" \
        --tls "${SHADOWTLS_SNI}" \
        --password "${SHADOWTLS_PASSWORD}" &
    shadowtls_pid=$!

    trap 'kill "$snell_pid" "$shadowtls_pid" 2>/dev/null || true; wait 2>/dev/null || true' INT TERM

    while kill -0 "$snell_pid" 2>/dev/null && kill -0 "$shadowtls_pid" 2>/dev/null; do
        sleep 1
    done

    kill "$snell_pid" "$shadowtls_pid" 2>/dev/null || true
    wait 2>/dev/null || true
    exit 1
fi

exec /app/snell-server -c "$CONFIG_FILE"
