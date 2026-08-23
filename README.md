[中文](README.md) ｜ [English](README.en.md)

# Snell 一键脚本与 Docker 镜像

支持 Snell v4 / v5 / v6、Snell 多用户、ShadowTLS v3、流量管理，以及 Docker / Docker Compose 部署。

## 脚本安装

### 自动识别系统安装

```bash
sh -c "$(curl -fsSL https://install.jinqians.com)"
```

### Debian / Ubuntu 多功能管理菜单

推荐 Debian / Ubuntu 用户优先使用管理菜单，可安装和管理 Snell、ShadowTLS、多用户、流量限制等功能。

```bash
bash <(curl -L -s menu.jinqians.com)
```

### 按系统选择脚本

| 系统 | 命令 | 说明 |
|------|------|------|
| Debian / Ubuntu | `bash <(curl -L -s snell.jinqians.com)` | Snell 主安装脚本 |
| CentOS | `bash <(curl -L -s snell-centos.jinqians.com)` | CentOS 版 Snell 安装脚本 |
| Alpine 本地构建 | `sh -c "$(curl -fsSL https://snell-docker.jinqians.com)"` | Alpine 本地构建安装 |
| Alpine 3.18 | `sh -c "$(curl -fsSL https://snell-alpine.jinqians.com)"` | Alpine 3.18 安装 |

### ShadowTLS 说明

在脚本中为 Snell 配置 ShadowTLS 后，脚本会把 Snell 后端改为仅监听 `127.0.0.1:Snell端口`，客户端只连接 ShadowTLS 对外端口。这样可以避免原始 Snell 端口继续暴露在公网。

## Docker 快速使用

Docker Hub 镜像：`jinqians/snell-server`

| 标签 | 版本 | 说明 |
|------|------|------|
| `latest` | Snell v5.0.1 | 固定指向 v5，不指向 v6 |
| `v4` | Snell v4.1.1 | v4 当前推荐版本 |
| `v5` | Snell v5.0.1 | v5 当前推荐版本 |
| `v6` | Snell v6.0.0rc2 | v6 当前 RC 版本 |
| `v4.0.0` / `v4.0.1` / `v4.1.0` / `v4.1.1` | Snell v4 | 固定版本标签 |
| `v5.0.0` / `v5.0.1` | Snell v5 | 固定版本标签 |
| `v6.0.0b1` … `v6.0.0b4` / `v6.0.0rc` / `v6.0.0rc2` | Snell v6 预发布 | 固定版本标签 |

架构支持：
- v4 / v5: `linux/amd64`、`linux/arm64`、`linux/arm/v7`
- v6: `linux/amd64`、`linux/arm64`

### 运行 Snell v5

```bash
docker run -d --name snell-server \
  --restart unless-stopped \
  -p 6160:6160/tcp \
  -p 6160:6160/udp \
  -e SNELL_PORT=6160 \
  -e SNELL_VER=v5 \
  -v ./snell-config:/etc/snell \
  jinqians/snell-server:v5
```

查看自动生成的 PSK：

```bash
cat ./snell-config/snell-server.conf
```

### 运行 Snell + ShadowTLS

```bash
docker run -d --name snell-shadowtls \
  --restart unless-stopped \
  -p 8443:8443/tcp \
  -e SNELL_PORT=6160 \
  -e SNELL_VER=v5 \
  -e SNELL_LISTEN_HOST=127.0.0.1 \
  -e SHADOWTLS_ENABLE=1 \
  -e SHADOWTLS_PORT=8443 \
  -e SHADOWTLS_SNI=www.microsoft.com \
  -v ./snell-config:/etc/snell \
  jinqians/snell-server:v5
```

启用 ShadowTLS 后，客户端连接 `8443`。Snell 后端只在容器内监听 `127.0.0.1:6160`，通常不需要映射 Snell 原始端口。

查看客户端需要的密钥：

```bash
grep '^psk' ./snell-config/snell-server.conf
cat ./snell-config/shadowtls-password
```

客户端填写：

| 项目 | 填写内容 |
|------|----------|
| 服务器 | VPS 公网 IP 或域名 |
| 端口 | ShadowTLS 对外端口，示例为 `8443` |
| Snell 版本 | `5` |
| Snell PSK | `./snell-config/snell-server.conf` 里的 `psk` |
| ShadowTLS 密码 | `./snell-config/shadowtls-password` 的内容，或手动传入的 `SHADOWTLS_PASSWORD` |
| ShadowTLS SNI | `SHADOWTLS_SNI`，默认 `www.microsoft.com` |
| ShadowTLS 版本 | `3` |

Surge 示例：

```text
HK = snell, 服务器IP, 8443, psk = your_16_plus_char_psk, version = 5, reuse = true, tfo = true, shadow-tls-password = your_shadowtls_password, shadow-tls-sni = www.microsoft.com, shadow-tls-version = 3
```

