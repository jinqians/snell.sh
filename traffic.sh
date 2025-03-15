#!/bin/bash
# =========================================
# 作者: jinqians
# 日期: 2024年3月
# 网站：jinqians.com
# 描述: 这个脚本用于管理服务流量监控
# =========================================

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 当前版本号
current_version="1.0"

# 流量相关配置
TRAFFIC_DIR="/etc/snell/traffic"
TRAFFIC_CONFIG="${TRAFFIC_DIR}/config.json"
TRAFFIC_DATA_DIR="${TRAFFIC_DIR}/data"
TRAFFIC_TRENDS_DIR="${TRAFFIC_DIR}/trends"
TRAFFIC_DAEMON_PID="/var/run/traffic-monitor.pid"
TRAFFIC_DAEMON_LOG="/var/log/traffic-monitor.log"

# 默认配置
DEFAULT_UPDATE_INTERVAL=300  # 5分钟
DEFAULT_RETENTION_DAYS=30    # 30天
DEFAULT_DAILY_THRESHOLD=10   # 10GB
DEFAULT_MONTHLY_THRESHOLD=100 # 100GB
DEFAULT_GROWTH_THRESHOLD=50  # 50%

# 检查是否以root权限运行
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请以root权限运行此脚本${RESET}"
        exit 1
    fi
}

# 检查并安装依赖
check_dependencies() {
    local deps=("jq" "bc" "nethogs")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo -e "${YELLOW}正在安装 ${dep}...${RESET}"
            if [ -x "$(command -v apt)" ]; then
                apt update && apt install -y "$dep"
            elif [ -x "$(command -v yum)" ]; then
                yum install -y "$dep"
            else
                echo -e "${RED}未支持的包管理器，请手动安装 ${dep}${RESET}"
                exit 1
            fi
        fi
    done
}

# 初始化配置
init_config() {
    mkdir -p "$TRAFFIC_DATA_DIR" "$TRAFFIC_TRENDS_DIR"
    
    if [ ! -f "$TRAFFIC_CONFIG" ]; then
        cat > "$TRAFFIC_CONFIG" << EOF
{
    "global": {
        "update_interval": $DEFAULT_UPDATE_INTERVAL,
        "retention_days": $DEFAULT_RETENTION_DAYS,
        "thresholds": {
            "daily": $DEFAULT_DAILY_THRESHOLD,
            "monthly": $DEFAULT_MONTHLY_THRESHOLD,
            "growth": $DEFAULT_GROWTH_THRESHOLD
        }
    },
    "services": {
        "snell": {
            "thresholds": {
                "daily": 5,
                "monthly": 50,
                "growth": 30
            },
            "actions": {
                "on_limit": "notify",
                "auto_restart": true
            }
        }
    },
    "notification": {
        "methods": {
            "syslog": true,
            "console": true,
            "telegram": false
        },
        "telegram": {
            "bot_token": "",
            "chat_id": ""
        }
    }
}
EOF
    fi
    
    chmod 755 "$TRAFFIC_DIR"
    chmod 644 "$TRAFFIC_CONFIG"
}

# 获取服务流量
get_service_traffic() {
    local service_name=$1
    local pid=$(systemctl show -p MainPID "$service_name" | cut -d'=' -f2)
    
    if [ -z "$pid" ] || [ "$pid" = "0" ]; then
        echo "0.00"
        return
    fi
    
    local rx_bytes=0
    local tx_bytes=0
    
    if command -v nethogs &> /dev/null; then
        local nethogs_data=$(timeout 1 nethogs -v 0 -t 2>/dev/null | grep "$pid")
        if [ ! -z "$nethogs_data" ]; then
            rx_bytes=$(echo "$nethogs_data" | awk '{sum += $2} END {print sum * 1024 * 1024}')
            tx_bytes=$(echo "$nethogs_data" | awk '{sum += $3} END {print sum * 1024 * 1024}')
        fi
    fi
    
    echo "scale=2; ($rx_bytes + $tx_bytes) / 1024 / 1024 / 1024" | bc
}

