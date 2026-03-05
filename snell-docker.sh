#!/bin/sh
# =========================================
# 作者: jinqians (Docker版)
# 创建日期: 2026年3月5日
# 描述: 使用 Docker 在 Alpine | Debian | CentOS…… Linux 上安装和管理 Snell 代理
#       避免宿主机兼容性问题，支持 Snell v4/v5
# =========================================

# --- 定义颜色代码 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
RESET='\033[0m'

# --- 脚本版本号 ---
current_version="1.0"

# --- 全局变量 ---
SNELL_VERSION_CHOICE=""
SNELL_VERSION=""
CONTAINER_NAME="snell-server"
IMAGE_NAME="my-snell"

# --- 基础函数 ---

check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}错误: 请以 root 权限运行此脚本。${RESET}"
        exit 1
    fi
}

check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${YELLOW}未检测到 Docker，是否自动安装？${RESET}"
        printf "输入 y 安装，其他键退出: "
        read -r install_docker
        if [ "$install_docker" != "y" ] && [ "$install_docker" != "Y" ]; then
            echo -e "${RED}取消安装。${RESET}"
            exit 1
        fi
        
        echo -e "${CYAN}正在安装 Docker...${RESET}"
        if [ -f /etc/alpine-release ]; then
            apk add --no-cache docker docker-cli-compose
            rc-update add docker boot
            rc-service docker start
        else
            curl -fsSL https://get.docker.com | sh
            systemctl enable docker
            systemctl start docker
        fi
        
        if ! command -v docker >/dev/null 2>&1; then
            echo -e "${RED}Docker 安装失败，请手动安装。${RESET}"
            exit 1
        fi
        echo -e "${GREEN}✓ Docker 安装成功${RESET}"
    fi
    
    if ! docker info >/dev/null 2>&1; then
        echo -e "${YELLOW}Docker 服务未运行，正在尝试启动...${RESET}"
        if [ -f /etc/alpine-release ]; then
            rc-service docker start
        else
            systemctl start docker
        fi
        sleep 2
        if ! docker info >/dev/null 2>&1; then
            echo -e "${RED}Docker 服务启动失败，请手动启动。${RESET}"
            exit 1
        fi
    fi
    
    echo -e "${GREEN}✓ Docker 环境检查通过${RESET}"
}

# --- 版本选择与获取 ---

select_snell_version() {
    echo -e "${CYAN}请选择要安装的 Snell 版本：${RESET}"
    echo -e "${GREEN}1.${RESET} Snell v4"
    echo -e "${GREEN}2.${RESET} Snell v5"
    
    while true; do
        printf "请输入选项 [1-2]: "
        read -r version_choice
        case "$version_choice" in
            1) SNELL_VERSION_CHOICE="v4"; echo -e "${GREEN}已选择 Snell v4${RESET}"; break ;;
            2) SNELL_VERSION_CHOICE="v5"; echo -e "${GREEN}已选择 Snell v5${RESET}"; break ;;
            *) echo -e "${RED}请输入正确的选项 [1-2]${RESET}" ;;
        esac
    done
}

get_latest_snell_v4_version() {
    latest_version=$(curl -s https://manual.nssurge.com/others/snell.html | grep -o 'snell-server-v4\.[0-9]\+\.[0-9]\+' | head -n 1 | sed 's/snell-server-v//')
    if [ -n "$latest_version" ]; then echo "v${latest_version}"; else echo "v4.0.1"; fi
}

get_latest_snell_v5_version() {
    v5_beta=$(curl -s https://manual.nssurge.com/others/snell.html | grep -o 'snell-server-v5\.[0-9]\+\.[0-9]\+b[0-9]\+' | head -n 1 | sed 's/snell-server-v//')
    if [ -z "$v5_beta" ]; then
        v5_beta=$(curl -s https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell | grep -o 'snell-server-v5\.[0-9]\+\.[0-9]\+b[0-9]\+' | head -n 1 | sed 's/snell-server-v//')
    fi
    if [ -n "$v5_beta" ]; then echo "v${v5_beta}"; return; fi
    v5_release=$(curl -s https://manual.nssurge.com/others/snell.html | grep -o 'snell-server-v5\.[0-9]\+\.[0-9]\+[a-z0-9]*' | grep -v b | head -n 1 | sed 's/snell-server-v//')
    if [ -z "$v5_release" ]; then
        v5_release=$(curl -s https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell | grep -o 'snell-server-v5\.[0-9]\+\.[0-9]\+[a-z0-9]*' | grep -v b | head -n 1 | sed 's/snell-server-v//')
    fi
    if [ -n "$v5_release" ]; then echo "v${v5_release}"; else echo "v5.0.0"; fi
}

get_latest_snell_version() {
    if [ "$SNELL_VERSION_CHOICE" = "v5" ]; then 
        SNELL_VERSION=$(get_latest_snell_v5_version)
    else 
        SNELL_VERSION=$(get_latest_snell_v4_version)
    fi
    echo -e "${GREEN}获取到版本: ${SNELL_VERSION}${RESET}"
}

get_snell_download_url() {
    local arch=$(uname -m)
    local arch_suffix=""
    case ${arch} in
        "x86_64"|"amd64") arch_suffix="amd64" ;;
        "aarch64"|"arm64") arch_suffix="aarch64" ;;
        "armv7l"|"armv7") arch_suffix="armv7l" ;;
        *) echo -e "${RED}不支持的架构: ${arch}${RESET}"; exit 1 ;;
    esac
    echo "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-${arch_suffix}.zip"
}

# --- 端口和配置 ---

get_user_port() {
    while true; do
        printf "请输入要使用的端口号 (1-65535), 回车默认 [随机]: "
        read -r PORT
        if [ -z "$PORT" ]; then 
            PORT=$(shuf -i 20000-65000 -n 1)
            echo -e "${YELLOW}使用随机端口: $PORT${RESET}"
            break
        fi
        case "$PORT" in 
            ''|*[!0-9]*) 
                echo -e "${RED}无效输入，请输入纯数字。${RESET}"
                continue
                ;;
        esac
        if [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then 
            echo -e "${GREEN}已选择端口: $PORT${RESET}"
            break
        else 
            echo -e "${RED}无效端口号，请输入 1 到 65535 之间的数字。${RESET}"
        fi
    done
}

# --- Docker 相关函数 ---

