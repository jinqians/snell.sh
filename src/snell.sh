#!/bin/bash
# =========================================
# 作者: jinqians
# 日期: 2025年2月
# 网站：jinqians.com
# 描述: 这个脚本用于安装、卸载、查看和更新 Snell 代理
#       Debian / Ubuntu / CentOS / RHEL / Rocky / AlmaLinux / Fedora（systemd）
# =========================================

# 共用部分（src/lib）。发布的 snell.sh 是 tools/build.sh 把它们合进来的单个文件，
# 直接运行 src/snell.sh 时从旁边的 lib 目录读。
SNELL_LIB="${SNELL_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib}"  # @dev
. "$SNELL_LIB/common.sh"    # @bundle
. "$SNELL_LIB/release.sh"   # @bundle
. "$SNELL_LIB/netinfo.sh"   # @bundle
. "$SNELL_LIB/firewall.sh"  # @bundle
. "$SNELL_LIB/channels.sh"  # @bundle
. "$SNELL_LIB/conf.sh"      # @bundle
. "$SNELL_LIB/routing.sh"   # @bundle

#当前版本号
current_version="6.1"

# 出口控制（netns + socket activation）默认参数
EGRESS_FEATURE_ENABLED="false"
EGRESS_IFACE=""
EGRESS_NS="snell-egress"
EGRESS_HOST_IP=""
EGRESS_NS_IP=""
EGRESS_SUBNET=""
EGRESS_GW=""

validate_snell_main_config() {
    migrate_legacy_main_config_if_needed || true

    if [ ! -s "$SNELL_CONF_FILE" ]; then
        echo -e "${RED}主配置文件不存在: ${SNELL_CONF_FILE}${RESET}"
        echo -e "${YELLOW}请先执行安装，或将旧配置放到该路径后再启动服务。${RESET}"
        return 1
    fi

    if ! grep -Eq '^[[:space:]]*listen[[:space:]]*=' "$SNELL_CONF_FILE"; then
        echo -e "${RED}主配置缺少 listen 配置: ${SNELL_CONF_FILE}${RESET}"
        return 1
    fi

    if ! grep -Eq '^[[:space:]]*psk[[:space:]]*=' "$SNELL_CONF_FILE"; then
        echo -e "${RED}主配置缺少 psk 配置: ${SNELL_CONF_FILE}${RESET}"
        return 1
    fi

    return 0
}

write_main_systemd_service() {
    ensure_snell_config_dir
    local snell_binary
    snell_binary=$(main_snell_binary)
    cat > ${SYSTEMD_SERVICE_FILE} << EOF
[Unit]
Description=Snell Proxy Service (Main)
After=network.target

[Service]
Type=simple
User=${SNELL_SERVICE_USER}
Group=${SNELL_SERVICE_GROUP}
# 服务加固：snell-server 只读配置、不写文件系统（与 netns 版 unit 保持一致）
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
ProtectKernelModules=yes
ReadOnlyPaths=/etc/snell
LimitNOFILE=32768
ExecStart=${snell_binary} -c ${SNELL_CONF_FILE}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
Restart=on-failure
RestartSec=2s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=snell-server

[Install]
WantedBy=multi-user.target
EOF
}

sync_existing_main_service_unit() {
    if [ ! -f "$SYSTEMD_SERVICE_FILE" ]; then
        return 0
    fi

    if systemctl is-enabled --quiet snell.socket 2>/dev/null; then
        return 0
    fi

    if grep -q "NetworkNamespacePath=" "$SYSTEMD_SERVICE_FILE"; then
        return 0
    fi

    if ! grep -Eq "ExecStart=${INSTALL_DIR}/snell-server(-v[456])? -c ${SNELL_CONF_FILE}" "$SYSTEMD_SERVICE_FILE"; then
        return 0
    fi

    if grep -q "StandardOutput=syslog\\|StandardError=syslog\\|User=nobody\\|Group=nogroup" "$SYSTEMD_SERVICE_FILE"; then
        write_main_systemd_service
        systemctl daemon-reload 2>/dev/null || true
        echo -e "${GREEN}已更新 snell.service systemd 配置。${RESET}"
    fi
}

# 根据 /30 子网生成 host/ns 地址与网关
apply_egress_subnet() {
    local subnet="$1"
    local base prefix

    base="${subnet%/30}"
    prefix="${base%.*}"

    EGRESS_SUBNET="$subnet"
    EGRESS_HOST_IP="${prefix}.1/30"
    EGRESS_NS_IP="${prefix}.2/30"
    EGRESS_GW="${prefix}.1"
}

# 自动选择未占用的 /30 子网（默认池：172.31.0.0/16）
auto_pick_egress_subnet() {
    local i candidate

    if ! command -v ip &> /dev/null; then
        apply_egress_subnet "172.31.0.0/30"
        return
    fi

    for i in $(seq 0 255); do
        candidate="172.31.${i}.0/30"
        if ip -o -4 addr show | grep -q "172\\.31\\.${i}\\."; then
            continue
        fi
        if ip -4 route show | grep -q "172\\.31\\.${i}\\."; then
            continue
        fi

        apply_egress_subnet "$candidate"
        return
    done

    apply_egress_subnet "172.31.0.0/30"
}

# 初始化默认网段
auto_pick_egress_subnet

# 自动检测默认出口网卡
auto_detect_egress_iface() {
    local detected_iface

    if command -v ip &> /dev/null; then
        detected_iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    fi

    if [ -n "$detected_iface" ]; then
        EGRESS_IFACE="$detected_iface"
    elif [ -z "$EGRESS_IFACE" ]; then
        EGRESS_IFACE="eth1"
    fi
}

# 初始化默认出口网卡
auto_detect_egress_iface

# 检查并迁移旧配置
check_and_migrate_config() {
    local old_files_exist=false

    # 自动修复 4.x -> 5.x 后服务指向新路径、配置仍在旧路径导致的启动失败。
    if [ ! -f "$SNELL_CONF_FILE" ] && [ -f "$OLD_SNELL_CONF_FILE" ]; then
        migrate_legacy_main_config_if_needed
        if [ -f "$SYSTEMD_SERVICE_FILE" ] && ! systemctl is-enabled --quiet snell.socket 2>/dev/null; then
            write_main_systemd_service
            systemctl daemon-reload 2>/dev/null || true
        fi
    fi

    # 检查仍需人工处理的旧配置。若主配置已自动迁移成功，仅保留旧文件不再反复提示。
    if { [ ! -f "$SNELL_CONF_FILE" ] && [ -f "$OLD_SNELL_CONF_FILE" ]; } || [ -f "$OLD_SYSTEMD_SERVICE_FILE" ]; then
        old_files_exist=true
        echo -e "\n${YELLOW}检测到旧版本的 Snell 配置文件${RESET}"
        echo -e "旧配置位置："
        [ -f "$OLD_SNELL_CONF_FILE" ] && echo -e "- 配置文件：${OLD_SNELL_CONF_FILE}"
        [ -f "$OLD_SYSTEMD_SERVICE_FILE" ] && echo -e "- 服务文件：${OLD_SYSTEMD_SERVICE_FILE}"
        
        # 检查用户目录是否存在
        if [ ! -d "${SNELL_CONF_DIR}/users" ]; then
            mkdir -p "${SNELL_CONF_DIR}/users"
            # 设置正确的目录权限（配置文件含 PSK，仅属主可读写）
            ensure_snell_service_user
            chown -R "${SNELL_SERVICE_USER}:${SNELL_SERVICE_GROUP}" "${SNELL_CONF_DIR}"
            find "${SNELL_CONF_DIR}" -type d -exec chmod 755 {} +
            find "${SNELL_CONF_DIR}" -name "*.conf" -exec chmod 600 {} +
        fi
    fi

    # 如果需要迁移，询问用户
    if [ "$old_files_exist" = true ]; then
        echo -e "\n${YELLOW}是否要迁移旧的配置文件？[y/N]${RESET}"
        read -r choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            echo -e "${CYAN}开始迁移配置文件...${RESET}"
            
            # 停止服务
            systemctl stop snell 2>/dev/null
            
            # 迁移配置文件
            if [ -f "$OLD_SNELL_CONF_FILE" ]; then
                cp "$OLD_SNELL_CONF_FILE" "${SNELL_CONF_FILE}"
                # 设置正确的文件权限
                ensure_snell_service_user
                chown "${SNELL_SERVICE_USER}:${SNELL_SERVICE_GROUP}" "${SNELL_CONF_FILE}"
                chmod 644 "${SNELL_CONF_FILE}"
                echo -e "${GREEN}已迁移配置文件${RESET}"
            fi
            
            # 迁移服务文件
            if [ -f "$OLD_SYSTEMD_SERVICE_FILE" ]; then
                write_main_systemd_service
                echo -e "${GREEN}已迁移服务文件${RESET}"
            fi
            
            # 询问是否删除旧文件
            echo -e "${YELLOW}是否删除旧的配置文件？[y/N]${RESET}"
            read -r del_choice
            if [[ "$del_choice" == "y" || "$del_choice" == "Y" ]]; then
                [ -f "$OLD_SNELL_CONF_FILE" ] && rm -f "$OLD_SNELL_CONF_FILE"
                [ -f "$OLD_SYSTEMD_SERVICE_FILE" ] && rm -f "$OLD_SYSTEMD_SERVICE_FILE"
                echo -e "${GREEN}已删除旧的配置文件${RESET}"
            fi
            
            # 重新加载服务
            systemctl daemon-reload
            if validate_snell_main_config; then
                systemctl start snell
            fi
            
            # 验证服务状态
            if systemctl is-active --quiet snell; then
                echo -e "${GREEN}配置迁移完成，服务已成功启动${RESET}"
            else
                echo -e "${RED}警告：服务启动失败，请检查配置文件和权限${RESET}"
                systemctl status snell
            fi
        else
            echo -e "${YELLOW}跳过配置迁移${RESET}"
        fi
    fi
}

check_root