# 保存流量数据
save_traffic_data() {
    local service_name=$1
    local traffic=$2
    local timestamp=$(date +%s)
    local data_file="${TRAFFIC_DATA_DIR}/${service_name}.json"
    
    if [ ! -f "$data_file" ]; then
        echo '{"data":[]}' > "$data_file"
    fi
    
    jq ".data += [{\"timestamp\":$timestamp,\"traffic\":$traffic}]" "$data_file" > "${data_file}.tmp"
    mv "${data_file}.tmp" "$data_file"
    
    # 清理旧数据
    local retention_days=$(jq -r '.global.retention_days' "$TRAFFIC_CONFIG")
    local cutoff=$((timestamp - 86400 * retention_days))
    jq ".data |= map(select(.timestamp >= $cutoff))" "$data_file" > "${data_file}.tmp"
    mv "${data_file}.tmp" "$data_file"
}

# 分析流量趋势
analyze_trends() {
    local service_name=$1
    local data_file="${TRAFFIC_DATA_DIR}/${service_name}.json"
    local trend_file="${TRAFFIC_TRENDS_DIR}/${service_name}.json"
    
    if [ ! -f "$data_file" ]; then
        return 1
    fi
    
    local now=$(date +%s)
    local day_ago=$((now - 86400))
    local week_ago=$((now - 86400 * 7))
    local month_ago=$((now - 86400 * 30))
    
    jq -c "{
        daily: {
            total: (.data | map(select(.timestamp >= $day_ago)) | map(.traffic) | add // 0),
            growth: (
                (.data | map(select(.timestamp >= $day_ago)) | map(.traffic) | add // 0) /
                (.data | map(select(.timestamp >= $((day_ago - 86400)))) | map(.traffic) | add // 1) * 100 - 100
            )
        },
        weekly: {
            total: (.data | map(select(.timestamp >= $week_ago)) | map(.traffic) | add // 0),
            growth: (
                (.data | map(select(.timestamp >= $week_ago)) | map(.traffic) | add // 0) /
                (.data | map(select(.timestamp >= $((week_ago - 86400 * 7)))) | map(.traffic) | add // 1) * 100 - 100
            )
        },
        monthly: {
            total: (.data | map(select(.timestamp >= $month_ago)) | map(.traffic) | add // 0),
            growth: (
                (.data | map(select(.timestamp >= $month_ago)) | map(.traffic) | add // 0) /
                (.data | map(select(.timestamp >= $((month_ago - 86400 * 30)))) | map(.traffic) | add // 1) * 100 - 100
            )
        }
    }" "$data_file" > "$trend_file"
}

# 发送通知
send_notification() {
    local service_name=$1
    local message=$2
    local config=$(cat "$TRAFFIC_CONFIG")
    
    # 系统日志
    if [ "$(echo "$config" | jq -r '.notification.methods.syslog')" = "true" ]; then
        logger -t "traffic-monitor" "$service_name: $message"
    fi
    
    # 控制台输出
    if [ "$(echo "$config" | jq -r '.notification.methods.console')" = "true" ]; then
        echo -e "${RED}$service_name: $message${RESET}" >&2
    fi
    
    # Telegram通知
    if [ "$(echo "$config" | jq -r '.notification.methods.telegram')" = "true" ]; then
        local bot_token=$(echo "$config" | jq -r '.notification.telegram.bot_token')
        local chat_id=$(echo "$config" | jq -r '.notification.telegram.chat_id')
        if [ ! -z "$bot_token" ] && [ ! -z "$chat_id" ]; then
            curl -s "https://api.telegram.org/bot${bot_token}/sendMessage" \
                -d "chat_id=${chat_id}" \
                -d "text=🚨 流量警告\n\n服务：${service_name}\n消息：${message}" \
                -d "parse_mode=HTML" >/dev/null
        fi
    fi
}

# 检查流量阈值
check_thresholds() {
    local service_name=$1
    local trend_file="${TRAFFIC_TRENDS_DIR}/${service_name}.json"
    
    if [ ! -f "$trend_file" ]; then
        return
    fi
    
    local trends=$(cat "$trend_file")
    local config=$(cat "$TRAFFIC_CONFIG")
    
    # 检查服务特定阈值
    if jq -e ".services.\"$service_name\"" "$config" >/dev/null; then
        local daily_threshold=$(jq -r ".services.\"$service_name\".thresholds.daily" "$config")
        local monthly_threshold=$(jq -r ".services.\"$service_name\".thresholds.monthly" "$config")
        local growth_threshold=$(jq -r ".services.\"$service_name\".thresholds.growth" "$config")
        
        local daily_traffic=$(echo "$trends" | jq -r '.daily.total')
        local monthly_traffic=$(echo "$trends" | jq -r '.monthly.total')
        local daily_growth=$(echo "$trends" | jq -r '.daily.growth')
        
        if (( $(echo "$daily_traffic > $daily_threshold" | bc -l) )); then
            send_notification "$service_name" "日流量 ($daily_traffic GB) 超过阈值 ($daily_threshold GB)"
            handle_limit_action "$service_name"
        fi
        
        if (( $(echo "$monthly_traffic > $monthly_threshold" | bc -l) )); then
            send_notification "$service_name" "月流量 ($monthly_traffic GB) 超过阈值 ($monthly_threshold GB)"
            handle_limit_action "$service_name"
        fi
        
        if (( $(echo "$daily_growth > $growth_threshold" | bc -l) )); then
            send_notification "$service_name" "日增长率 ($daily_growth%) 超过阈值 ($growth_threshold%)"
        fi
    fi
}

# 处理超限动作
handle_limit_action() {
    local service_name=$1
    local action=$(jq -r ".services.\"$service_name\".actions.on_limit" "$TRAFFIC_CONFIG")
    
    if [ "$action" = "stop" ]; then
        systemctl stop "$service_name"
        send_notification "$service_name" "服务已停止"
    fi
}

# 启动守护进程
start_daemon() {
    if [ -f "$TRAFFIC_DAEMON_PID" ]; then
        if kill -0 $(cat "$TRAFFIC_DAEMON_PID") 2>/dev/null; then
            echo -e "${YELLOW}流量监控守护进程已在运行${RESET}"
            return
        fi
    fi
    
    nohup bash -c '
        while true; do
            for service in $(systemctl list-units --type=service --all --no-legend | grep -E "snell|ss-rust|shadowtls-" | awk "{print \$1}"); do
                traffic=$(get_service_traffic "$service")
                save_traffic_data "$service" "$traffic"
                analyze_trends "$service"
                check_thresholds "$service"
            done
            sleep $(jq -r ".global.update_interval" "'$TRAFFIC_CONFIG'")
        done
    ' > "$TRAFFIC_DAEMON_LOG" 2>&1 &
    
    echo $! > "$TRAFFIC_DAEMON_PID"
    echo -e "${GREEN}流量监控守护进程已启动${RESET}"
}

# 停止守护进程
stop_daemon() {
    if [ -f "$TRAFFIC_DAEMON_PID" ]; then
        kill $(cat "$TRAFFIC_DAEMON_PID") 2>/dev/null
        rm -f "$TRAFFIC_DAEMON_PID"
        echo -e "${GREEN}流量监控守护进程已停止${RESET}"
    else
        echo -e "${YELLOW}流量监控守护进程未在运行${RESET}"
    fi
}

# 显示流量统计
show_traffic_stats() {
    local service_name=$1
    local trend_file="${TRAFFIC_TRENDS_DIR}/${service_name}.json"
    
    if [ ! -f "$trend_file" ]; then
        echo -e "${YELLOW}没有找到 $service_name 的流量统计数据${RESET}"
        return
    fi
    
    local trends=$(cat "$trend_file")
    
    echo -e "\n${CYAN}=== $service_name 流量统计 ===${RESET}"
    echo -e "${YELLOW}日流量：$(echo "$trends" | jq -r '.daily.total') GB${RESET}"
    echo -e "${YELLOW}周流量：$(echo "$trends" | jq -r '.weekly.total') GB${RESET}"
    echo -e "${YELLOW}月流量：$(echo "$trends" | jq -r '.monthly.total') GB${RESET}"
    
    echo -e "\n${CYAN}增长趋势：${RESET}"
    echo -e "${YELLOW}日增长率：$(echo "$trends" | jq -r '.daily.growth')%${RESET}"
    echo -e "${YELLOW}周增长率：$(echo "$trends" | jq -r '.weekly.growth')%${RESET}"
    echo -e "${YELLOW}月增长率：$(echo "$trends" | jq -r '.monthly.growth')%${RESET}"
}

# 配置管理
manage_config() {
    while true; do
        echo -e "\n${CYAN}=== 配置管理 ===${RESET}"
        echo "1. 修改全局阈值"
        echo "2. 修改服务阈值"
        echo "3. 配置通知方式"
        echo "4. 返回主菜单"
        
        read -rp "请选择操作 [1-4]: " choice
        case "$choice" in
            1)
                echo -e "\n${CYAN}=== 全局阈值设置 ===${RESET}"
                read -rp "日流量阈值(GB) [当前：$(jq -r '.global.thresholds.daily' "$TRAFFIC_CONFIG")]: " daily
                read -rp "月流量阈值(GB) [当前：$(jq -r '.global.thresholds.monthly' "$TRAFFIC_CONFIG")]: " monthly
                read -rp "增长率阈值(%) [当前：$(jq -r '.global.thresholds.growth' "$TRAFFIC_CONFIG")]: " growth
                
                [ ! -z "$daily" ] && jq ".global.thresholds.daily = $daily" "$TRAFFIC_CONFIG" > "${TRAFFIC_CONFIG}.tmp"
                [ ! -z "$monthly" ] && jq ".global.thresholds.monthly = $monthly" "${TRAFFIC_CONFIG}.tmp" > "${TRAFFIC_CONFIG}"
                [ ! -z "$growth" ] && jq ".global.thresholds.growth = $growth" "$TRAFFIC_CONFIG" > "${TRAFFIC_CONFIG}.tmp"
                mv "${TRAFFIC_CONFIG}.tmp" "$TRAFFIC_CONFIG"
                ;;
            2)
                echo -e "\n${CYAN}=== 服务阈值设置 ===${RESET}"
                echo "可用服务："
                jq -r '.services | keys[]' "$TRAFFIC_CONFIG" | nl
                read -rp "请选择服务编号: " service_num
                
                local service_name=$(jq -r ".services | keys[$((service_num-1))]" "$TRAFFIC_CONFIG")
                if [ ! -z "$service_name" ]; then
                    read -rp "日流量阈值(GB) [当前：$(jq -r ".services.\"$service_name\".thresholds.daily" "$TRAFFIC_CONFIG")]: " daily
                    read -rp "月流量阈值(GB) [当前：$(jq -r ".services.\"$service_name\".thresholds.monthly" "$TRAFFIC_CONFIG")]: " monthly
                    read -rp "增长率阈值(%) [当前：$(jq -r ".services.\"$service_name\".thresholds.growth" "$TRAFFIC_CONFIG")]: " growth
                    
                    [ ! -z "$daily" ] && jq ".services.\"$service_name\".thresholds.daily = $daily" "$TRAFFIC_CONFIG" > "${TRAFFIC_CONFIG}.tmp"
                    [ ! -z "$monthly" ] && jq ".services.\"$service_name\".thresholds.monthly = $monthly" "${TRAFFIC_CONFIG}.tmp" > "${TRAFFIC_CONFIG}"
                    [ ! -z "$growth" ] && jq ".services.\"$service_name\".thresholds.growth = $growth" "$TRAFFIC_CONFIG" > "${TRAFFIC_CONFIG}.tmp"
                    mv "${TRAFFIC_CONFIG}.tmp" "$TRAFFIC_CONFIG"
                fi
                ;;
            3)
                echo -e "\n${CYAN}=== 通知配置 ===${RESET}"
                echo "1. 系统日志 [$(jq -r '.notification.methods.syslog' "$TRAFFIC_CONFIG")]"
                echo "2. 控制台输出 [$(jq -r '.notification.methods.console' "$TRAFFIC_CONFIG")]"
                echo "3. Telegram通知 [$(jq -r '.notification.methods.telegram' "$TRAFFIC_CONFIG")]"
                read -rp "请选择要修改的通知方式 [1-3]: " notify_choice
                
                case "$notify_choice" in
                    1)
                        toggle_notification "syslog"
                        ;;
                    2)
                        toggle_notification "console"
                        ;;
                    3)
                        toggle_notification "telegram"
                        if [ "$(jq -r '.notification.methods.telegram' "$TRAFFIC_CONFIG")" = "true" ]; then
                            read -rp "请输入Bot Token: " bot_token
                            read -rp "请输入Chat ID: " chat_id
                            jq ".notification.telegram.bot_token = \"$bot_token\" | .notification.telegram.chat_id = \"$chat_id\"" "$TRAFFIC_CONFIG" > "${TRAFFIC_CONFIG}.tmp"
                            mv "${TRAFFIC_CONFIG}.tmp" "$TRAFFIC_CONFIG"
                        fi
                        ;;
                esac
                ;;
            4)
                break
                ;;
            *)
                echo -e "${RED}无效的选项${RESET}"
                ;;
        esac
    done
}