create_dockerfile() {
    local snell_url=$(get_snell_download_url)
    local arch=$(uname -m)
    local gnu_lib_dir=""
    local ld_linker_cmd=""

    case ${arch} in
        "x86_64"|"amd64")
            gnu_lib_dir="x86_64-linux-gnu"
            ld_linker_cmd="mkdir -p /lib64 && ln -sf /usr/glibc-compat/lib/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2"
            ;;
        "aarch64"|"arm64")
            gnu_lib_dir="aarch64-linux-gnu"
            ld_linker_cmd="ln -sf /usr/glibc-compat/lib/ld-linux-aarch64.so.1 /lib/ld-linux-aarch64.so.1"
            ;;
        "armv7l"|"armv7")
            gnu_lib_dir="arm-linux-gnueabihf"
            ld_linker_cmd="ln -sf /usr/glibc-compat/lib/ld-linux-armhf.so.3 /lib/ld-linux-armhf.so.3"
            ;;
    esac

    echo -e "${CYAN}创建 Dockerfile (多阶段构建: Debian提取glibc + Alpine运行)...${RESET}"

    cat > Dockerfile << EOF
# 第一阶段: 使用 Debian 下载二进制并提供 glibc 运行时库
FROM debian:bookworm-slim AS builder
RUN apt-get update && apt-get install -y --no-install-recommends curl unzip ca-certificates && \\
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
RUN curl -L -o snell.zip "${snell_url}" && \\
    unzip -o snell.zip && \\
    rm -f snell.zip && \\
    chmod +x /app/snell-server

# 第二阶段: Alpine 最终镜像，注入 glibc 运行时
FROM alpine:3.19
RUN apk add --no-cache ca-certificates
WORKDIR /app
COPY --from=builder /app/snell-server /app/snell-server
COPY --from=builder /lib/${gnu_lib_dir}/ /usr/glibc-compat/lib/
RUN ${ld_linker_cmd}
ENV LD_LIBRARY_PATH=/usr/glibc-compat/lib
RUN mkdir -p /etc/snell
COPY snell-config/snell-server.conf /etc/snell/snell-server.conf
EXPOSE ${PORT}
CMD exec /app/snell-server -c /etc/snell/snell-server.conf
EOF

    echo -e "${GREEN}✓ Dockerfile 创建完成${RESET}"
}

create_config_file() {
    local psk=$(openssl rand -base64 16)
    
    echo -e "${CYAN}创建 Snell 配置文件...${RESET}"
    
    # 创建临时配置目录
    mkdir -p ./snell-config
    # 同时创建持久配置目录
    mkdir -p /etc/snell-docker
    
    # 根据版本创建不同的配置文件格式
    if [ "$SNELL_VERSION_CHOICE" = "v5" ]; then
        cat > ./snell-config/snell-server.conf << EOF
[snell-server]
listen = 0.0.0.0:${PORT}
psk = ${psk}
EOF
    else
        cat > ./snell-config/snell-server.conf << EOF
[snell-server]
listen = 0.0.0.0:${PORT}
psk = ${psk}
ipv6 = true
tfo = true
EOF
    fi

    # 复制到持久位置
    cp ./snell-config/snell-server.conf /etc/snell-docker/

    echo -e "${GREEN}✓ 配置文件创建完成${RESET}"
    echo -e "${GREEN}✓ 配置文件已保存到持久位置${RESET}"
    echo -e "${YELLOW}端口: ${PORT}${RESET}"
    echo -e "${YELLOW}PSK: ${psk}${RESET}"
    
    # 保存配置信息到变量
    SNELL_PORT="$PORT"
    SNELL_PSK="$psk"
}

build_docker_image() {
    echo -e "${CYAN}构建 Docker 镜像...${RESET}"
    
    if docker build -t "${IMAGE_NAME}:${SNELL_VERSION}" -t "${IMAGE_NAME}:latest" .; then
        echo -e "${GREEN}✓ Docker 镜像构建成功${RESET}"
    else
        echo -e "${RED}✗ Docker 镜像构建失败${RESET}"
        return 1
    fi
}