# 是否启用 Snell v5/v6 出口控制
get_egress_feature_choice() {
    EGRESS_FEATURE_ENABLED="false"
    if [ "$SNELL_VERSION_CHOICE" != "v5" ] && [ "$SNELL_VERSION_CHOICE" != "v6" ]; then
        return
    fi

    echo -e "${CYAN}是否启用 Snell ${SNELL_VERSION_CHOICE} 出口控制（netns + socket activation）？${RESET}"
    echo -e "${GREEN}1.${RESET} 启用（新特性）"
    echo -e "${GREEN}2.${RESET} 不启用（推荐）"

    while true; do
        read -rp "请输入选项 [1-2]: " egress_choice
        case "$egress_choice" in
            1)
                EGRESS_FEATURE_ENABLED="true"
                echo -e "${GREEN}已启用 Snell v5 出口控制${RESET}"
                break
                ;;
            2)
                EGRESS_FEATURE_ENABLED="false"
                echo -e "${YELLOW}已选择传统模式${RESET}"
                break
                ;;
            *)
                echo -e "${RED}请输入正确的选项 [1-2]${RESET}"
                ;;
        esac
    done
}

# 获取出口控制相关参数
get_egress_settings() {
    if [ "$EGRESS_FEATURE_ENABLED" != "true" ]; then
        return
    fi

    auto_detect_egress_iface
    read -rp "请输入出口接口名称（默认 ${EGRESS_IFACE}）: " custom_iface
    if [ -n "$custom_iface" ]; then
        EGRESS_IFACE="$custom_iface"
    fi

    read -rp "请输入 netns 名称（默认 snell-egress）: " custom_ns
    if [ -n "$custom_ns" ]; then
        EGRESS_NS="$custom_ns"
    fi

    # 白名单校验：这两个值会被写入 root 执行的初始化脚本，
    # 非法字符可能导致脚本损坏或命令注入
    if ! [[ "$EGRESS_IFACE" =~ ^[a-zA-Z0-9_.-]{1,15}$ ]]; then
        echo -e "${RED}接口名称不合法（只允许字母、数字、_ . -，最长 15 字符），已恢复为自动检测值${RESET}"
        auto_detect_egress_iface
    fi
    if ! [[ "$EGRESS_NS" =~ ^[a-zA-Z0-9_.-]{1,16}$ ]]; then
        echo -e "${YELLOW}命名空间名称不合法（只允许字母、数字、_ . -），已恢复默认值 snell-egress${RESET}"
        EGRESS_NS="snell-egress"
    fi

    # 自动探测默认子网，并允许用户手工覆盖
    auto_pick_egress_subnet
    read -rp "请输入 veth 子网（CIDR，默认 ${EGRESS_SUBNET}）: " custom_subnet
    if [ -n "$custom_subnet" ]; then
        if [[ "$custom_subnet" =~ ^([0-9]{1,3}\.){3}0/30$ ]]; then
            apply_egress_subnet "$custom_subnet"
        else
            echo -e "${YELLOW}子网格式无效，继续使用自动选择：${EGRESS_SUBNET}${RESET}"
        fi
    fi

    echo -e "${GREEN}出口接口: ${EGRESS_IFACE}${RESET}"
    echo -e "${GREEN}命名空间: ${EGRESS_NS}${RESET}"
    echo -e "${GREEN}veth 子网: ${EGRESS_SUBNET}${RESET}"
    echo -e "${YELLOW}说明：${EGRESS_HOST_IP}（主命名空间） <-> ${EGRESS_NS_IP}（${EGRESS_NS}）${RESET}"
}

# 检查出口控制依赖
check_egress_dependencies() {
    if [ "$EGRESS_FEATURE_ENABLED" != "true" ]; then
        return
    fi

    ensure_cmds ip nft || exit 1
}

# 写入 netns 初始化单元
write_snell_netns_service() {
    cat > ${NETNS_SETUP_SCRIPT} << EOF
#!/bin/bash
set -eux

ip netns add ${EGRESS_NS} 2>/dev/null || true
ip link show veth-host >/dev/null 2>&1 || ip link add veth-host type veth peer name veth-snell
ip link set veth-snell netns ${EGRESS_NS} 2>/dev/null || true

ip addr replace ${EGRESS_HOST_IP} dev veth-host
ip link set veth-host up

ip netns exec ${EGRESS_NS} ip addr replace ${EGRESS_NS_IP} dev veth-snell
ip netns exec ${EGRESS_NS} ip link set lo up
ip netns exec ${EGRESS_NS} ip link set veth-snell up
ip netns exec ${EGRESS_NS} ip route replace default via ${EGRESS_GW}

mkdir -p /etc/netns/${EGRESS_NS}
cp -f /etc/resolv.conf /etc/netns/${EGRESS_NS}/resolv.conf
if grep -Eq '^nameserver[[:space:]]+127\\.0\\.0\\.53$' /etc/netns/${EGRESS_NS}/resolv.conf; then
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/netns/${EGRESS_NS}/resolv.conf
fi

sysctl -w net.ipv4.ip_forward=1

nft delete table ip snell_nat 2>/dev/null || true
nft add table ip snell_nat
nft add chain ip snell_nat postrouting '{ type nat hook postrouting priority 100; policy accept; }'
nft add rule ip snell_nat postrouting oifname "${EGRESS_IFACE}" ip saddr ${EGRESS_SUBNET} masquerade

nft add table inet snell_filter 2>/dev/null || true
nft list chain inet snell_filter forward >/dev/null 2>&1 || nft add chain inet snell_filter forward '{ type filter hook forward priority -5; policy accept; }'
nft add rule inet snell_filter forward iifname 'veth-host' oifname "${EGRESS_IFACE}" ip saddr ${EGRESS_SUBNET} accept 2>/dev/null || true
nft add rule inet snell_filter forward iifname "${EGRESS_IFACE}" oifname 'veth-host' ct state established,related accept 2>/dev/null || true

if command -v iptables >/dev/null 2>&1; then
    iptables -C FORWARD -i veth-host -o ${EGRESS_IFACE} -s ${EGRESS_SUBNET} -j ACCEPT 2>/dev/null || iptables -I FORWARD -i veth-host -o ${EGRESS_IFACE} -s ${EGRESS_SUBNET} -j ACCEPT
    iptables -C FORWARD -i ${EGRESS_IFACE} -o veth-host -d ${EGRESS_SUBNET} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -I FORWARD -i ${EGRESS_IFACE} -o veth-host -d ${EGRESS_SUBNET} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
fi
EOF
    chmod +x ${NETNS_SETUP_SCRIPT}

    cat > ${SYSTEMD_NETNS_FILE} << EOF
[Unit]
Description=Prepare netns and NAT for Snell egress
DefaultDependencies=no
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${NETNS_SETUP_SCRIPT}
ExecStop=/bin/true

[Install]
WantedBy=multi-user.target
EOF
}

# 写入 socket activation 单元
# listen_addr 可选：不传时从主配置的 listen 行推导，保证 socket 监听地址族与配置一致
# （之前写死 0.0.0.0，IPv6 用户开 egress 后 IPv6 监听会静默丢失）
write_snell_socket_service_units() {
    local listen_port=$1
    local listen_addr="${2:-}"
    local snell_binary
    snell_binary=$(main_snell_binary)

    if [ -z "$listen_addr" ] && [ -f "$SNELL_CONF_FILE" ]; then
        listen_addr=$(grep -E '^[[:space:]]*listen[[:space:]]*=' "$SNELL_CONF_FILE" | head -n 1 \
            | sed -n 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*\(.*\):[0-9][0-9]*[[:space:]]*$/\1/p')
    fi
    [ -z "$listen_addr" ] && listen_addr="0.0.0.0"

    local socket_stream="ListenStream=0.0.0.0:${listen_port}"
    local socket_datagram="ListenDatagram=0.0.0.0:${listen_port}"
    if [[ "$listen_addr" == *:* ]]; then
        socket_stream="ListenStream=[::]:${listen_port}"
        socket_datagram="ListenDatagram=[::]:${listen_port}"
    fi

    cat > ${SYSTEMD_SOCKET_FILE} << EOF
[Unit]
Description=Snell v5 (socket-activated)

[Socket]
${socket_stream}
${socket_datagram}
FileDescriptorName=snell_inet
ReusePort=no
NoDelay=true

[Install]
WantedBy=sockets.target
EOF

    cat > ${SYSTEMD_SERVICE_FILE} << EOF
[Unit]
Description=Snell Proxy Service (Main, netns)
Requires=snell-netns.service
After=snell-netns.service

[Service]
Type=simple
NetworkNamespacePath=/run/netns/${EGRESS_NS}
BindReadOnlyPaths=/etc/netns/${EGRESS_NS}/resolv.conf:/etc/resolv.conf
User=${SNELL_SERVICE_USER}
Group=${SNELL_SERVICE_GROUP}
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
ProtectKernelModules=yes
LimitNOFILE=32768
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
WorkingDirectory=${INSTALL_DIR}
ExecStart=${snell_binary} -c ${SNELL_CONF_FILE}
Restart=on-failure
RestartSec=2s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=snell-server

[Install]
WantedBy=multi-user.target
EOF
}

# 按端口释放监听进程：只自动处理 snell 相关进程；
# 非 snell 进程必须经用户明确确认才会结束，避免误杀 nginx/sshd 等服务
force_release_port_by_pid() {
    local port="$1"
    local pids pid cmd
    local snell_pids="" other_pids=""

    if command -v ss &> /dev/null; then
        pids=$( {
            ss -H -ltnp "( sport = :${port} )" 2>/dev/null
            ss -H -lunp "( sport = :${port} )" 2>/dev/null
        } | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | sort -u)
    elif command -v lsof &> /dev/null; then
        pids=$( {
            lsof -t -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null
            lsof -t -nP -iUDP:"${port}" 2>/dev/null
        } | sort -u)
    fi

    [ -z "$pids" ] && return 0

    for pid in $pids; do
        cmd=$(ps -p "$pid" -o args= 2>/dev/null)
        if echo "$cmd" | grep -q "snell"; then
            snell_pids="${snell_pids}${pid} "
        else
            other_pids="${other_pids}${pid} "
        fi
    done

    for pid in $snell_pids; do
        kill -TERM "$pid" 2>/dev/null || true
    done

    sleep 0.2

    if is_port_in_use "$port"; then
        if [ -n "$other_pids" ]; then
            echo -e "${RED}端口 ${port} 仍被以下非 Snell 进程占用:${RESET}"
            for pid in $other_pids; do
                echo -e "  PID ${pid}: $(ps -p "$pid" -o args= 2>/dev/null)"
            done
            echo -e "${YELLOW}是否强制结束这些进程以释放端口? [y/N]${RESET}"
            read -r kill_choice
            case "$kill_choice" in
                [yY]|[yY][eE][sS]) ;;
                *)
                    echo -e "${YELLOW}已取消，未释放端口 ${port}${RESET}"
                    return 1
                    ;;
            esac
            for pid in $other_pids; do
                kill -KILL "$pid" 2>/dev/null || true
            done
        else
            for pid in $snell_pids; do
                kill -KILL "$pid" 2>/dev/null || true
            done
        fi
    fi
    return 0
}