# 切换通知状态
toggle_notification() {
    local method=$1
    local current_state=$(jq -r ".notification.methods.$method" "$TRAFFIC_CONFIG")
    local new_state=$([ "$current_state" = "true" ] && echo "false" || echo "true")
    jq ".notification.methods.$method = $new_state" "$TRAFFIC_CONFIG" > "${TRAFFIC_CONFIG}.tmp"
    mv "${TRAFFIC_CONFIG}.tmp" "$TRAFFIC_CONFIG"
    echo -e "${GREEN}${method}通知已$([ "$new_state" = "true" ] && echo "启用" || echo "禁用")${RESET}"
}

# 主菜单
show_menu() {
    while true; do
        clear
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${CYAN}          流量监控管理 v${current_version}${RESET}"
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${GREEN}作者: jinqian${RESET}"
        echo -e "${GREEN}网站：https://jinqians.com${RESET}"
        echo -e "${CYAN}============================================${RESET}"
        
        echo -e "\n${YELLOW}=== 监控管理 ===${RESET}"
        echo "1. 启动流量监控"
        echo "2. 停止流量监控"
        echo "3. 查看监控状态"
        
        echo -e "\n${YELLOW}=== 流量统计 ===${RESET}"
        echo "4. 查看流量统计"
        echo "5. 重置流量统计"
        
        echo -e "\n${YELLOW}=== 系统设置 ===${RESET}"
        echo "6. 配置管理"
        echo "7. 测试通知"
        echo "0. 退出"
        
        read -rp "请选择操作 [0-7]: " choice
        case "$choice" in
            1)
                start_daemon
                ;;
            2)
                stop_daemon
                ;;
            3)
                if [ -f "$TRAFFIC_DAEMON_PID" ]; then
                    local pid=$(cat "$TRAFFIC_DAEMON_PID")
                    if kill -0 "$pid" 2>/dev/null; then
                        echo -e "${GREEN}流量监控正在运行 (PID: $pid)${RESET}"
                        echo -e "\n最近的日志:"
                        tail -n 10 "$TRAFFIC_DAEMON_LOG"
                    else
                        echo -e "${RED}流量监控未运行${RESET}"
                    fi
                else
                    echo -e "${RED}流量监控未运行${RESET}"
                fi
                ;;
            4)
                echo -e "\n${CYAN}=== 流量统计 ===${RESET}"
                for service in $(systemctl list-units --type=service --all --no-legend | grep -E "snell|ss-rust|shadowtls-" | awk '{print $1}'); do
                    show_traffic_stats "$service"
                done
                ;;
            5)
                echo -e "\n${CYAN}=== 重置流量统计 ===${RESET}"
                echo "1. 重置所有服务"
                echo "2. 重置指定服务"
                read -rp "请选择操作 [1-2]: " reset_choice
                case "$reset_choice" in
                    1)
                        read -rp "确定要重置所有服务的流量统计？[y/N] " confirm
                        if [[ "$confirm" == [yY] ]]; then
                            rm -f "${TRAFFIC_DATA_DIR}"/*
                            rm -f "${TRAFFIC_TRENDS_DIR}"/*
                            echo -e "${GREEN}已重置所有服务的流量统计${RESET}"
                        fi
                        ;;
                    2)
                        echo "可用服务："
                        ls -1 "$TRAFFIC_DATA_DIR" | sed 's/\.json$//' | nl
                        read -rp "请选择服务编号: " service_num
                        local service_file=$(ls -1 "$TRAFFIC_DATA_DIR" | sed -n "${service_num}p")
                        if [ ! -z "$service_file" ]; then
                            rm -f "${TRAFFIC_DATA_DIR}/${service_file}"
                            rm -f "${TRAFFIC_TRENDS_DIR}/${service_file}"
                            echo -e "${GREEN}已重置 ${service_file%.json} 的流量统计${RESET}"
                        fi
                        ;;
                esac
                ;;
            6)
                manage_config
                ;;
            7)
                read -rp "请输入测试消息: " test_message
                send_notification "测试" "${test_message:-这是一条测试消息}"
                ;;
            0)
                echo -e "${GREEN}感谢使用，再见！${RESET}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效的选项${RESET}"
                ;;
        esac
        
        echo -e "\n按任意键继续..."
        read -n 1 -s -r
    done
}

# 主程序入口
main() {
    check_root
    check_dependencies
    init_config
    show_menu
}

main 