start_snell_container() {
    echo -e "${CYAN}启动 Snell 容器...${RESET}"
    
    # 停止并删除可能存在的旧容器
    docker stop "${CONTAINER_NAME}" 2>/dev/null || true
    docker rm "${CONTAINER_NAME}" 2>/dev/null || true
    
    # 第一步：不带 --restart 先测试启动，避免崩溃循环
    echo -e "${CYAN}测试启动容器...${RESET}"
    local run_output
    run_output=$(docker run -d \
        --name "${CONTAINER_NAME}" \
        -p "${SNELL_PORT}:${SNELL_PORT}" \
        "${IMAGE_NAME}:latest" 2>&1)
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}✗ 容器创建失败${RESET}"
        echo "   $run_output"
        return 1
    fi
    
    echo -e "${GREEN}✓ 容器已创建${RESET}"
    
    # 等待启动
    echo -e "${CYAN}等待服务启动...${RESET}"
    sleep 5
    
    # 检查容器是否在运行
    local container_status=$(docker inspect --format='{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null)
    local exit_code=$(docker inspect --format='{{.State.ExitCode}}' "${CONTAINER_NAME}" 2>/dev/null)
    
    if [ "$container_status" = "running" ]; then
        # 再等几秒确认稳定性
        sleep 3
        container_status=$(docker inspect --format='{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null)
    fi
    
    if [ "$container_status" != "running" ]; then
        echo -e "${RED}✗ 容器启动失败，状态: $container_status，退出码: $exit_code${RESET}"
        echo -e "${CYAN}容器日志:${RESET}"
        docker logs "${CONTAINER_NAME}" 2>&1 | sed 's/^/   /'
        
        if [ "$exit_code" = "127" ]; then
            echo -e "${RED}退出码 127 = 程序或命令找不到${RESET}"
            echo -e "${YELLOW}检查镜像内容...${RESET}"
            # 使用 sh 启动一个临时容器检查镜像内容
            docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
            echo -e "${CYAN}镜像内 /app 目录:${RESET}"
            docker run --rm "${IMAGE_NAME}:latest" sh -c "ls -la /app/ 2>&1" 2>&1 | sed 's/^/   /'
            echo -e "${CYAN}镜像内 /etc/snell 目录:${RESET}"
            docker run --rm "${IMAGE_NAME}:latest" sh -c "ls -la /etc/snell/ 2>&1" 2>&1 | sed 's/^/   /'
            echo -e "${CYAN}二进制文件信息:${RESET}"
            docker run --rm "${IMAGE_NAME}:latest" sh -c "file /app/snell-server 2>&1" 2>&1 | sed 's/^/   /'
            echo -e "${CYAN}手动执行测试:${RESET}"
            docker run --rm "${IMAGE_NAME}:latest" sh -c "/app/snell-server -c /etc/snell/snell-server.conf" 2>&1 | head -5 | sed 's/^/   /'
        fi
        
        docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
        return 1
    fi
    
    echo -e "${GREEN}✓ 容器运行正常${RESET}"
    
    # 检查端口映射
    local port_mapping=$(docker port "${CONTAINER_NAME}" 2>/dev/null)
    if [ -n "$port_mapping" ]; then
        echo -e "${GREEN}✓ 端口映射: $port_mapping${RESET}"
    fi
    
    # 显示容器日志
    echo -e "${CYAN}容器日志:${RESET}"
    docker logs "${CONTAINER_NAME}" 2>&1 | tail -5 | sed 's/^/   /'
    
    # 测试成功，现在重建并启用自动重启
    echo -e "${CYAN}启用自动重启策略...${RESET}"
    docker update --restart unless-stopped "${CONTAINER_NAME}" 2>/dev/null || true
    
    echo -e "${GREEN}✓ Snell 容器启动成功${RESET}"
    return 0
}

# --- 安装函数 ---

install_snell() {
    check_root
    check_docker
    
    # 检查是否已有容器运行
    if docker ps -a | grep -q "${CONTAINER_NAME}"; then
        echo -e "${YELLOW}检测到已存在的 Snell 容器，是否要重新安装？${RESET}"
        printf "输入 y 继续，其他键取消: "
        read -r confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            return
        fi
        uninstall_snell
    fi
    
    select_snell_version
    get_latest_snell_version
    get_user_port
    
    # 创建临时工作目录
    WORK_DIR="/tmp/snell-docker-$(date +%s)"
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    
    echo -e "${CYAN}开始 Docker 方式安装 Snell ${SNELL_VERSION}...${RESET}"
    
    # 创建配置文件
    create_config_file
    
    # 创建 Dockerfile
    create_dockerfile
    
    # 构建镜像
    if ! build_docker_image; then
        echo -e "${RED}安装失败！${RESET}"
        cd - >/dev/null
        rm -rf "$WORK_DIR"
        return 1
    fi
    
    # 启动容器
    if ! start_snell_container; then
        echo -e "${RED}安装失败！${RESET}"
        cd - >/dev/null
        rm -rf "$WORK_DIR"
        return 1
    fi
    
    # 清理临时文件
    cd - >/dev/null
    rm -rf "$WORK_DIR"
    
    echo -e "${GREEN}🎉 Snell Server 安装完成！${RESET}"
    
    # 配置防火墙
    configure_firewall
    
    # 显示配置信息
    show_information
}

# --- 管理函数 ---

uninstall_snell() {
    check_root
    
    echo -e "${CYAN}正在卸载 Snell Docker 容器...${RESET}"
    
    # 停止并删除容器
    if docker stop "${CONTAINER_NAME}" 2>/dev/null; then
        echo -e "${GREEN}✓ 容器已停止${RESET}"
    fi
    
    if docker rm "${CONTAINER_NAME}" 2>/dev/null; then
        echo -e "${GREEN}✓ 容器已删除${RESET}"
    fi
    
    # 询问是否删除镜像
    printf "是否同时删除 Docker 镜像？[y/N]: "
    read -r remove_image
    if [ "$remove_image" = "y" ] || [ "$remove_image" = "Y" ]; then
        docker rmi "${IMAGE_NAME}:latest" 2>/dev/null || true
        docker rmi $(docker images "${IMAGE_NAME}" -q) 2>/dev/null || true
        echo -e "${GREEN}✓ Docker 镜像已删除${RESET}"
    fi
    
    # 清理配置文件
    if [ -d "/etc/snell-docker" ]; then
        rm -rf /etc/snell-docker
        echo -e "${GREEN}✓ 配置文件已删除${RESET}"
    fi
    
    # 清理防火墙规则（如果能找到端口信息）
    if [ -f "/tmp/snell_port" ]; then
        old_port=$(cat /tmp/snell_port)
        iptables -D INPUT -p tcp --dport "$old_port" -j ACCEPT 2>/dev/null || true
        ufw delete allow "$old_port" 2>/dev/null || true
        rm -f /tmp/snell_port
    fi
    
    echo -e "${GREEN}🗑️  Snell 已完全卸载${RESET}"
}

restart_snell() {
    check_root
    
    if ! docker ps -a | grep -q "${CONTAINER_NAME}"; then
        echo -e "${RED}错误: Snell 容器不存在${RESET}"
        return 1
    fi
    
    echo -e "${CYAN}正在重启 Snell 容器...${RESET}"
    
    if docker restart "${CONTAINER_NAME}"; then
        sleep 2
        if docker ps | grep -q "${CONTAINER_NAME}"; then
            echo -e "${GREEN}✓ Snell 容器重启成功${RESET}"
        else
            echo -e "${RED}✗ 容器重启后异常${RESET}"
            echo -e "${YELLOW}查看日志: docker logs ${CONTAINER_NAME}${RESET}"
        fi
    else
        echo -e "${RED}✗ 容器重启失败${RESET}"
    fi
}

check_status() {
    echo -e "${CYAN}=== Snell Docker 容器状态 ===${RESET}"
    
    if docker ps -a | grep -q "${CONTAINER_NAME}"; then
        echo -e "\n${CYAN}容器信息:${RESET}"
        docker ps -a --filter "name=${CONTAINER_NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        
        echo -e "\n${CYAN}资源使用情况:${RESET}"
        docker stats "${CONTAINER_NAME}" --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}"
        
        echo -e "\n${CYAN}容器日志 (最后10行):${RESET}"
        docker logs --tail 10 "${CONTAINER_NAME}"
    else
        echo -e "${RED}Snell 容器不存在${RESET}"
    fi
}