# 切换到 socket activation 前，确保主端口已释放
ensure_main_port_free_for_socket() {
    local port="$1"
    local i

    systemctl stop snell.socket 2>/dev/null
    systemctl stop snell 2>/dev/null
    systemctl disable snell 2>/dev/null
    systemctl reset-failed snell.socket 2>/dev/null

    # 兜底：避免残留 snell-server 进程继续占用端口
    systemctl kill snell --signal=SIGKILL 2>/dev/null
    pkill -f "${INSTALL_DIR}/snell-server -c ${SNELL_CONF_FILE}" 2>/dev/null || true
    # 用户拒绝释放非 snell 进程时直接中止，不再盲等 20 次
    force_release_port_by_pid "$port" || return 1

    for i in {1..20}; do
        if ! is_port_in_use "$port"; then
            return 0
        fi
        sleep 0.2
    done

    echo -e "${RED}端口 ${port} 仍被占用，无法启动 snell.socket。${RESET}"
    echo -e "${YELLOW}占用详情：${RESET}"
    show_port_occupier "$port"
    return 1
}

# 启用 egress 运行时：优先 socket + service；失败回退为 netns 直启服务
start_egress_runtime() {
    local port="$1"

    if ! ensure_main_port_free_for_socket "$port"; then
        return 1
    fi

    if ! systemctl enable snell.socket; then
        echo -e "${RED}启用 snell.socket 失败。${RESET}"
        return 1
    fi
    if ! systemctl start snell.socket; then
        echo -e "${RED}启动 snell.socket 失败。${RESET}"
        return 1
    fi

    # 关键：主动拉起 snell，确保 UDP/QUIC 可用，不依赖首次 TCP 触发
    if systemctl start snell; then
        echo -e "${GREEN}已启用 socket + service 运行模式。${RESET}"
        return 0
    fi

    echo -e "${YELLOW}socket 模式下主动拉起 snell 失败，自动回退到 netns 直启服务模式。${RESET}"
    systemctl stop snell.socket 2>/dev/null
    systemctl disable snell.socket 2>/dev/null

    if ! systemctl enable snell; then
        echo -e "${RED}回退模式：启用 snell 失败。${RESET}"
        return 1
    fi
    if ! systemctl restart snell; then
        echo -e "${RED}回退模式：启动 snell 失败。${RESET}"
        return 1
    fi

    echo -e "${GREEN}已回退为 netns 直启服务模式（无 socket 激活）。${RESET}"
    return 0
}

# 安装 Snell
# 写管理命令 /usr/local/bin/snell：每次运行都经短域名取最新脚本（地址由 Cloudflare 重定向，
# 脚本在仓库里换位置也不用改这里）
write_management_script() {
    mkdir -p /usr/local/bin
    cat > /usr/local/bin/snell << 'EOFSCRIPT'
#!/bin/bash

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 检查是否以 root 权限运行
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}请以 root 权限运行此脚本${RESET}"
    exit 1
fi

# 下载并执行最新版本的脚本（带完整性校验：传输失败即停、非空、语法检查）
echo -e "${CYAN}正在获取最新版本的管理脚本...${RESET}"
TMP_SCRIPT=$(mktemp)
if curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 https://snell.jinqians.com -o "$TMP_SCRIPT" \
    && [ -s "$TMP_SCRIPT" ] && bash -n "$TMP_SCRIPT" 2>/dev/null; then
    bash "$TMP_SCRIPT"
    rm -f "$TMP_SCRIPT"
else
    echo -e "${RED}下载或校验脚本失败，请检查网络连接。${RESET}"
    rm -f "$TMP_SCRIPT"
    exit 1
fi
EOFSCRIPT
    chmod +x /usr/local/bin/snell
}

# 旧版写的管理命令直连 raw.githubusercontent.com 上的固定路径（snell.sh / snell-centos.sh），
# 换成走短域名的新写法；不是本脚本写的文件不动
upgrade_management_script() {
    [ -f /usr/local/bin/snell ] || return 0
    grep -q 'raw.githubusercontent.com/jinqians/snell.sh/' /usr/local/bin/snell 2>/dev/null || return 0
    write_management_script && echo -e "${GREEN}已更新 snell 管理命令（改为经 snell.jinqians.com 获取最新脚本）${RESET}"
}

# 读主配置里 key = value 的值（取第一个 = 之后的全部，base64 PSK 里的 = 不会被截掉）
main_conf_value() {
    grep -E "^[[:space:]]*$1[[:space:]]*=" "$SNELL_CONF_FILE" 2>/dev/null | head -n 1 \
        | sed -e 's/^[^=]*=[[:space:]]*//' -e 's/[[:space:]]*$//'
}

