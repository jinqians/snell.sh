#!/bin/sh
set -e

CONFIG_FILE="/etc/snell/snell-server.conf"
SHADOWTLS_PASSWORD_FILE="/etc/snell/shadowtls-password"

is_enabled() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

config_listen_port() {
    sed -n 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*.*:\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$CONFIG_FILE" | tail -n 1
}

# 如果配置文件不存在，通过环境变量自动生成
if [ ! -f "$CONFIG_FILE" ]; then
    echo "配置文件不存在，自动生成..."

    # 端口: 优先使用环境变量，默认 6160
    SNELL_PORT="${SNELL_PORT:-6160}"

    # PSK: 优先使用环境变量，否则自动生成
    if [ -z "${SNELL_PSK:-}" ]; then
        SNELL_PSK=$(head -c 16 /dev/urandom | base64)
        echo "========================================"
        echo "  自动生成的 PSK: ${SNELL_PSK}"
        echo "  请保存此 PSK，连接时需要使用"
        echo "========================================"
    fi

    # Snell 版本: v4/v5/v6 配置有差异
    SNELL_VER="${SNELL_VER:-v4}"

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
        echo "提示: 客户端需配置 version = 6 且 mode = ${SNELL_MODE}"
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
    cat "$CONFIG_FILE"
fi

if is_enabled "${SHADOWTLS_ENABLE:-0}"; then
    CONFIG_SNELL_PORT="$(config_listen_port || true)"
    SNELL_PORT="${SNELL_PORT:-${CONFIG_SNELL_PORT:-6160}}"
    SHADOWTLS_PORT="${SHADOWTLS_PORT:-8443}"
    SHADOWTLS_SNI="${SHADOWTLS_SNI:-www.microsoft.com}"

    if [ -z "${SHADOWTLS_PASSWORD:-}" ]; then
        if [ -f "$SHADOWTLS_PASSWORD_FILE" ]; then
            SHADOWTLS_PASSWORD="$(cat "$SHADOWTLS_PASSWORD_FILE")"
        else
            SHADOWTLS_PASSWORD=$(head -c 16 /dev/urandom | base64)
            printf '%s\n' "$SHADOWTLS_PASSWORD" > "$SHADOWTLS_PASSWORD_FILE"
            chmod 600 "$SHADOWTLS_PASSWORD_FILE"
            echo "========================================"
            echo "  自动生成的 ShadowTLS 密码: ${SHADOWTLS_PASSWORD}"
            echo "  已保存到: ${SHADOWTLS_PASSWORD_FILE}"
            echo "  请保存此密码，连接时需要使用"
            echo "========================================"
        fi
    fi

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