## Docker Compose

### Snell + ShadowTLS

创建 `compose.yml`：

```yaml
services:
  snell-shadowtls:
    image: jinqians/snell-server:v5
    container_name: snell-shadowtls
    restart: unless-stopped
    ports:
      - "8443:8443/tcp"
    environment:
      - SNELL_PORT=6160
      - SNELL_VER=v5
      - SNELL_LISTEN_HOST=127.0.0.1
      - SHADOWTLS_ENABLE=1
      - SHADOWTLS_PORT=8443
      - SHADOWTLS_SNI=www.microsoft.com
    volumes:
      - ./snell-config:/etc/snell
```

启动：

```bash
docker compose up -d
```

查看配置：

```bash
docker logs snell-shadowtls
cat ./snell-config/snell-server.conf
cat ./snell-config/shadowtls-password
```

停止并删除：

```bash
docker compose down
```

## Docker 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `SNELL_VER` | `v4` | Snell 配置模式：`v4`、`v5`、`v6` |
| `SNELL_PORT` | `6160` | Snell 后端监听端口 |
| `SNELL_PSK` | 自动生成 | Snell PSK |
| `SNELL_LISTEN_HOST` | `0.0.0.0` | Snell 监听地址；搭配 ShadowTLS 时使用 `127.0.0.1` |
| `SNELL_IPV6` | `true` | v4 配置项；v6 下会转换为 `dns-ip-preference`（`false` → `ipv4-only`） |
| `SNELL_TFO` | `true` | v4 配置项，v6 已不再使用 |
| `SNELL_MODE` | `default` | 仅 v6：加密模式 `default` / `unshaped` / `unsafe-raw`，客户端需一致 |
| `SNELL_DNS_IP_PREFERENCE` | 跟随 `SNELL_IPV6` | 仅 v6：`default` / `prefer-ipv4` / `prefer-ipv6` / `ipv4-only` / `ipv6-only` |
| `SNELL_DNS` | 未设置 | 仅 v6：自定义 DNS 服务器，多个用逗号分隔 |
| `SHADOWTLS_ENABLE` | `0` | 设置为 `1` 启用 ShadowTLS |
| `SHADOWTLS_PORT` | `8443` | ShadowTLS 对外监听端口 |
| `SHADOWTLS_PASSWORD` | 自动生成 | ShadowTLS 密码，会保存到 `/etc/snell/shadowtls-password` |
| `SHADOWTLS_SNI` | `www.microsoft.com` | ShadowTLS TLS 伪装 SNI |

## 切换 Docker 版本

切换版本时同时修改镜像标签和 `SNELL_VER`。

```bash
# v4
docker run -d --name snell-server \
  --restart unless-stopped \
  -p 6160:6160/tcp \
  -p 6160:6160/udp \
  -e SNELL_PORT=6160 \
  -e SNELL_VER=v4 \
  -v ./snell-config:/etc/snell \
  jinqians/snell-server:v4

# v6
docker run -d --name snell-server \
  --restart unless-stopped \
  -p 6160:6160/tcp \
  -p 6160:6160/udp \
  -e SNELL_PORT=6160 \
  -e SNELL_VER=v6 \
  -v ./snell-config:/etc/snell \
  jinqians/snell-server:v6
```

## 本地构建 Docker 镜像

```bash
./build-docker-images.sh
```

多架构构建并推送：

```bash
USE_BUILDX=1 PUSH=1 ./build-docker-images.sh
```

## 协议简介

<details>
   <summary>展开查看</summary>

### Snell 协议

Snell 协议是由 Surge 团队设计的一种轻量级、高效的加密代理协议，专注于提供安全、快速的网络传输服务。该协议通过简洁的设计和加密技术，满足用户对隐私保护和高性能传输的需求。

### Snell v4 / v5 / v6 对比

| 特性 | Snell v4 | Snell v5 | Snell v6 (RC) |
|------|----------|----------|---------------|
| 状态 | 稳定版 | 稳定版 | 预发布（rc2） |
| QUIC Proxy | 不支持 | 支持 | 已移除 |
| Dynamic Record Sizing | 不支持 | 支持 | 支持 |
| 出口控制 (egress-interface) | 不支持 | 支持 | 支持 |
| 部署级协议多样性 | 不支持 | 不支持 | 支持（PSK 派生） |
| 加密模式 mode | 不支持 | 不支持 | `default` / `unshaped` / `unsafe-raw` |
| obfs 混淆 | 支持 `http` | 支持 `http` | 已移除 |
| `ipv6` 参数 | 支持 | 支持 | 已废弃，改用 `dns-ip-preference` |
| 多地址监听 | 不支持 | 不支持 | 支持（`listen` 逗号分隔） |
| armv7l 构建 | 提供 | 提供 | 不提供 |

