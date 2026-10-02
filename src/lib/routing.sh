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