# 网络连接诊断
network_diagnosis() {
    echo -e "${CYAN}🔍 开始 Snell 网络连接诊断...${RESET}"
    echo -e "${CYAN}===========================================${RESET}"
    
    # 检查配置文件是否存在
    if [ ! -f "/etc/snell-docker/snell-server.conf" ]; then
        echo -e "${RED}❌ 配置文件不存在，请先安装 Snell${RESET}"
        return 1
    fi
    
    # 读取配置
    local port=$(grep 'listen' /etc/snell-docker/snell-server.conf | sed 's/.*://')
    local psk=$(grep 'psk' /etc/snell-docker/snell-server.conf | sed 's/psk\s*=\s*//')
    local version_choice="v4"
    if docker images "${IMAGE_NAME}" --format '{{.Tag}}' 2>/dev/null | grep -q 'v5'; then
        version_choice="v5"
    fi
    
    echo -e "${YELLOW}📋 服务配置信息:${RESET}"
    echo "   端口: $port"
    echo "   版本: $version_choice"
    echo "   PSK: ${psk:0:10}..."
    echo ""
    
    # 1. 检查容器状态
    echo -e "${CYAN}1️⃣  检查容器状态...${RESET}"
    if docker ps | grep -q "${CONTAINER_NAME}"; then
        echo -e "   ${GREEN}✅ 容器正在运行${RESET}"
        local container_ports=$(docker port "${CONTAINER_NAME}")
        echo "   端口映射: $container_ports"
    else
        echo -e "   ${RED}❌ 容器未运行${RESET}"
        if docker ps -a | grep -q "${CONTAINER_NAME}"; then
            echo -e "   ${YELLOW}⚠️  容器存在但已停止，尝试启动...${RESET}"
            docker start "${CONTAINER_NAME}"
            sleep 2
        else
            echo -e "   ${RED}❌ 容器不存在，请重新安装${RESET}"
            return 1
        fi
    fi
    echo ""
    
    # 2. 检查 Docker 端口映射
    echo -e "${CYAN}2️⃣  检查 Docker 端口映射...${RESET}"
    local port_mapping=$(docker port "${CONTAINER_NAME}" 2>/dev/null)
    if [ -n "$port_mapping" ]; then
        echo -e "   ${GREEN}✅ Docker 端口映射存在${RESET}"
        echo "   $port_mapping" | sed 's/^/   /'
        
        # 检查宿主机端口是否在监听
        if netstat -tlnp 2>/dev/null | grep ":$port " | grep -q LISTEN; then
            echo -e "   ${GREEN}✅ 宿主机端口 $port 正在监听${RESET}"
            netstat -tlnp 2>/dev/null | grep ":$port " | head -1 | sed 's/^/   /'
        else
            echo -e "   ${RED}❌ 宿主机端口 $port 未在监听${RESET}"
        fi
    else
        echo -e "   ${RED}❌ Docker 端口映射不存在或异常${RESET}"
        echo -e "   ${YELLOW}检查容器详细状态...${RESET}"
        
        # 详细检查容器状态
        local container_status=$(docker ps -a --filter "name=${CONTAINER_NAME}" --format "{{.Status}}" 2>/dev/null)
        echo "   容器状态: $container_status"
        
        # 检查镜像是否存在
        if ! docker images | grep -q "${IMAGE_NAME}"; then
            echo -e "   ${RED}❌ Docker 镜像不存在，需要重新安装${RESET}"
            echo -e "   ${YELLOW}请选择主菜单选项 1 重新安装 Snell${RESET}"
            return 1
        fi
        
        echo -e "   ${YELLOW}尝试重建容器...${RESET}"
        
        # 停止并删除容器
        docker stop "${CONTAINER_NAME}" 2>/dev/null || true
        docker rm "${CONTAINER_NAME}" 2>/dev/null || true
        
        # 重新启动容器（配置已内置于镜像，无需挂载）
        echo -e "   ${CYAN}重新创建容器...${RESET}"
        if docker run -d \
            --name "${CONTAINER_NAME}" \
            --restart unless-stopped \
            -p "${port}:${port}" \
            "${IMAGE_NAME}:latest" 2>/dev/null; then
            echo -e "   ${GREEN}✅ 容器已重新创建${RESET}"
            sleep 5
            
            # 验证新容器
            local new_restarting=$(docker inspect --format='{{.State.Restarting}}' "${CONTAINER_NAME}" 2>/dev/null)
            if [ "$new_restarting" = "true" ]; then
                echo -e "   ${RED}❌ 容器仍在重启，建议选项1重新安装${RESET}"
                docker logs --tail 5 "${CONTAINER_NAME}" 2>&1 | sed 's/^/   /'
            else
                local new_port_mapping=$(docker port "${CONTAINER_NAME}" 2>/dev/null)
                if [ -n "$new_port_mapping" ]; then
                    echo -e "   ${GREEN}✅ 端口映射已修复: $new_port_mapping${RESET}"
                else
                    echo -e "   ${RED}❌ 端口映射仍有问题${RESET}"
                fi
            fi
        else
            echo -e "   ${RED}❌ 容器重新创建失败${RESET}"
            echo -e "   ${YELLOW}可能是镜像问题，建议重新安装${RESET}"
        fi
    fi
    echo ""
    
    # 3. 检查防火墙规则
    echo -e "${CYAN}3️⃣  检查防火墙规则...${RESET}"
    if command -v iptables >/dev/null 2>&1; then
        if iptables -L INPUT -n | grep -q "dpt:$port"; then
            echo -e "   ${GREEN}✅ iptables 规则存在${RESET}"
            iptables -L INPUT -n | grep "dpt:$port" | head -1 | sed 's/^/   /'
        else
            echo -e "   ${RED}❌ iptables 规则不存在${RESET}"
            echo -e "   ${YELLOW}尝试添加规则...${RESET}"
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null && \
            echo -e "   ${GREEN}✅ iptables 规则已添加${RESET}" || \
            echo -e "   ${RED}❌ 添加 iptables 规则失败${RESET}"
        fi
    else
        echo -e "   ${YELLOW}⚠️  iptables 不可用${RESET}"
    fi
    
    if command -v ufw >/dev/null 2>&1; then
        if ufw status | grep -q "$port"; then
            echo -e "   ${GREEN}✅ UFW 规则存在${RESET}"
        else
            echo -e "   ${YELLOW}⚠️  UFW 规则可能不存在${RESET}"
        fi
    fi
    echo ""
    
    # 4. 外部端口连通性测试
    echo -e "${CYAN}4️⃣  测试外部端口连通性...${RESET}"
    local server_ip=$(curl -s4 --connect-timeout 5 https://api.ipify.org 2>/dev/null)
    if [ -n "$server_ip" ]; then
        echo "   服务器 IP: $server_ip"
        
        # 使用多种方法测试端口
        echo -e "   ${CYAN}测试端口 $port...${RESET}"
        
        # 方法1: 使用 nc (netcat)
        if command -v nc >/dev/null 2>&1; then
            if timeout 5 nc -z "$server_ip" "$port" 2>/dev/null; then
                echo -e "   ${GREEN}✅ nc 测试通过${RESET}"
            else
                echo -e "   ${RED}❌ nc 测试失败${RESET}"
            fi
        fi
        
        # 方法2: 使用 telnet
        if command -v telnet >/dev/null 2>&1; then
            if timeout 5 sh -c "echo '' | telnet $server_ip $port" 2>/dev/null | grep -q Connected; then
                echo -e "   ${GREEN}✅ telnet 测试通过${RESET}"
            else
                echo -e "   ${RED}❌ telnet 测试失败${RESET}"
            fi
        fi
        
        # 方法3: 使用在线端口检测
        echo -e "   ${YELLOW}💡 在线端口检测工具:${RESET}"
        echo "   https://www.yougetsignal.com/tools/open-ports/"
        echo "   https://tool.chinaz.com/port/"
        echo "   输入 IP: $server_ip, 端口: $port"
    else
        echo -e "   ${RED}❌ 无法获取服务器 IP${RESET}"
    fi
    echo ""
    
    # 5. 容器内部详细检查
    echo -e "${CYAN}5️⃣  容器内部详细检查...${RESET}"
    if docker ps | grep -q "${CONTAINER_NAME}"; then
        # 检查容器内部端口
        echo -e "   ${CYAN}检查容器内部端口监听...${RESET}"
        local container_netstat=$(docker exec "${CONTAINER_NAME}" netstat -tln 2>/dev/null | grep ":$port " || echo "")
        if [ -n "$container_netstat" ]; then
            echo -e "   ${GREEN}✅ 容器内端口正常监听${RESET}"
            echo "   $container_netstat" | sed 's/^/   /'
        else
            echo -e "   ${RED}❌ 容器内端口未监听${RESET}"
        fi
        
        # 检查 Snell 进程
        echo -e "   ${CYAN}检查 Snell 进程状态...${RESET}"
        local snell_process=$(docker exec "${CONTAINER_NAME}" ps aux 2>/dev/null | grep -v grep | grep snell || echo "")
        if [ -n "$snell_process" ]; then
            echo -e "   ${GREEN}✅ Snell 进程正在运行${RESET}"
            echo "$snell_process" | sed 's/^/   /'
            
            # 检查进程状态是否正常
            if echo "$snell_process" | grep -q "\[snell-server\]"; then
                echo -e "   ${RED}⚠️  检测到僵尸进程格式，Snell 可能未正常启动${RESET}"
                echo -e "   ${YELLOW}尝试重新启动 Snell 服务...${RESET}"
                
                # 杀死可能的僵尸进程
                docker exec "${CONTAINER_NAME}" pkill -f snell 2>/dev/null || true
                sleep 1
                
                # 重新启动 Snell
                echo -e "   ${CYAN}重新启动 Snell 服务...${RESET}"
                if docker exec -d "${CONTAINER_NAME}" sh -c "cd /app && exec ./snell-server -c /etc/snell/snell-server.conf" 2>/dev/null; then
                    sleep 3
                    local new_snell_process=$(docker exec "${CONTAINER_NAME}" ps aux 2>/dev/null | grep -v grep | grep snell || echo "")
                    if [ -n "$new_snell_process" ]; then
                        echo -e "   ${GREEN}✓ Snell 服务重启成功${RESET}"
                        echo "$new_snell_process" | sed 's/^/   RESTART: /'
                    else
                        echo -e "   ${RED}✗ Snell 服务重启失败${RESET}"
                    fi
                else
                    echo -e "   ${RED}✗ 重启命令执行失败${RESET}"
                fi
            fi
        else
            echo -e "   ${RED}❌ Snell 进程未运行${RESET}"
        fi
        
        # 检查配置文件
        echo -e "   ${CYAN}检查配置文件...${RESET}"
        local ls_result=$(docker exec "${CONTAINER_NAME}" ls -la /etc/snell/ 2>/dev/null || echo "")
        if [ -n "$ls_result" ]; then
            echo -e "   ${GREEN}✅ 配置目录存在${RESET}"
            echo "$ls_result" | sed 's/^/   /'
            
            # 检查配置文件内容
            local config_content=$(docker exec "${CONTAINER_NAME}" cat /etc/snell/snell-server.conf 2>/dev/null || echo "")
            if [ -n "$config_content" ]; then
                echo -e "   ${GREEN}✅ 配置文件存在且有内容${RESET}"
                echo "$config_content" | sed 's/^/   /'
            else
                echo -e "   ${RED}❌ 配置文件不存在或为空${RESET}"
                echo -e "   ${YELLOW}配置文件应内置于镜像中，建议选项1重新安装${RESET}"
            fi
        else
            echo -e "   ${RED}❌ 配置目录不存在${RESET}"
            echo -e "   ${YELLOW}这表明容器挂载有严重问题${RESET}"
        fi
        
        # 检查 Snell 二进制文件
        echo -e "   ${CYAN}检查 Snell 二进制文件...${RESET}"
        local snell_binary=$(docker exec "${CONTAINER_NAME}" ls -la /app/snell-server 2>/dev/null || echo "")
        if [ -n "$snell_binary" ]; then
            echo -e "   ${GREEN}✅ Snell 二进制文件存在${RESET}"
            echo "$snell_binary" | sed 's/^/   /'
            
            # 尝试手动运行测试
            echo -e "   ${CYAN}测试 Snell 二进制文件...${RESET}"
            local snell_test=$(docker exec "${CONTAINER_NAME}" timeout 3s /app/snell-server --help 2>&1 || echo "")
            if echo "$snell_test" | grep -q "usage\|help\|version"; then
                echo -e "   ${GREEN}✅ Snell 二进制文件可执行${RESET}"
            else
                echo -e "   ${RED}❌ Snell 二进制文件可能有问题${RESET}"
                echo "$snell_test" | sed 's/^/   /' | head -3
                
                # 检查二进制文件完整性
                echo -e "   ${CYAN}检查二进制文件完整性...${RESET}"
                local file_info=$(docker exec "${CONTAINER_NAME}" file /app/snell-server 2>/dev/null || echo "")
                echo "   文件信息: $file_info"
                
                local file_size=$(docker exec "${CONTAINER_NAME}" stat -c%s /app/snell-server 2>/dev/null || echo "0")
                echo "   文件大小: $file_size bytes"
                
                if [ "$file_size" -lt 100000 ]; then
                    echo -e "   ${RED}❌ binary文件大小异常，可能下载不完整${RESET}"
                fi
            fi
        else
            echo -e "   ${RED}❌ Snell 二进制文件不存在${RESET}"
            echo -e "   ${YELLOW}这表明 Docker 镜像构建失败${RESET}"
            echo -e "   ${YELLOW}需要重新安装以重建镜像${RESET}"
        fi
        
        # 检查完整的容器日志
        echo -e "   ${CYAN}检查完整容器日志...${RESET}"
        local full_logs=$(docker logs --tail 50 "${CONTAINER_NAME}" 2>&1)
        if [ -n "$full_logs" ]; then
            echo -e "   ${YELLOW}最近日志 (最后10行):${RESET}"
            echo "$full_logs" | tail -10 | sed 's/^/   /'
            
            # 检查特定错误
            local error_logs=$(echo "$full_logs" | grep -i "error\|failed\|refused\|cannot\|permission\|bind" || echo "")
            if [ -n "$error_logs" ]; then
                echo -e "   ${RED}发现错误日志:${RESET}"
                echo "$error_logs" | sed 's/^/   /'
            fi
        else
            echo -e "   ${YELLOW}无日志输出${RESET}"
        fi
        
        # 尝试修复
        local needs_fix=false
        if [ -z "$snell_process" ]; then
            needs_fix=true
        elif [ -z "$container_netstat" ]; then
            needs_fix=true
        fi
        
        if [ "$needs_fix" = "true" ]; then
            echo -e "   ${YELLOW}尝试修复容器...${RESET}"
            echo -e "   ${CYAN}重启容器中的 Snell 服务...${RESET}"
            
            # 清理可能的僵尸进程
            docker exec "${CONTAINER_NAME}" pkill -f snell 2>/dev/null || true
            docker exec "${CONTAINER_NAME}" pkill -f "sleep" 2>/dev/null || true
            sleep 2
            
            # 方法1: 尝试直接启动 
            echo -e "   ${CYAN}尝试直接启动 Snell 服务...${RESET}"
            if docker exec -d "${CONTAINER_NAME}" sh -c "cd /app && exec ./snell-server -c /etc/snell/snell-server.conf" 2>/dev/null; then
                sleep 5
                
                # 检查是否启动成功
                local fixed_process=$(docker exec "${CONTAINER_NAME}" ps aux 2>/dev/null | grep -v grep | grep snell || echo "")
                local fixed_netstat=$(docker exec "${CONTAINER_NAME}" netstat -tln 2>/dev/null | grep ":$port " || echo "")
                
                if [ -n "$fixed_process" ] && [ -n "$fixed_netstat" ]; then
                    echo -e "   ${GREEN}✅ Snell 服务修复成功${RESET}"
                    echo "$fixed_process" | sed 's/^/   FIX: /'
                    echo "$fixed_netstat" | sed 's/^/   PORT: /'
                elif [ -n "$fixed_process" ]; then
                    echo -e "   ${YELLOW}⚠️  进程已启动但端口仍未监听${RESET}"
                    echo "$fixed_process" | sed 's/^/   FIX: /'
                else
                    echo -e "   ${RED}❌ 手动启动失败，建议重建容器${RESET}"
                    
                    # 显示启动错误信息
                    echo -e "   ${CYAN}检查启动错误...${RESET}"
                    local start_error=$(docker exec "${CONTAINER_NAME}" sh -c "cd /app && timeout 5s ./snell-server -c /etc/snell/snell-server.conf" 2>&1 || echo "")
                    if [ -n "$start_error" ]; then
                        echo "   启动错误: $start_error" | head -3
                    fi
                fi
            else
                echo -e "   ${RED}❌ 启动命令执行失败${RESET}"
            fi
        fi
    fi
    echo ""
    
    # 6. 生成客户端配置
    echo -e "${CYAN}6️⃣  客户端配置检查...${RESET}"
    if [ -n "$server_ip" ]; then
        echo -e "   ${GREEN}Surge 配置:${RESET}"
        if [ "$version_choice" = "v5" ]; then
            echo "   MySnell_v4 = snell, $server_ip, $port, psk=$psk, version=4, reuse=true, tfo=true"
            echo "   MySnell_v5 = snell, $server_ip, $port, psk=$psk, version=5, reuse=true, tfo=true"
        else
            echo "   MySnell = snell, $server_ip, $port, psk=$psk, version=4, reuse=true, tfo=true"
        fi
        echo ""
        echo -e "   ${YELLOW}确保客户端配置与上述配置完全一致${RESET}"
    fi
    echo ""
    
    # 7. 自动修复建议和操作
    echo -e "${CYAN}🔧 自动修复选项:${RESET}"
    echo -e "${YELLOW}检测到的问题:${RESET}"
    
    local issues_found=0
    local port_mapping=$(docker port "${CONTAINER_NAME}" 2>/dev/null)
    local snell_process=$(docker exec "${CONTAINER_NAME}" ps aux 2>/dev/null | grep -v grep | grep snell || echo "")
    local container_listening=$(docker exec "${CONTAINER_NAME}" netstat -tln 2>/dev/null | grep ":$port " || echo "")
    
    if [ -z "$port_mapping" ]; then
        echo "   • Docker 端口映射缺失"
        issues_found=$((issues_found + 1))
    fi
    
    if [ -z "$snell_process" ]; then
        echo "   • Snell 进程未运行"
        issues_found=$((issues_found + 1))
    elif echo "$snell_process" | grep -q "\[snell-server\]"; then
        echo "   • Snell 进程可能是僵尸进程"
        issues_found=$((issues_found + 1))
    fi
    
    if [ -z "$container_listening" ]; then
        echo "   • 容器内端口未监听"
        issues_found=$((issues_found + 1))
    fi
    
    if [ "$issues_found" -gt 0 ]; then
        echo ""
        echo -e "${CYAN}修复选项:${RESET}"
        echo -e "${YELLOW}1. 快速修复 (重启容器):${RESET}"
        echo "   docker restart ${CONTAINER_NAME}"
        echo ""
        echo -e "${YELLOW}2. 重建容器 (推荐):${RESET}"
        echo "   选择脚本主菜单的选项 1 重新安装"
        echo ""
        echo -e "${YELLOW}3. 手动修复命令:${RESET}"
        echo "   # 停止当前容器"
        echo "   docker stop ${CONTAINER_NAME}"
        echo "   docker rm ${CONTAINER_NAME}"
        echo ""
        echo "   # 重新创建容器"
        echo "   docker run -d \\"
        echo "     --name ${CONTAINER_NAME} \\"
        echo "     --restart unless-stopped \\"
        echo "     -p ${port}:${port} \\"
        echo "     ${IMAGE_NAME}:latest"
        echo ""
        
        # 提供一键修复选项
        echo -e "${GREEN}是否要执行自动修复? [y/N]:${RESET}"
        printf "   "
        read -r fix_choice
        if [ "$fix_choice" = "y" ] || [ "$fix_choice" = "Y" ]; then
            echo -e "${CYAN}执行自动修复...${RESET}"
            
            # 停止并删除容器
            docker stop "${CONTAINER_NAME}" 2>/dev/null || true
            docker rm "${CONTAINER_NAME}" 2>/dev/null || true
            
            # 重新创建容器（配置已内置于镜像）
            if docker run -d \
                --name "${CONTAINER_NAME}" \
                --restart unless-stopped \
                -p "${port}:${port}" \
                "${IMAGE_NAME}:latest" 2>/dev/null; then
                echo -e "   ${GREEN}✅ 容器重建成功${RESET}"
                sleep 8  # 给更多时间启动
                
                # 验证修复结果
                echo -e "   ${CYAN}验证修复结果...${RESET}"
                if docker ps | grep -q "${CONTAINER_NAME}"; then
                    local new_port_mapping=$(docker port "${CONTAINER_NAME}" 2>/dev/null)
                    if [ -n "$new_port_mapping" ]; then
                        echo -e "   ${GREEN}✅ 端口映射已恢复: $new_port_mapping${RESET}"
                        
                        # 等待服务启动并检查
                        sleep 5
                        local new_snell_process=$(docker exec "${CONTAINER_NAME}" ps aux 2>/dev/null | grep -v grep | grep snell || echo "")
                        local new_port_listen=$(docker exec "${CONTAINER_NAME}" netstat -tln 2>/dev/null | grep ":$port " || echo "")
                        
                        if [ -n "$new_snell_process" ] && [ -n "$new_port_listen" ]; then
                            echo -e "   ${GREEN}✅ Snell 服务已启动并监听端口${RESET}"
                            echo "$new_snell_process" | sed 's/^/   PROCESS: /'
                            echo "$new_port_listen" | sed 's/^/   LISTEN: /'
                            echo -e "   ${GREEN}🎉 修复成功！请重新测试连接${RESET}"
                        elif [ -n "$new_snell_process" ]; then
                            echo -e "   ${YELLOW}⚠️  服务已启动但端口未监听${RESET}"
                            echo "$new_snell_process" | sed 's/^/   PROCESS: /'
                            echo -e "   ${YELLOW}可能需要等待更长时间或重新安装${RESET}"
                        else
                            echo -e "   ${YELLOW}⚠️  容器已启动，但 Snell 服务可能还在启动中...${RESET}"
                            echo -e "   ${YELLOW}请等待 10-20 秒后重新运行诊断${RESET}"
                        fi
                    else
                        echo -e "   ${RED}❌ 端口映射仍然有问题${RESET}"
                        echo -e "   ${YELLOW}请检查容器状态:${RESET}"
                        docker ps --filter "name=${CONTAINER_NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | sed 's/^/   /'
                    fi
                else
                    echo -e "   ${RED}❌ 容器启动失败${RESET}"
                    echo -e "   ${CYAN}容器启动日志:${RESET}"
                    docker logs --tail 10 "${CONTAINER_NAME}" 2>&1 | sed 's/^/   /'
                fi
            else
                echo -e "   ${RED}❌ 容器重建失败${RESET}"
                echo -e "   ${YELLOW}可能是镜像问题，建议选择选项1重新安装${RESET}"
            fi
        fi
    else
        echo "   ${GREEN}✅ 未发现明显问题${RESET}"
        echo "   ${YELLOW}如果仍无法连接，可能是 VPS 提供商防火墙限制${RESET}"
    fi
    echo ""
    
    echo -e "${CYAN}🔧 常见问题解决方案:${RESET}"
    echo -e "${CYAN}🔧 通用解决方案:${RESET}"
    echo -e "${YELLOW}1. VPS 提供商防火墙:${RESET}"
    echo "   ▸ 登录 VPS 控制面板，开放端口 $port"
    echo "   ▸ 阿里云/腾讯云等需要在安全组中开放端口"
    echo ""
    echo -e "${YELLOW}2. 网络运营商限制:${RESET}"
    echo "   ▸ 某些端口可能被运营商封禁"
    echo "   ▸ 尝试更换端口: docker stop snell-server && 重新安装"
    echo ""
    echo -e "${YELLOW}3. 容器重启:${RESET}"
    echo "   ▸ docker restart ${CONTAINER_NAME}"
    echo "   ▸ docker logs -f ${CONTAINER_NAME}"
    echo ""
    echo -e "${YELLOW}4. 重新开放端口:${RESET}"
    echo "   ▸ iptables -I INPUT -p tcp --dport $port -j ACCEPT"
    echo "   ▸ 检查 /etc/iptables/rules.v4 是否保存规则"
    echo ""
    echo -e "${CYAN}===========================================${RESET}"
    echo -e "${GREEN}✅ 诊断完成！${RESET}"
}

# --- 辅助函数 ---

configure_firewall() {
    echo -e "${CYAN}配置防火墙...${RESET}"
    
    # 保存端口信息供卸载时使用
    echo "$SNELL_PORT" > /tmp/snell_port
    
    # 尝试 iptables
    if command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport "$SNELL_PORT" -j ACCEPT 2>/dev/null || true
        # 尝试保存 iptables 规则
        if command -v iptables-save >/dev/null 2>&1; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
        echo -e "${GREEN}✓ iptables 规则已添加${RESET}"
    fi
    
    # 尝试 ufw（如果存在）
    if command -v ufw >/dev/null 2>&1; then
        ufw allow "$SNELL_PORT" >/dev/null 2>&1 || true
        echo -e "${GREEN}✓ ufw 规则已添加${RESET}"
    fi
    
    echo -e "${YELLOW}请确保您的 VPS 提供商防火墙也开放了端口 ${SNELL_PORT}${RESET}"
}

show_information() {
    if [ ! -f "/etc/snell-docker/snell-server.conf" ]; then
        echo -e "${RED}未找到配置文件。${RESET}"
        return
    fi
    
    local port=$(grep 'listen' /etc/snell-docker/snell-server.conf | sed 's/.*://')
    local psk=$(grep 'psk' /etc/snell-docker/snell-server.conf | sed 's/psk\s*=\s*//')
    # 通过镜像tag判断版本
    local version_choice="v4"
    if docker images "${IMAGE_NAME}" --format '{{.Tag}}' 2>/dev/null | grep -q 'v5'; then
        version_choice="v5"
    fi
    
    # 获取服务器 IP
    local ipv4_addr=$(curl -s4 --connect-timeout 5 https://api.ipify.org 2>/dev/null)
    local ipv6_addr=$(curl -s6 --connect-timeout 5 https://api64.ipify.org 2>/dev/null)
    
    clear
    echo -e "${BLUE}============================================${RESET}"
    echo -e "${GREEN}🐳 Snell Docker 配置信息:${RESET}"
    echo -e "${BLUE}============================================${RESET}"

    if [ -n "$ipv4_addr" ]; then
        local ip_country_ipv4=$(curl -s --connect-timeout 5 "http://ipinfo.io/${ipv4_addr}/country" 2>/dev/null)
        echo -e "${GREEN}--- IPv4 Surge 配置 (Snell ${version_choice}) ---${RESET}"
        if [ "$version_choice" = "v5" ]; then
            echo -e "${GREEN}${ip_country_ipv4}_v4 = snell, ${ipv4_addr}, ${port}, psk=${psk}, version=4, reuse=true, tfo=true${RESET}"
            echo -e "${GREEN}${ip_country_ipv4}_v5 = snell, ${ipv4_addr}, ${port}, psk=${psk}, version=5, reuse=true, tfo=true${RESET}"
        else
            echo -e "${GREEN}${ip_country_ipv4} = snell, ${ipv4_addr}, ${port}, psk=${psk}, version=4, reuse=true, tfo=true${RESET}"
        fi
    fi

    if [ -n "$ipv6_addr" ]; then
        local ip_country_ipv6=$(curl -s --connect-timeout 5 "https://ipapi.co/${ipv6_addr}/country/" 2>/dev/null)
        echo -e "\n${GREEN}--- IPv6 Surge 配置 (Snell ${version_choice}) ---${RESET}"
        if [ "$version_choice" = "v5" ]; then
            echo -e "${GREEN}${ip_country_ipv6}_v4 = snell, ${ipv6_addr}, ${port}, psk=${psk}, version=4, reuse=true, tfo=true${RESET}"
            echo -e "${GREEN}${ip_country_ipv6}_v5 = snell, ${ipv6_addr}, ${port}, psk=${psk}, version=5, reuse=true, tfo=true${RESET}"
        else
            echo -e "${GREEN}${ip_country_ipv6} = snell, ${ipv6_addr}, ${port}, psk=${psk}, version=4, reuse=true, tfo=true${RESET}"
        fi
    fi

    echo ""
    echo -e "${YELLOW}服务器端口: ${RESET}${port}"
    echo -e "${YELLOW}PSK 密钥: ${RESET}${psk}"
    echo -e "${YELLOW}容器名称: ${RESET}${CONTAINER_NAME}"
    echo -e "${YELLOW}镜像名称: ${RESET}${IMAGE_NAME}:latest"
    echo -e "\n${YELLOW}配置文件: ${RESET}/etc/snell-docker/snell-server.conf"
    echo -e "\n${CYAN}Docker 管理命令:${RESET}"
    echo -e "查看日志: ${YELLOW}docker logs ${CONTAINER_NAME}${RESET}"
    echo -e "进入容器: ${YELLOW}docker exec -it ${CONTAINER_NAME} sh${RESET}"
    echo -e "重启容器: ${YELLOW}docker restart ${CONTAINER_NAME}${RESET}"
    echo -e "${BLUE}============================================${RESET}"
}

# --- 主菜单 ---

show_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}   🐳 Snell Docker 管理脚本 v${current_version}${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    
    # 检查容器状态
    if docker ps -a 2>/dev/null | grep -q "${CONTAINER_NAME}"; then
        if docker ps 2>/dev/null | grep -q "${CONTAINER_NAME}"; then
            echo -e "服务状态: ${GREEN}运行中 🟢${RESET}"
        else
            echo -e "服务状态: ${RED}已停止 🔴${RESET}"
        fi
    else
        echo -e "服务状态: ${YELLOW}未安装 ⚪${RESET}"
    fi
    
    echo -e "${CYAN}--------------------------------------------${RESET}"
    echo -e "${GREEN}1.${RESET} 🚀 安装 Snell (Docker)"
    echo -e "${GREEN}2.${RESET} 🗑️  卸载 Snell"
    echo -e "${GREEN}3.${RESET} 🔄 重启服务"
    echo -e "${GREEN}4.${RESET} 📋 查看配置信息"
    echo -e "${GREEN}5.${RESET} 📊 查看详细状态"
    echo -e "${GREEN}6.${RESET} � 网络连接诊断"
    echo -e "${GREEN}7.${RESET} �🐳 Docker 常用命令"
    echo -e "${GREEN}0.${RESET} 🚪 退出脚本"
    echo -e "${CYAN}============================================${RESET}"
    printf "请输入选项 [0-7]: "
    read -r num
}

show_docker_commands() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}       🐳 Docker 常用管理命令${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}查看容器状态:${RESET}"
    echo "  docker ps -a --filter \"name=${CONTAINER_NAME}\""
    echo ""
    echo -e "${GREEN}查看实时日志:${RESET}"
    echo "  docker logs -f ${CONTAINER_NAME}"
    echo ""
    echo -e "${GREEN}进入容器shell:${RESET}"
    echo "  docker exec -it ${CONTAINER_NAME} sh"
    echo ""
    echo -e "${GREEN}容器资源监控:${RESET}"
    echo "  docker stats ${CONTAINER_NAME}"
    echo ""
    echo -e "${GREEN}手动重启容器:${RESET}"
    echo "  docker restart ${CONTAINER_NAME}"
    echo ""
    echo -e "${GREEN}手动停止/启动:${RESET}"
    echo "  docker stop ${CONTAINER_NAME}"
    echo "  docker start ${CONTAINER_NAME}"
    echo ""
    echo -e "${GREEN}查看镜像:${RESET}"
    echo "  docker images | grep ${IMAGE_NAME}"
    echo ""
    echo -e "${GREEN}容器端口映射:${RESET}"
    echo "  docker port ${CONTAINER_NAME}"
    echo -e "${CYAN}============================================${RESET}"
    printf "${CYAN}按任意键返回主菜单...${RESET}"
    read -r dummy
}

# --- 主程序 ---

main() {
    while true; do
        show_menu
        case "$num" in
            1) install_snell ;;
            2) uninstall_snell ;;
            3) restart_snell ;;
            4) show_information ;;
            5) check_status ;;
            6) network_diagnosis ;;
            7) show_docker_commands ;;
            0) echo -e "${GREEN}感谢使用，再见！🎉${RESET}"; exit 0 ;;
            *) echo -e "${RED}请输入正确的选项 [0-7]${RESET}";;
        esac
        if [ "$num" != "7" ]; then
            echo ""
            printf "${CYAN}按任意键返回主菜单...${RESET}"
            read -r dummy
        fi
    done
}

# 启动主程序
main