> v6 服务端与客户端的 `mode` 必须一致，Surge 侧配置示例：
> `节点名 = snell, 1.2.3.4, 6160, psk = xxx, version = 6, mode = default, reuse = true, tfo = true`

### ShadowTLS

ShadowTLS 是一个轻量级的 TLS 伪装工具，可以模拟正常 HTTPS 流量，用于提升连接隐蔽性和稳定性。

</details>

## 流量管理

<details>
   <summary>流量管理说明[展开查看]</summary>

### 功能说明
通过 iptables 对 Snell 节点进行流量计数，支持设置月度流量上限，超限后自动暂停节点，每月指定日期自动重置。

### 计量原理
Snell 以明文 TCP 监听在指定端口，流量管理通过在 iptables 中添加专用计数规则（`PSM_TRF` 链）统计该端口的进出字节数，不影响数据包的正常转发。超限时向 `INPUT` 链插入 DROP 规则，阻断新连接。

```
客户端 ──TCP──▶ iptables 计数 ──▶ snell-server
                     │
                   超限时 DROP
```

### 使用方式
在管理菜单中选择 **9. 流量管理**，进入交互向导：

```
1. 添加 / 修改流量限制   → 选择节点，设置上限 (GB) 和每月重置日
2. 查看流量状态         → 显示各节点已用流量、剩余、暂停状态
3. 手动暂停节点         → 立即阻断指定节点的新连接
4. 手动恢复节点         → 移除 DROP 规则，恢复正常访问
5. 重置流量统计         → 清零计数，并恢复被暂停的节点
```

### 自动检查定时器
首次配置后会提示安装 systemd 定时器（`psm-traffic.timer`），每分钟执行一次检查：
- 累计流量 ≥ 限额 → 自动暂停节点
- 到达重置日 → 清零计数并恢复节点

手动查看定时器状态：
```bash
systemctl status psm-traffic.timer
```

### 注意事项
- 流量计数基于 iptables 字节计数器，**服务器重启后计数器归零**，但已累计的流量数据保存在 `/etc/psm/traffic/state.json` 中，下次计数从断点续计
- 暂停节点仅阻断**新连接**，已建立的 TCP 连接会在自然断开后失效
- 若系统使用 nftables，需确认 iptables 兼容层已启用（`iptables-legacy` 或 `iptables-nft`）
- Snell 使用 TCP，流量计数不包含 UDP

</details>

## 🥇 赞助
+ [ZMTO](https://console.zmto.com/?affid=1567)
+ [ZMTO 测评](https://vps.jinqians.com/zmto/)

## 手搓snell
[点击跳转](https://vps.jinqians.com/snell-v4%e9%83%a8%e7%bd%b2%e6%95%99%e7%a8%8b/)

<details>
   <summary>surge配置文件[点击展开]</summary>
   
## Surge配置文件
自用配置文件：https://raw.githubusercontent.com/jinqians/snell.sh/refs/heads/main/surge.conf
### 配置文件说明
- Snell V4 配置示例
- Snell V5 配置示例
- Snell + ShadowTLS 配置示例
- VMESS 配置示例
- surge 订阅示例
</details>

<details>
   <summary>脚本输出示例[点击展开]</summary>
   
### Snell v4 配置
```
=== 配置信息 ===
当前安装版本: Snell v4
# 原始 Snell 配置
HK = snell, 1.2.3.4, 57891, psk = xxxxxxxxxxxx, version = 4, reuse = true, tfo = true
HK = snell, ::1, 57891, psk = xxxxxxxxxxxx, version = 4, reuse = true, tfo = true
```

### Snell v5 配置
```
=== 配置信息 ===
当前安装版本: Snell v5
# Snell v5 配置（支持 v4 和 v5 客户端）
HK = snell, 1.2.3.4, 57891, psk = xxxxxxxxxxxx, version = 4, reuse = true, tfo = true
HK = snell, 1.2.3.4, 57891, psk = xxxxxxxxxxxx, version = 5, reuse = true, tfo = true
```

### Snell + ShadowTLS 配置
```
=== 配置信息 ===
# 带 ShadowTLS 的配置
HK = snell, 1.2.3.4, 8989, psk = xxxxxxxxxxxx, version = 4, reuse = true, tfo = true, shadow-tls-password = yyyyyyyyyyyy, shadow-tls-sni = www.microsoft.com, shadow-tls-version = 3
HK = snell, ::1, 8989, psk = xxxxxxxxxxxx, version = 4, reuse = true, tfo = true, shadow-tls-password = yyyyyyyyyyyy, shadow-tls-sni = www.microsoft.com, shadow-tls-version = 3
```
</details>
