#!/bin/sh
set -e

CONFIG_FILE="/etc/snell/snell-server.conf"

# 如果配置文件不存在，通过环境变量自动生成
if [ ! -f "$CONFIG_FILE" ]; then
    echo "配置文件不存在，自动生成..."

    # 端口: 优先使用环境变量，默认 6160
    SNELL_PORT="${SNELL_PORT:-6160}"

    # PSK: 优先使用环境变量，否则自动生成
    if [ -z "$SNELL_PSK" ]; then
        SNELL_PSK=$(head -c 16 /dev/urandom | base64)
        echo "========================================"
        echo "  自动生成的 PSK: ${SNELL_PSK}"
        echo "  请保存此 PSK，连接时需要使用"
        echo "========================================"
    fi

    # Snell 版本: v4 或 v5 配置有差异
    SNELL_VER="${SNELL_VER:-v4}"

    if [ "$SNELL_VER" = "v5" ]; then
        cat > "$CONFIG_FILE" << CONF
[snell-server]
listen = 0.0.0.0:${SNELL_PORT}
psk = ${SNELL_PSK}
CONF
    else
        IPV6="${SNELL_IPV6:-true}"
        TFO="${SNELL_TFO:-true}"
        cat > "$CONFIG_FILE" << CONF
[snell-server]
listen = 0.0.0.0:${SNELL_PORT}
psk = ${SNELL_PSK}
ipv6 = ${IPV6}
tfo = ${TFO}
CONF
    fi

    echo "配置文件已生成: $CONFIG_FILE"
    cat "$CONFIG_FILE"
fi

exec /app/snell-server -c "$CONFIG_FILE"