install_snell() {
    echo -e "${CYAN}正在安装 Snell${RESET}"

    # 已存在主配置时先让用户选择，避免误触重装导致端口/PSK 被静默轮换
    local keep_existing_conf="false"
    if [ -f "$SNELL_CONF_FILE" ]; then
        local old_port old_ver
        old_port=$(get_snell_port)
        old_ver=$(get_conf_snell_version "$SNELL_CONF_FILE" 2>/dev/null)
        echo -e "${YELLOW}检测到已存在主用户配置：${SNELL_CONF_FILE}${RESET}"
        [ -n "$old_port" ] && echo -e "${YELLOW}  当前端口: ${old_port}${RESET}"
        [ -n "$old_ver" ] && echo -e "${YELLOW}  当前版本通道: ${old_ver}${RESET}"
        echo -e "${GREEN}1.${RESET} 保留现有端口和 PSK（仅重装二进制/修复服务）"
        echo -e "${GREEN}2.${RESET} 全新安装（重新生成端口和 PSK）"
        echo -e "${GREEN}0.${RESET} 取消"
        local reinstall_choice
        if ! read -rp "请输入选项 [0-2]: " reinstall_choice; then
            echo
            echo -e "${YELLOW}已取消安装。${RESET}"
            return 0
        fi
        case "$reinstall_choice" in
            1) keep_existing_conf="true" ;;
            2) keep_existing_conf="false" ;;
            0)
                echo -e "${YELLOW}已取消安装。${RESET}"
                return 0
                ;;
            *)
                echo -e "${RED}无效的选项，已取消安装。${RESET}"
                return 1
                ;;
        esac
    fi

    if [ "$keep_existing_conf" = "true" ]; then
        # 沿用已有配置的版本通道重装二进制，不重新询问安装参数
        SNELL_VERSION_CHOICE=$(get_conf_snell_version "$SNELL_CONF_FILE" 2>/dev/null)
        case "$SNELL_VERSION_CHOICE" in
            v4|v5|v6) ;;
            *)
                echo -e "${YELLOW}无法识别已有配置的版本通道，请手动选择要重装的版本。${RESET}"
                select_snell_version
                ;;
        esac
        # 从已有配置读取端口/PSK 等信息，供后续开防火墙、启服务、展示配置使用
        PORT=$(get_snell_port)
        PSK=$(main_conf_value psk)
        IPV6_ENABLE=$(main_conf_value ipv6)
        if [ -z "$IPV6_ENABLE" ]; then
            # v6 配置没有 ipv6 键，按 dns-ip-preference 推断（仅用于安装总结展示，不改配置）
            if [ "$(main_conf_value dns-ip-preference)" = "ipv4-only" ]; then
                IPV6_ENABLE="false"
            else
                IPV6_ENABLE="true"
            fi
        fi
        DNS=$(main_conf_value dns)
        [ -z "$DNS" ] && DNS="8.8.8.8"
        if [ -z "$PORT" ] || [ -z "$PSK" ]; then
            echo -e "${RED}已有配置缺少端口或 PSK，可能已损坏，请选择全新安装。${RESET}"
            return 1
        fi
        # 磁盘上已有 socket 单元说明之前启用了出口控制，沿用该模式
        # （netns 初始化脚本不重写：重写需要安装时的接口/子网参数，磁盘上的已是正确的）
        if [ -f "$SYSTEMD_SOCKET_FILE" ]; then
            EGRESS_FEATURE_ENABLED="true"
            # 从磁盘上的 netns 初始化脚本还原接口/命名空间名，socket 单元与安装总结要用
            if [ -f "${NETNS_SETUP_SCRIPT}" ]; then
                local keep_ns keep_iface
                keep_ns=$(sed -n 's/^ip netns add \([A-Za-z0-9_.-]\{1,\}\).*/\1/p' "${NETNS_SETUP_SCRIPT}" | head -n 1)
                [ -n "$keep_ns" ] && EGRESS_NS="$keep_ns"
                keep_iface=$(grep -o 'oifname "[^"]*"' "${NETNS_SETUP_SCRIPT}" 2>/dev/null | head -n 1 | cut -d'"' -f2)
                [ -n "$keep_iface" ] && EGRESS_IFACE="$keep_iface"
            fi
        else
            EGRESS_FEATURE_ENABLED="false"
        fi
        echo -e "${GREEN}将保留现有端口和 PSK，仅重装二进制并重写服务单元。${RESET}"
    else
        # 选择 Snell 版本
        select_snell_version
    fi

    ensure_cmds curl unzip || exit 1

    # 若机器上还是旧的单版本布局，先迁成版本化布局，避免装新通道时覆盖掉在用的二进制
    migrate_snell_binary_layout

    # 安装（或强制重装）所选通道的二进制，其他通道原样保留
    if ! install_snell_binary_for_version "$SNELL_VERSION_CHOICE" "true"; then
        echo -e "${RED}安装 Snell ${SNELL_VERSION_CHOICE} 失败。${RESET}"
        exit 1
    fi

    # 主用户所用通道决定 snell-server 软链指向
    update_snell_symlink "$SNELL_VERSION_CHOICE"

    if [ "$keep_existing_conf" != "true" ]; then
        get_user_port  # 获取用户输入的端口
        get_dns # 获取用户输入的 DNS 服务器
        get_ipv6_choice # 是否启用 IPv6
        # v6 需要额外选择 mode 与 dns-ip-preference
        if [ "$SNELL_VERSION_CHOICE" = "v6" ]; then
            configure_snell_v6_options
        fi
        get_egress_feature_choice
        get_egress_settings
        check_egress_dependencies
        PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)

        # 创建用户配置目录
        mkdir -p ${SNELL_CONF_DIR}/users

        # 将主用户配置存储在 users 目录下
        write_snell_conf "${SNELL_CONF_FILE}" "${LISTEN_ADDR}" "${PORT}" "${PSK}" "${IPV6_ENABLE}" "${DNS}" "${SNELL_VERSION_CHOICE}"
    fi

    write_main_systemd_service

    if [ "$EGRESS_FEATURE_ENABLED" = "true" ]; then
        # 保留模式沿用磁盘上的 netns 初始化脚本；snell.service 刚被改写成普通版，
        # socket 版的单元要重新写回（监听地址从配置里推导）
        if [ "$keep_existing_conf" != "true" ]; then
            write_snell_netns_service
            write_snell_socket_service_units "$PORT" "$LISTEN_ADDR"
        else
            write_snell_socket_service_units "$PORT"
        fi
    fi

    systemctl daemon-reload
    if [ $? -ne 0 ]; then
        echo -e "${RED}重载 Systemd 配置失败。${RESET}"
        exit 1
    fi

    if [ "$EGRESS_FEATURE_ENABLED" = "true" ]; then
        systemctl enable snell-netns
        if [ $? -ne 0 ]; then
            echo -e "${RED}启用 snell-netns 失败。${RESET}"
            exit 1
        fi

        systemctl start snell-netns
        if [ $? -ne 0 ]; then
            echo -e "${RED}启动 snell-netns 失败。${RESET}"
            exit 1
        fi

        if ! start_egress_runtime "$PORT"; then
            exit 1
        fi

        echo -e "${GREEN}snell.socket 已启动，snell 服务将按需拉起（首次连接触发）${RESET}"
        if [ "$SNELL_VERSION_CHOICE" = "v6" ]; then
            echo -e "${YELLOW}v6 已移除 QUIC 代理模式，客户端 version = 6 且 mode 需与服务端一致。${RESET}"
        else
            echo -e "${YELLOW}建议客户端优先使用 version = 4（v5 的 QUIC/UDP 依赖更高）。${RESET}"
        fi
    else
        systemctl stop snell.socket 2>/dev/null
        systemctl disable snell.socket 2>/dev/null
        systemctl stop snell-netns 2>/dev/null
        systemctl disable snell-netns 2>/dev/null

        systemctl enable snell
        if [ $? -ne 0 ]; then
            echo -e "${RED}开机自启动 Snell 失败。${RESET}"
            exit 1
        fi

        if ! validate_snell_main_config; then
            exit 1
        fi

        systemctl start snell
        if [ $? -ne 0 ]; then
            echo -e "${RED}启动 Snell 服务失败。${RESET}"
            exit 1
        fi
    fi

    # 开放端口
    open_port "$PORT"

    # 在安装完成后输出配置信息
    echo -e "\n${GREEN}安装完成！以下是您的配置信息：${RESET}"
    echo -e "${CYAN}--------------------------------${RESET}"
    if [ "$EGRESS_FEATURE_ENABLED" = "true" ]; then
        echo -e "${YELLOW}出口控制: 已启用（接口 ${EGRESS_IFACE}，命名空间 ${EGRESS_NS}）${RESET}"
        echo -e "${YELLOW}Socket 激活: snell.socket${RESET}"
    fi
    echo -e "${YELLOW}监听端口: ${PORT}${RESET}"
    echo -e "${YELLOW}PSK 密钥: ${PSK}${RESET}"
    echo -e "${YELLOW}IPv6: ${IPV6_ENABLE}${RESET}"
    echo -e "${YELLOW}DNS 服务器: ${DNS}${RESET}"
    echo -e "${CYAN}--------------------------------${RESET}"

    # 获取并显示服务器IP地址
    echo -e "\n${GREEN}服务器地址信息：${RESET}"
    
    # 获取 IPv4 地址
    IPV4_ADDR=$(get_public_ipv4)
    if [ $? -eq 0 ] && [ ! -z "$IPV4_ADDR" ]; then
        IP_COUNTRY_IPV4=$(get_ip_country "${IPV4_ADDR}")
        echo -e "${GREEN}IPv4 地址: ${RESET}${IPV4_ADDR} ${GREEN}所在国家: ${RESET}${IP_COUNTRY_IPV4}"
    fi

    # 获取 IPv6 地址
    IPV6_ADDR=$(get_public_ipv6)
    if [ $? -eq 0 ] && [ ! -z "$IPV6_ADDR" ]; then
        IP_COUNTRY_IPV6=$(get_ip_country "${IPV6_ADDR}")
        echo -e "${GREEN}IPv6 地址: ${RESET}${IPV6_ADDR} ${GREEN}所在国家: ${RESET}${IP_COUNTRY_IPV6}"
    fi

    # 输出 Surge 配置格式
    echo -e "\n${GREEN}Surge 配置格式：${RESET}"
    local installed_version="$SNELL_VERSION_CHOICE"
    if [ ! -z "$IPV4_ADDR" ]; then
        generate_surge_config "$IPV4_ADDR" "$PORT" "$PSK" "$SNELL_VERSION_CHOICE" "$IP_COUNTRY_IPV4" "$installed_version"
    fi
    
    if [ ! -z "$IPV6_ADDR" ]; then
        generate_surge_config "$IPV6_ADDR" "$PORT" "$PSK" "$SNELL_VERSION_CHOICE" "$IP_COUNTRY_IPV6" "$installed_version"
    fi


    # 创建管理脚本
    echo -e "${CYAN}正在安装管理脚本...${RESET}"
    if write_management_script; then
        echo -e "\n${GREEN}管理脚本安装成功！${RESET}"
        echo -e "${YELLOW}您可以在终端输入 'snell' 进入管理菜单。${RESET}"
        echo -e "${YELLOW}注意：需要使用 sudo snell 或以 root 身份运行。${RESET}\n"
    else
        echo -e "\n${RED}创建管理脚本失败。${RESET}"
        echo -e "${YELLOW}您可以通过直接运行原脚本来管理 Snell。${RESET}\n"
    fi
}

# 已安装 Snell v5/v6 的出口控制管理
configure_v5_egress_control() {
    echo -e "${CYAN}=============== v5/v6 出口控制设置 ===============${RESET}"

    if ! command -v snell-server &> /dev/null; then
        echo -e "${RED}未检测到 Snell，请先安装。${RESET}"
        return 1
    fi

    # 出口控制作用于主服务，因此按主配置的通道判断
    local installed_version
    installed_version=$(get_conf_snell_version "$SNELL_CONF_FILE")
    if [ "$installed_version" != "v5" ] && [ "$installed_version" != "v6" ]; then
        echo -e "${YELLOW}主用户当前使用 ${installed_version}，仅 Snell v5/v6 支持此设置。${RESET}"
        return 1
    fi

    local main_port
    main_port=$(get_snell_port)
    if [ -z "$main_port" ]; then
        echo -e "${RED}未找到主配置端口，请检查 ${SNELL_CONF_FILE}${RESET}"
        return 1
    fi

    local egress_enabled="false"
    if systemctl is-enabled snell.socket &> /dev/null || systemctl is-active snell.socket &> /dev/null; then
        egress_enabled="true"
    fi

    echo -e "${GREEN}主用户版本: Snell ${installed_version}${RESET}"
    echo -e "${GREEN}主端口: ${main_port}${RESET}"
    if [ "$egress_enabled" = "true" ]; then
        echo -e "${YELLOW}当前出口控制状态: 已启用${RESET}"
    else
        echo -e "${YELLOW}当前出口控制状态: 未启用${RESET}"
    fi

    echo -e "${GREEN}1.${RESET} 启用/更新 出口控制"
    echo -e "${GREEN}2.${RESET} 关闭 出口控制（恢复传统模式）"
    echo -e "${GREEN}0.${RESET} 返回"
    read -rp "请输入选项 [0-2]: " egress_manage_choice

    case "$egress_manage_choice" in
        1)
            if router_active; then
                echo -e "${RED}规则分流正在运行：出口控制把 Snell 放进单独的网络命名空间后，分流就拦不到它的流量。请先在菜单 12 停用分流。${RESET}"
                return 1
            fi
            EGRESS_FEATURE_ENABLED="true"
            get_egress_settings
            check_egress_dependencies

            write_snell_netns_service
            write_snell_socket_service_units "$main_port"

            systemctl daemon-reload
            if ! systemctl enable snell-netns; then
                echo -e "${RED}启用 snell-netns 失败。${RESET}"
                return 1
            fi
            if ! systemctl start snell-netns; then
                echo -e "${RED}启动 snell-netns 失败，请执行: systemctl status snell-netns.service${RESET}"
                return 1
            fi

            if ! start_egress_runtime "$main_port"; then
                return 1
            fi

            echo -e "${GREEN}已应用出口控制（接口 ${EGRESS_IFACE}，命名空间 ${EGRESS_NS}）。${RESET}"
            if [ "$installed_version" = "v6" ]; then
            echo -e "${YELLOW}v6 已移除 QUIC 代理模式，客户端 version = 6 且 mode 需与服务端一致。${RESET}"
        else
            echo -e "${YELLOW}建议客户端优先使用 version = 4（v5 的 QUIC/UDP 依赖更高）。${RESET}"
        fi
            echo -e "${YELLOW}说明：snell.socket 已监听，snell.service 将在首次连接时自动启动。${RESET}"
            ;;
        2)
            systemctl stop snell.socket 2>/dev/null
            systemctl disable snell.socket 2>/dev/null
            systemctl stop snell-netns 2>/dev/null
            systemctl disable snell-netns 2>/dev/null

            write_main_systemd_service

            rm -f ${SYSTEMD_SOCKET_FILE}
            rm -f ${SYSTEMD_NETNS_FILE}

            systemctl daemon-reload
            systemctl enable snell
            if ! validate_snell_main_config; then
                return 1
            fi
            systemctl restart snell

            echo -e "${GREEN}已关闭出口控制，恢复传统模式。${RESET}"
            ;;
        0)
            echo -e "${CYAN}已返回。${RESET}"
            ;;
        *)
            echo -e "${RED}请输入正确的选项 [0-2]${RESET}"
            ;;
    esac
}


# 卸载 Snell
uninstall_snell() {
    echo -e "${CYAN}正在卸载 Snell${RESET}"

    # 规则分流（sing-box）一起删掉：拦截规则、服务、配置
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
    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for user_conf in "${SNELL_CONF_DIR}/users"/*; do
            if [ -f "$user_conf" ]; then
                local port=$(grep -E '^listen' "$user_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
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

    # 清理出口控制残留：netns / veth / nft 表 / FORWARD 规则 / /etc/netns（不存在时静默跳过）
    # 命名空间名以 netns 初始化脚本中的实际值为准（用户可能自定义过），取不到则用默认值
    local egress_ns="${EGRESS_NS:-snell-egress}"
    if [ -f "${NETNS_SETUP_SCRIPT}" ]; then
        local script_ns
        script_ns=$(sed -n 's/^ip netns add \([A-Za-z0-9_.-]\{1,\}\).*/\1/p' "${NETNS_SETUP_SCRIPT}" | head -n 1)
        [ -n "$script_ns" ] && egress_ns="$script_ns"
    fi
    if command -v ip >/dev/null 2>&1; then
        [ -n "$egress_ns" ] && ip netns del "$egress_ns" 2>/dev/null || true
        # 删除 veth 对（删除一端，另一端自动消失）
        ip link del veth-host 2>/dev/null || true
    fi
    if [ -n "$egress_ns" ]; then
        rm -rf "/etc/netns/${egress_ns}" 2>/dev/null
    fi
    if command -v nft >/dev/null 2>&1; then
        # 精确删除本脚本建过的两张表（netns 初始化脚本建表处可查）
        nft delete table ip snell_nat 2>/dev/null || true
        nft delete table inet snell_filter 2>/dev/null || true
    fi
    if command -v iptables >/dev/null 2>&1; then
        # netns 脚本只加过含 veth-host 的 FORWARD 规则，按系统实际规则逐条精确删除
        local fwd_del
        while fwd_del=$(iptables -S FORWARD 2>/dev/null | grep -- '-A FORWARD.*veth-host' | head -n 1 | sed 's/^-A /-D /'); do
            [ -z "$fwd_del" ] && break
            # shellcheck disable=SC2086
            iptables $fwd_del 2>/dev/null || break
        done
    fi

    # 删除服务文件（含旧版 CentOS 脚本写的 preset）
    rm -f /lib/systemd/system/snell.service
    rm -f ${SYSTEMD_SERVICE_FILE}
    rm -f ${SYSTEMD_SOCKET_FILE}
    rm -f ${SYSTEMD_NETNS_FILE}
    rm -f ${NETNS_SETUP_SCRIPT}
    rm -f /usr/lib/systemd/system-preset/90-snell.preset

    # 删除各通道二进制、软链与更新时留下的备份
    local version
    for version in $SNELL_ALL_VERSIONS; do
        rm -f "$(snell_binary_for_version "$version")"
    done
    rm -f "${INSTALL_DIR}"/snell-server-v[456].bak.*
    rm -f ${INSTALL_DIR}/snell-server
    rm -rf ${SNELL_CONF_DIR}
    rm -f /usr/local/bin/snell  # 删除管理脚本

    if ! find "${SYSTEMD_DIR}" -maxdepth 1 -name "shadowtls-*.service" 2>/dev/null | grep -q .; then
        rm -f /usr/local/bin/shadow-tls
    fi

    # snell 系统用户/组默认保留，询问后才删除
    echo -e "${YELLOW}是否同时删除 snell 系统用户和用户组？[y/N]${RESET}"
    local del_snell_user
    if ! read -r del_snell_user; then
        del_snell_user=""
    fi
    if [[ "$del_snell_user" =~ ^[Yy]$ ]]; then
        if getent passwd snell >/dev/null 2>&1; then
            userdel snell 2>/dev/null && echo -e "${GREEN}已删除系统用户 snell${RESET}"
        fi
        if getent group snell >/dev/null 2>&1; then
            groupdel snell 2>/dev/null && echo -e "${GREEN}已删除用户组 snell${RESET}"
        fi
    else
        echo -e "${YELLOW}已保留 snell 系统用户和用户组。${RESET}"
    fi

    # 重载 systemd 配置
    systemctl daemon-reload

    echo -e "${GREEN}Snell 及其所有多用户配置已成功卸载${RESET}"
}

# 重启 Snell
restart_snell() {
    echo -e "${YELLOW}正在重启所有 Snell 服务...${RESET}"

    if ! validate_snell_main_config; then
        echo -e "${RED}已取消重启，避免 snell-server 在缺少配置时崩溃。${RESET}"
        return 1
    fi
    
    # 若使用 socket activation，先重启 socket 与 netns，再重启服务
    if systemctl list-unit-files | grep -q '^snell.socket'; then
        systemctl restart snell-netns 2>/dev/null
        systemctl restart snell.socket 2>/dev/null
    fi

    # 重启主服务
    systemctl restart snell
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}主 Snell 服务已成功重启。${RESET}"
    else
        echo -e "${RED}重启主 Snell 服务失败。${RESET}"
    fi

    # 重启所有多用户服务
    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for user_conf in "${SNELL_CONF_DIR}/users"/*; do
            if [ -f "$user_conf" ] && [[ "$user_conf" != *"snell-main.conf" ]]; then
                local port=$(grep -E '^listen' "$user_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
                if [ ! -z "$port" ]; then
                    echo -e "${YELLOW}正在重启用户服务 (端口: $port)${RESET}"
                    systemctl restart "snell-${port}" 2>/dev/null
                    if [ $? -eq 0 ]; then
                        echo -e "${GREEN}用户服务 (端口: $port) 已成功重启。${RESET}"
                    else
                        echo -e "${RED}重启用户服务 (端口: $port) 失败。${RESET}"
                    fi
                fi
            fi
        done
    fi
}
# 检查服务状态并显示
check_and_show_status() {
    echo -e "\n${CYAN}=============== 服务状态检查 ===============${RESET}"
    
    # 检查 Snell 状态
    if command -v snell-server &> /dev/null; then
        # 初始化计数器和资源使用变量
        local user_count=0
        local running_count=0
        local total_snell_memory=0
        local total_snell_cpu=0
        
        # 检查主服务状态
        local main_available=false
        if systemctl is-active snell &> /dev/null; then
            main_available=true
        elif systemctl is-active snell.socket &> /dev/null; then
            # socket activation 场景下，服务可能按需拉起
            main_available=true
        fi

        if [ "$main_available" = "true" ]; then
            user_count=$((user_count + 1))
            running_count=$((running_count + 1))
            
            # 获取主服务资源使用情况
            local main_pid=$(systemctl show -p MainPID snell | cut -d'=' -f2)
            if [ ! -z "$main_pid" ] && [ "$main_pid" != "0" ]; then
                local mem=$(ps -o rss= -p $main_pid 2>/dev/null)
                local cpu=$(ps -o %cpu= -p $main_pid 2>/dev/null)
                if [ ! -z "$mem" ]; then
                    total_snell_memory=$((total_snell_memory + mem))
                fi
                if [ ! -z "$cpu" ]; then
                    total_snell_cpu=$(echo "$total_snell_cpu + $cpu" | bc -l)
                fi
            fi
        else
            user_count=$((user_count + 1))
        fi
        
        # 检查多用户状态
        if [ -d "${SNELL_CONF_DIR}/users" ]; then
            for user_conf in "${SNELL_CONF_DIR}/users"/*; do
                if [ -f "$user_conf" ] && [[ "$user_conf" != *"snell-main.conf" ]]; then
                    local port=$(grep -E '^listen' "$user_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
                    if [ ! -z "$port" ]; then
                        user_count=$((user_count + 1))
                        if systemctl is-active --quiet "snell-${port}"; then
                            running_count=$((running_count + 1))
                            
                            # 获取用户服务资源使用情况
                            local user_pid=$(systemctl show -p MainPID "snell-${port}" | cut -d'=' -f2)
                            if [ ! -z "$user_pid" ] && [ "$user_pid" != "0" ]; then
                                local mem=$(ps -o rss= -p $user_pid 2>/dev/null)
                                local cpu=$(ps -o %cpu= -p $user_pid 2>/dev/null)
                                if [ ! -z "$mem" ]; then
                                    total_snell_memory=$((total_snell_memory + mem))
                                fi
                                if [ ! -z "$cpu" ]; then
                                    total_snell_cpu=$(echo "$total_snell_cpu + $cpu" | bc -l)
                                fi
                            fi
                        fi
                    fi
                fi
            done
        fi
        
        # 显示 Snell 状态
        local total_snell_memory_mb=$(echo "scale=2; $total_snell_memory/1024" | bc)
        printf "${GREEN}Snell 已安装${RESET}  ${YELLOW}CPU：%.2f%%${RESET}  ${YELLOW}内存：%.2f MB${RESET}  ${GREEN}运行中：${running_count}/${user_count}${RESET}\n" "$total_snell_cpu" "$total_snell_memory_mb"

        # 已安装的通道，以及各自被多少个服务使用
        local installed_channels channel channel_summary=""
        installed_channels=$(list_installed_snell_versions)
        if [ -n "$installed_channels" ]; then
            for channel in $installed_channels; do
                channel_summary="${channel_summary}${channel}(×$(list_services_using_version "$channel" | grep -c .)) "
            done
            echo -e "${GREEN}已安装通道${RESET}  ${YELLOW}${channel_summary}${RESET}"
        fi
    else
        echo -e "${YELLOW}Snell 未安装${RESET}"
    fi
    
    # 检查 ShadowTLS 状态
    if [ -f "/usr/local/bin/shadow-tls" ]; then
        # 初始化 ShadowTLS 服务计数器和资源使用
        local stls_total=0
        local stls_running=0
        local total_stls_memory=0
        local total_stls_cpu=0
        declare -A processed_ports
        
        # 检查 Snell 的 ShadowTLS 服务
        local snell_services=$(find /etc/systemd/system -name "shadowtls-snell-*.service" 2>/dev/null | sort -u)
        if [ ! -z "$snell_services" ]; then
            while IFS= read -r service_file; do
                local port=$(basename "$service_file" | sed 's/shadowtls-snell-\([0-9]*\)\.service/\1/')
                
                # 检查是否已处理过该端口
                if [ -z "${processed_ports[$port]}" ]; then
                    processed_ports[$port]=1
                    stls_total=$((stls_total + 1))
                    if systemctl is-active "shadowtls-snell-${port}" &> /dev/null; then
                        stls_running=$((stls_running + 1))
                        
                        # 获取 ShadowTLS 服务资源使用情况
                        local stls_pid=$(systemctl show -p MainPID "shadowtls-snell-${port}" | cut -d'=' -f2)
                        if [ ! -z "$stls_pid" ] && [ "$stls_pid" != "0" ]; then
                            local mem=$(ps -o rss= -p $stls_pid 2>/dev/null)
                            local cpu=$(ps -o %cpu= -p $stls_pid 2>/dev/null)
                            if [ ! -z "$mem" ]; then
                                total_stls_memory=$((total_stls_memory + mem))
                            fi
                            if [ ! -z "$cpu" ]; then
                                total_stls_cpu=$(echo "$total_stls_cpu + $cpu" | bc -l)
                            fi
                        fi
                    fi
                fi
            done <<< "$snell_services"
        fi
        
        # 显示 ShadowTLS 状态
        if [ $stls_total -gt 0 ]; then
            local total_stls_memory_mb=$(echo "scale=2; $total_stls_memory/1024" | bc)
            printf "${GREEN}ShadowTLS 已安装${RESET}  ${YELLOW}CPU：%.2f%%${RESET}  ${YELLOW}内存：%.2f MB${RESET}  ${GREEN}运行中：${stls_running}/${stls_total}${RESET}\n" "$total_stls_cpu" "$total_stls_memory_mb"
        else
            echo -e "${YELLOW}ShadowTLS 未安装${RESET}"
        fi
    else
        echo -e "${YELLOW}ShadowTLS 未安装${RESET}"
    fi

    # 规则分流（只在启用过时显示）
    if router_active; then
        echo -e "${GREEN}规则分流 运行中${RESET}  ${YELLOW}$(jq '.rules | length' "$ROUTER_STATE" 2>/dev/null || echo 0) 条规则${RESET}"
    elif router_installed; then
        echo -e "${YELLOW}规则分流 已停用${RESET}"
    fi
    
    echo -e "${CYAN}============================================${RESET}\n"
}

# 查看配置
view_snell_config() {
    echo -e "${GREEN}Snell 配置信息:${RESET}"
    echo -e "${CYAN}================================${RESET}"
    
    # 每个用户可以用不同通道，这里只列出机器上装了哪些
    local installed_channels
    installed_channels=$(list_installed_snell_versions)
    if [ -n "$installed_channels" ]; then
        echo -e "${YELLOW}已安装通道: ${installed_channels}${RESET}"
    else
        echo -e "${YELLOW}未检测到已安装的 Snell 通道${RESET}"
    fi
    
    # 获取 IPv4 地址
    IPV4_ADDR=$(get_public_ipv4)
    if [ $? -eq 0 ] && [ ! -z "$IPV4_ADDR" ]; then
        IP_COUNTRY_IPV4=$(get_ip_country "${IPV4_ADDR}")
        echo -e "${GREEN}IPv4 地址: ${RESET}${IPV4_ADDR} ${GREEN}所在国家: ${RESET}${IP_COUNTRY_IPV4}"
    fi

    # 获取 IPv6 地址
    IPV6_ADDR=$(get_public_ipv6)
    if [ $? -eq 0 ] && [ ! -z "$IPV6_ADDR" ]; then
        IP_COUNTRY_IPV6=$(get_ip_country "${IPV6_ADDR}")
        echo -e "${GREEN}IPv6 地址: ${RESET}${IPV6_ADDR} ${GREEN}所在国家: ${RESET}${IP_COUNTRY_IPV6}"
    fi

    # 检查是否获取到 IP 地址
    if [ -z "$IPV4_ADDR" ] && [ -z "$IPV6_ADDR" ]; then
        echo -e "${RED}无法获取到公网 IP 地址，请检查网络连接。${RESET}"
        return
    fi
    
    echo -e "\n${YELLOW}=== 用户配置列表 ===${RESET}"
    
    # 显示主用户配置
    local main_conf="${SNELL_CONF_DIR}/users/snell-main.conf"
    if [ -f "$main_conf" ]; then
        echo -e "\n${GREEN}主用户配置：${RESET}"
        local main_port=$(grep -E '^listen' "$main_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
        local main_psk=$(grep -E '^psk' "$main_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local main_ipv6=$(grep -E '^[[:space:]]*ipv6[[:space:]]*=' "$main_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local main_dns=$(grep -E '^[[:space:]]*dns[[:space:]]*=' "$main_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local main_mode=$(grep -E '^[[:space:]]*mode[[:space:]]*=' "$main_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local main_dns_pref=$(grep -E '^[[:space:]]*dns-ip-preference[[:space:]]*=' "$main_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local main_version=$(get_conf_snell_version "$main_conf")

        echo -e "${YELLOW}端口: ${main_port}${RESET}"
        echo -e "${YELLOW}版本: Snell ${main_version}${RESET}"
        echo -e "${YELLOW}PSK: ${main_psk}${RESET}"
        [ -n "$main_ipv6" ] && echo -e "${YELLOW}IPv6: ${main_ipv6}${RESET}"
        [ -n "$main_mode" ] && echo -e "${YELLOW}模式 (mode): ${main_mode}${RESET}"
        [ -n "$main_dns_pref" ] && echo -e "${YELLOW}DNS 解析偏好: ${main_dns_pref}${RESET}"
        echo -e "${YELLOW}DNS: ${main_dns}${RESET}"
        
        echo -e "\n${GREEN}Surge 配置格式：${RESET}"
        if [ ! -z "$IPV4_ADDR" ]; then
            generate_surge_config "$IPV4_ADDR" "$main_port" "$main_psk" "$main_version" "$IP_COUNTRY_IPV4" "$main_version"
        fi
        if [ ! -z "$IPV6_ADDR" ]; then
            generate_surge_config "$IPV6_ADDR" "$main_port" "$main_psk" "$main_version" "$IP_COUNTRY_IPV6" "$main_version"
        fi
    fi
    
    # 显示其他用户配置
    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for user_conf in "${SNELL_CONF_DIR}/users"/*; do
            if [ -f "$user_conf" ] && [[ "$user_conf" != *"snell-main.conf" ]]; then
                local user_port=$(grep -E '^listen' "$user_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
                local user_psk=$(grep -E '^psk' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
                local user_ipv6=$(grep -E '^[[:space:]]*ipv6[[:space:]]*=' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
                local user_dns=$(grep -E '^[[:space:]]*dns[[:space:]]*=' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
                local user_mode=$(grep -E '^[[:space:]]*mode[[:space:]]*=' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
                local user_dns_pref=$(grep -E '^[[:space:]]*dns-ip-preference[[:space:]]*=' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
                local user_version=$(get_conf_snell_version "$user_conf")

                echo -e "\n${GREEN}用户配置 (端口: ${user_port}):${RESET}"
                echo -e "${YELLOW}版本: Snell ${user_version}${RESET}"
                echo -e "${YELLOW}PSK: ${user_psk}${RESET}"
                [ -n "$user_ipv6" ] && echo -e "${YELLOW}IPv6: ${user_ipv6}${RESET}"
                [ -n "$user_mode" ] && echo -e "${YELLOW}模式 (mode): ${user_mode}${RESET}"
                [ -n "$user_dns_pref" ] && echo -e "${YELLOW}DNS 解析偏好: ${user_dns_pref}${RESET}"
                echo -e "${YELLOW}DNS: ${user_dns}${RESET}"
                
                echo -e "\n${GREEN}Surge 配置格式：${RESET}"
                if [ ! -z "$IPV4_ADDR" ]; then
                    generate_surge_config "$IPV4_ADDR" "$user_port" "$user_psk" "$user_version" "$IP_COUNTRY_IPV4" "$user_version"
                fi
                if [ ! -z "$IPV6_ADDR" ]; then
                    generate_surge_config "$IPV6_ADDR" "$user_port" "$user_psk" "$user_version" "$IP_COUNTRY_IPV6" "$user_version"
                fi
            fi
        done
    fi
    
    # 如果 ShadowTLS 已安装，显示组合配置（版本按后端端口各自的通道取）
    local snell_services=$(find /etc/systemd/system -name "shadowtls-snell-*.service" 2>/dev/null | sort -u)
    if [ ! -z "$snell_services" ]; then
        echo -e "\n${YELLOW}=== ShadowTLS 组合配置 ===${RESET}"
        declare -A processed_ports
        while IFS= read -r service_file; do
            local exec_line=$(grep "ExecStart=" "$service_file")
            local stls_port=$(echo "$exec_line" | grep -oP '(?<=--listen ::0:)\d+')
            local stls_password=$(echo "$exec_line" | grep -oP '(?<=--password )[^ ]+')
            local stls_domain=$(echo "$exec_line" | grep -oP '(?<=--tls )[^ ]+')
            local snell_port=$(echo "$exec_line" | grep -oP '(?<=--server 127.0.0.1:)\d+')
            # 查找 psk
            local psk=""
            if [ -f "${SNELL_CONF_DIR}/users/snell-${snell_port}.conf" ]; then
                psk=$(grep -E '^psk' "${SNELL_CONF_DIR}/users/snell-${snell_port}.conf" | awk -F'=' '{print $2}' | tr -d ' ')
            elif [ -f "${SNELL_CONF_DIR}/users/snell-main.conf" ] && [ "$snell_port" = "$(get_snell_port)" ]; then
                psk=$(grep -E '^psk' "${SNELL_CONF_DIR}/users/snell-main.conf" | awk -F'=' '{print $2}' | tr -d ' ')
            fi
            # 避免重复
            if [ -z "$snell_port" ] || [ -z "$psk" ] || [ -n "${processed_ports[$snell_port]}" ]; then
                continue
            fi
            processed_ports[$snell_port]=1
            local snell_version=$(get_port_snell_version "$snell_port")
            local snell_mode=$(get_snell_mode "$(snell_conf_for_port "$snell_port")")
            if [ "$snell_port" = "$(get_snell_port)" ]; then
                echo -e "\n${GREEN}主用户 ShadowTLS 配置：${RESET}"
            else
                echo -e "\n${GREEN}用户 ShadowTLS 配置 (端口: ${snell_port})：${RESET}"
            fi
            echo -e "  - Snell 端口：${snell_port}"
            echo -e "  - PSK：${psk}"
            echo -e "  - ShadowTLS 监听端口：${stls_port}"
            echo -e "  - ShadowTLS 密码：${stls_password}"
            echo -e "  - ShadowTLS SNI：${stls_domain}"
            echo -e "  - 版本：3"
            echo -e "  - Snell 版本：${snell_version}"
            echo -e "\n${GREEN}Surge 配置格式：${RESET}"
            if [ ! -z "$IPV4_ADDR" ]; then
                if [ "$snell_version" = "v6" ]; then
                    echo -e "${GREEN}${IP_COUNTRY_IPV4} = snell, ${IPV4_ADDR}, ${stls_port}, psk = ${psk}, version = 6, mode = ${snell_mode}, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                elif [ "$snell_version" = "v5" ]; then
                    echo -e "${GREEN}${IP_COUNTRY_IPV4} = snell, ${IPV4_ADDR}, ${stls_port}, psk = ${psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                    echo -e "${GREEN}${IP_COUNTRY_IPV4} = snell, ${IPV4_ADDR}, ${stls_port}, psk = ${psk}, version = 5, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                else
                    echo -e "${GREEN}${IP_COUNTRY_IPV4} = snell, ${IPV4_ADDR}, ${stls_port}, psk = ${psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                fi
            fi
            if [ ! -z "$IPV6_ADDR" ]; then
                if [ "$snell_version" = "v6" ]; then
                    echo -e "${GREEN}${IP_COUNTRY_IPV6} = snell, ${IPV6_ADDR}, ${stls_port}, psk = ${psk}, version = 6, mode = ${snell_mode}, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                elif [ "$snell_version" = "v5" ]; then
                    echo -e "${GREEN}${IP_COUNTRY_IPV6} = snell, ${IPV6_ADDR}, ${stls_port}, psk = ${psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                    echo -e "${GREEN}${IP_COUNTRY_IPV6} = snell, ${IPV6_ADDR}, ${stls_port}, psk = ${psk}, version = 5, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                else
                    echo -e "${GREEN}${IP_COUNTRY_IPV6} = snell, ${IPV6_ADDR}, ${stls_port}, psk = ${psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                fi
            fi
        done <<< "$snell_services"
    fi
    
    echo -e "\n${YELLOW}注意：${RESET}"
    echo -e "1. Snell 仅支持 Surge 客户端"
    echo -e "2. 请将配置中的服务器地址替换为实际可用的地址"
    read -p "按任意键返回主菜单..."
}

# 更新单个通道的二进制到最新版本。
# 不改动任何用户的通道归属，配置格式因此不变，只重启用到该通道的服务。
update_snell_channel() {
    local version="$1"
    local target
    target=$(snell_binary_for_version "$version")

    echo -e "\n${CYAN}=============== 更新 Snell ${version} 通道 ===============${RESET}"
    echo -e "${GREEN}✓ 只替换 ${version} 的二进制，其他通道原样不动${RESET}"
    echo -e "${GREEN}✓ 端口、密码、用户配置都不会改变${RESET}"

    local services
    services=$(list_services_using_version "$version")
    if [ -n "$services" ]; then
        echo -e "${YELLOW}将重启：$(echo "$services" | tr '\n' ' ')${RESET}"
    else
        echo -e "${YELLOW}当前没有服务在使用 ${version} 通道，仅更新二进制${RESET}"
    fi

    # 配置与二进制各留一个回滚点
    local backup_dir
    backup_dir=$(backup_snell_config)
    echo -e "${GREEN}配置已备份到: ${backup_dir}${RESET}"

    local backup_binary=""
    if [ -f "$target" ]; then
        backup_binary="${target}.bak.$(date +%Y%m%d_%H%M%S)"
        if cp -a "$target" "$backup_binary"; then
            echo -e "${GREEN}原二进制已备份到: ${backup_binary}${RESET}"
        else
            echo -e "${YELLOW}警告：二进制备份失败，更新失败时将无法自动回滚${RESET}"
            backup_binary=""
        fi
    fi

    if ! install_snell_binary_for_version "$version" "true"; then
        if [ -n "$backup_binary" ]; then
            cp -a "$backup_binary" "$target" && echo -e "${YELLOW}已回滚到更新前的二进制${RESET}"
        fi
        return 1
    fi

    # 主用户用的就是这个通道时，软链跟着走
    if [ "$(get_conf_snell_version "$SNELL_CONF_FILE")" = "$version" ]; then
        update_snell_symlink "$version"
    fi

    local service failed=""
    while IFS= read -r service; do
        [ -n "$service" ] || continue
        if [ "$service" = "snell" ] && ! validate_snell_main_config; then
            failed="${failed}${service} "
            continue
        fi
        echo -e "${CYAN}正在重启 ${service}...${RESET}"
        if ! restart_and_verify_service "$service"; then
            failed="${failed}${service} "
        fi
    done <<< "$services"

    if [ -n "$failed" ]; then
        echo -e "\n${RED}以下服务未能正常启动: ${failed}${RESET}"
        if [ -n "$backup_binary" ]; then
            echo -e "${YELLOW}正在回滚 ${version} 通道的二进制...${RESET}"
            cp -a "$backup_binary" "$target"
            for service in $failed; do
                systemctl restart "$service" 2>/dev/null
            done
            echo -e "${YELLOW}已回滚。配置备份仍保留在 ${backup_dir}${RESET}"
        fi
        return 1
    fi

    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}✅ Snell ${version} 通道更新完成（$(get_channel_binary_version "$version")）${RESET}"
    echo -e "${GREEN}✓ 其他通道与全部配置未受影响${RESET}"
    echo -e "${YELLOW}配置备份目录: ${backup_dir}${RESET}"
    echo -e "${CYAN}============================================${RESET}"

    # 回滚点的使命到此结束，删掉避免 ${INSTALL_DIR} 里越积越多
    [ -n "$backup_binary" ] && rm -f "$backup_binary"
    return 0
}

# 把一个配置切换到目标通道：备好二进制 -> 迁移配置参数 -> 改 unit -> 重启，失败自动回滚
switch_conf_to_version() {
    local conf_file="$1"
    local target_version="$2"
    local port service unit current_version

    if [ ! -f "$conf_file" ]; then
        echo -e "${RED}配置不存在: ${conf_file}${RESET}"
        return 1
    fi

    current_version=$(get_conf_snell_version "$conf_file")
    port=$(grep -E '^listen' "$conf_file" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
    if [ -z "$port" ]; then
        echo -e "${RED}无法从 ${conf_file} 解析监听端口${RESET}"
        return 1
    fi

    if [ "$current_version" = "$target_version" ]; then
        echo -e "${YELLOW}端口 ${port} 已经在 ${target_version} 通道，无需切换${RESET}"
        return 0
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
    point_service_unit_to_version "$unit" "$target_version"
    systemctl daemon-reload 2>/dev/null || true
    if [ "$service" = "snell" ]; then
        update_snell_symlink "$target_version"
    fi

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

# 逐个检查已安装通道是否有新版本
update_installed_channels() {
    local installed
    installed=$(list_installed_snell_versions)
    if [ -z "$installed" ]; then
        echo -e "${RED}未检测到已安装的通道${RESET}"
        return 1
    fi

    local version current latest updated=0
    for version in $installed; do
        current=$(get_channel_binary_version "$version")
        latest=$(resolve_latest_version_for_channel "$version")
        echo -e "\n${CYAN}--- ${version} 通道 ---${RESET}"
        echo -e "${YELLOW}当前: ${current:-未知}   最新: ${latest:-未知}${RESET}"

        if [ -z "$latest" ]; then
            echo -e "${YELLOW}无法获取最新版本，跳过${RESET}"
            continue
        fi
        if [ -n "$current" ] && version_greater_equal "$current" "$latest"; then
            echo -e "${GREEN}已是最新${RESET}"
            continue
        fi

        echo -e "${CYAN}发现新版本，是否更新 ${version} 通道? [y/N]${RESET}"
        read -r choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            update_snell_channel "$version" && updated=$((updated + 1))
        else
            echo -e "${CYAN}已跳过 ${version}${RESET}"
        fi
    done

    echo -e "\n${GREEN}检查完成，本次更新了 ${updated} 个通道${RESET}"
}

# 安装一个新通道，只落盘二进制，不改动任何现有用户
install_extra_channel() {
    local installed missing version
    installed=" $(list_installed_snell_versions) "
    missing=""
    for version in $SNELL_ALL_VERSIONS; do
        case "$installed" in
            *" ${version} "*) ;;
            *) missing="${missing}${version} " ;;
        esac
    done
    missing="${missing% }"

    if [ -z "$missing" ]; then
        echo -e "${GREEN}v4 / v5 / v6 三个通道都已安装${RESET}"
        return 0
    fi

    echo -e "\n${YELLOW}尚未安装的通道：${missing}${RESET}"
    echo -e "${CYAN}装好后可在「多用户管理」里给具体端口选用，或用本菜单的「切换通道」${RESET}"
    local idx=1
    local options=()
    for version in $missing; do
        echo -e "${GREEN}${idx}.${RESET} 安装 Snell ${version}"
        options+=("$version")
        idx=$((idx + 1))
    done
    echo -e "${GREEN}0.${RESET} 返回"

    read -rp "请输入选项 [0-$((idx - 1))]: " pick
    if [ "$pick" = "0" ] || [ -z "$pick" ]; then
        return 0
    fi
    if ! [[ "$pick" =~ ^[0-9]+$ ]] || [ "$pick" -lt 1 ] || [ "$pick" -gt "${#options[@]}" ]; then
        echo -e "${RED}无效选项${RESET}"
        return 1
    fi

    local target="${options[$((pick - 1))]}"
    if install_snell_binary_for_version "$target" "true"; then
        echo -e "${GREEN}✓ Snell ${target} 已就绪，现有服务未受任何影响${RESET}"
    else
        return 1
    fi
}

# 切换某个用户（含主用户）所使用的通道
switch_user_channel() {
    local conf_file port version
    local confs=()
    local labels=()

    if [ -f "$SNELL_CONF_FILE" ]; then
        port=$(grep -E '^listen' "$SNELL_CONF_FILE" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
        version=$(get_conf_snell_version "$SNELL_CONF_FILE")
        confs+=("$SNELL_CONF_FILE")
        labels+=("主用户 (端口 ${port}) 当前: ${version}")
    fi

    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for conf_file in "${SNELL_CONF_DIR}/users"/snell-*.conf; do
            [ -f "$conf_file" ] || continue
            case "$conf_file" in
                *snell-main.conf) continue ;;
            esac
            port=$(grep -E '^listen' "$conf_file" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
            [ -n "$port" ] || continue
            version=$(get_conf_snell_version "$conf_file")
            confs+=("$conf_file")
            labels+=("用户 (端口 ${port}) 当前: ${version}")
        done
    fi

    if [ "${#confs[@]}" -eq 0 ]; then
        echo -e "${RED}没有可切换的用户${RESET}"
        return 1
    fi

    echo -e "\n${YELLOW}=== 选择要切换通道的用户 ===${RESET}"
    local idx=1
    for label in "${labels[@]}"; do
        echo -e "${GREEN}${idx}.${RESET} ${label}"
        idx=$((idx + 1))
    done
    echo -e "${GREEN}0.${RESET} 返回"

    read -rp "请输入选项 [0-$((idx - 1))]: " pick
    if [ "$pick" = "0" ] || [ -z "$pick" ]; then
        return 0
    fi
    if ! [[ "$pick" =~ ^[0-9]+$ ]] || [ "$pick" -lt 1 ] || [ "$pick" -gt "${#confs[@]}" ]; then
        echo -e "${RED}无效选项${RESET}"
        return 1
    fi

    local selected="${confs[$((pick - 1))]}"
    local current
    current=$(get_conf_snell_version "$selected")

    echo -e "\n${YELLOW}=== 选择目标通道（当前 ${current}）===${RESET}"
    echo -e "${GREEN}1.${RESET} Snell v4"
    echo -e "${GREEN}2.${RESET} Snell v5"
    echo -e "${GREEN}3.${RESET} Snell v6 (RC)"
    echo -e "${GREEN}0.${RESET} 返回"
    read -rp "请输入选项 [0-3]: " target_pick

    local target=""
    case "$target_pick" in
        1) target="v4" ;;
        2) target="v5" ;;
        3)
            target="v6"
            echo -e "${YELLOW}注意：v6 仍为预发布版本，已移除 QUIC 代理模式与 obfs${RESET}"
            ;;
        0|"") return 0 ;;
        *) echo -e "${RED}无效选项${RESET}"; return 1 ;;
    esac

    switch_conf_to_version "$selected" "$target"
}

# Snell 版本管理入口（原「更新 Snell」）
check_snell_update() {
    echo -e "\n${CYAN}=============== Snell 版本管理 ===============${RESET}"

    # 老的单版本布局先迁移，否则下面按通道展示会看不到东西
    migrate_snell_binary_layout

    local installed
    installed=$(list_installed_snell_versions)
    if [ -z "$installed" ]; then
        echo -e "${RED}未检测到任何已安装的 Snell 通道，请先执行安装。${RESET}"
        return 1
    fi

    echo -e "${YELLOW}已安装通道：${RESET}"
    local version svc_count svc_list
    for version in $installed; do
        svc_list=$(list_services_using_version "$version")
        svc_count=$(echo "$svc_list" | grep -c .)
        echo -e "  ${GREEN}${version}${RESET}  版本: $(get_channel_binary_version "$version")  使用中: ${svc_count} 个服务"
    done

    echo -e "\n${GREEN}1.${RESET} 检查并更新已安装通道"
    echo -e "${GREEN}2.${RESET} 安装一个新通道（只下载二进制，不影响现有用户）"
    echo -e "${GREEN}3.${RESET} 切换某个用户使用的通道"
    echo -e "${GREEN}0.${RESET} 返回"

    read -rp "请输入选项 [0-3]: " manage_choice
    case "$manage_choice" in
        1) update_installed_channels ;;
        2) install_extra_channel ;;
        3) switch_user_channel ;;
        0|"") echo -e "${CYAN}已返回${RESET}" ;;
        *) echo -e "${RED}请输入正确的选项 [0-3]${RESET}" ;;
    esac
}

# 更新脚本
update_script() {
    echo -e "${CYAN}正在检查脚本更新...${RESET}"
    
    # 创建临时文件
    local TMP_SCRIPT
    TMP_SCRIPT=$(mktemp)

    # 下载最新版本（带完整性校验）
    if fetch_verified_script "$SNELL_SCRIPT_URL" "$TMP_SCRIPT"; then
        # 获取新版本号
        new_version=$(grep -m1 -E '^current_version="' "$TMP_SCRIPT" | cut -d'"' -f2)

        # 版本号格式必须合法，防止下载到错误内容后误更新
        if ! [[ "$new_version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
            echo -e "${RED}下载的脚本版本号格式异常，已中止更新${RESET}"
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

# 初始检查
initial_check() {
    check_root
    # bc：状态里的 CPU / 内存合计
    ensure_cmds curl bc || exit 1
    check_and_migrate_config
    # 旧的单版本布局迁到按通道分开存；已经是新布局时什么都不做
    if [ -e "${INSTALL_DIR}/snell-server" ]; then
        migrate_snell_binary_layout
    fi
    sync_existing_main_service_unit
    upgrade_management_script
    check_and_show_status
}

# 运行初始检查
initial_check

# 下载子脚本到临时文件，校验通过后再执行
run_remote_script() {   # <url> <名称>
    local tmp_script
    tmp_script=$(mktemp) || return 1
    if fetch_verified_script "$1" "$tmp_script"; then
        bash "$tmp_script"
    else
        echo -e "${RED}${2}下载校验失败，已取消执行。${RESET}"
    fi
    rm -f "$tmp_script"
}

# 多用户管理
setup_multi_user() {
    echo -e "${CYAN}正在执行多用户管理脚本...${RESET}"
    run_remote_script "${SNELL_RAW_BASE}/scripts/multi-user.sh" "多用户管理脚本"

    # 多用户管理脚本执行完毕后会自动返回这里
    echo -e "${GREEN}多用户管理操作完成${RESET}"
    sleep 1  # 给用户一点时间看到提示
}

# 两栏菜单的一行：_menu_row "1." "安装 Snell" 9 "7." "多用户管理"
# $3 为左栏补空格数（标签固定，空格数已按中文 2 列宽度算好，左栏总宽 24）
_menu_row() {
    echo -e "${GREEN}  $1${RESET} $2$(printf '%*s' "$3" "")${GREEN}$4${RESET} $5"
}

# 主菜单
show_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}    Snell 管理脚本 v${current_version} (v4/v5/v6 可共存)${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}作者: jinqian${RESET}"
    echo -e "${GREEN}网站：https://jinqians.com${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    

    # 显示服务状态
    check_and_show_status

    echo -e "${CYAN}--------------------------------------------${RESET}"
    _menu_row "1." "安装 Snell" 9 "7." "多用户管理"
    _menu_row "2." "卸载 Snell" 9 "8." "版本管理（更新 / 追加通道 / 切换通道）"
    _menu_row "3." "查看配置" 11 "9." "更新脚本"
    _menu_row "4." "重启服务" 11 "10." "查看服务状态"
    _menu_row "5." "ShadowTLS 管理" 5 "11." "Snell v5/v6 出口控制设置"
    _menu_row "6." "BBR 管理" 11 "12." "规则分流（sing-box：广告 / 大陆 / AI / 流媒体… 走不同出口）"
    echo -e "${GREEN}  0.${RESET} 退出脚本"
    echo -e "${CYAN}--------------------------------------------${RESET}"
    if ! read -rp "请输入选项 [0-12]: " num; then
        echo
        echo -e "${YELLOW}未读取到输入，已退出 Snell 菜单。${RESET}"
        exit 0
    fi
}

#开启bbr
setup_bbr() {
    echo -e "${CYAN}正在获取并执行 BBR 管理脚本...${RESET}"

    # 下载到本地校验通过后再执行
    run_remote_script "${SNELL_RAW_BASE}/scripts/bbr.sh" "BBR 脚本"

    # BBR 脚本执行完毕后会自动返回这里
    echo -e "${GREEN}BBR 管理操作完成${RESET}"
    sleep 1  # 给用户一点时间看到提示
}

# ShadowTLS管理
setup_shadowtls() {
    echo -e "${CYAN}正在执行 ShadowTLS 管理脚本...${RESET}"
    run_remote_script "${SNELL_RAW_BASE}/scripts/shadowtls.sh" "ShadowTLS 脚本"

    # ShadowTLS 脚本执行完毕后会自动返回这里
    echo -e "${GREEN}ShadowTLS 管理操作完成${RESET}"
    sleep 1  # 给用户一点时间看到提示
}

# 主循环
while true; do
    show_menu
    case "$num" in
        1)
            install_snell
            ;;
        2)
            uninstall_snell
            ;;
        3)
            view_snell_config
            ;;
        4)
            restart_snell
            ;;
        5)
            setup_shadowtls
            ;;
        6)
            setup_bbr
            ;;
        7)
            setup_multi_user
            ;;
        8)
            check_snell_update
            ;;
        9)
            update_script
            ;;
        10)
            check_and_show_status
            read -p "按任意键继续..." || exit 0
            ;;
        11)
            configure_v5_egress_control
            read -p "按任意键继续..." || exit 0
            ;;
        12)
            router_menu
            ;;
        0)
            echo -e "${GREEN}感谢使用，再见！${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}请输入正确的选项 [0-12]${RESET}"
            ;;
    esac
    echo -e "\n${CYAN}按任意键返回主菜单...${RESET}"
    read -n 1 -s -r || exit 0
done
