[中文](README.md) ｜ [English](README.en.md)
## Snell 协议
<details>
   <summary>协议简介[展开查看]</summary>
   
### Snell 协议
Snell 协议是由 Surge 团队设计的一种轻量级、高效的加密代理协议，专注于提供安全、快速的网络传输服务。该协议通过简洁的设计和强大的加密技术，满足了用户对隐私保护和高性能传输的需求。

#### Snell v4 vs v5 对比
| 特性 | Snell v4 | Snell v5 |
|------|----------|----------|
| 状态 | 稳定版 | 最新版 |
| 安全性 | ✅ | ✅ |
| QUIC Proxy | ❌ | ✅ |
| Dynamic Record Sizing | ❌ | ✅ |
| 出口控制 | ❌ | ✅ |

### ShadowTLS
ShadowTLS 是一个轻量级的 TLS 伪装工具，能够有效规避 TLS 指纹检测。它通过模拟正常的 HTTPS 流量，提供更好的隐私保护和连接稳定性。

## 脚本介绍
该管理脚本为基于 Linux 系统的 Snell 和 ShadowTLS 代理服务提供了高效、自动化的管理解决方案，已支持debian、ubuntu、centos、alpine。脚本支持一键部署 Snell v4/v5 或 Snell + ShadowTLS 组合，通过简洁的命令实现安装、配置、版本控制以及卸载，帮助用户快速搭建安全可靠的代理服务。
</details>

## 食用说明
<details>
   <summary>脚本食用说明[展开查看]</summary>
   
脚本自行判断系统，选择对应安装脚本
### snell 安装
```bash
sh -c "$(curl -fsSL https://install.jinqians.com)"
```
### 多功能管理菜单使用(仅支持debian/ubuntu)
```bash
bash <(curl -L -s menu.jinqians.com)
```

## 可自行根据系统选择
#### Debian/Ubuntu安装
```bash
bash <(curl -L -s snell.jinqians.com)
```
#### CentOS安装
```bash
bash <(curl -L -s snell-centos.jinqians.com)
```
#### Alpine 安装(本地构建)
```bash
sh -c "$(curl -fsSL https://snell-docker.jinqians.com)"
```
#### Alpine 3.18安装
```bash
sh -c "$(curl -fsSL https://snell-alpine.jinqians.com)"
```
#### Docker
```bash
docker run -d --name snell-server \
  --restart unless-stopped \
  --network host \
  -e SNELL_PORT=6160 \
  -e SNELL_PSK=your_psk \
  -e SNELL_VER=v5 \
  jinqians/snell-server:latest
```

#### Docker Compose
当前为镜像为5.0.1
```yaml
services:
  snell:
    image: jinqians/snell-server:latest
    container_name: snell-server
    restart: unless-stopped
    network_mode: host
    environment:
      - SNELL_PORT=6160
      - SNELL_PSK=jinqians.com   # 自定义密钥，留空则自动生成
      - SNELL_VER=v5
    volumes:
      - ./snell-config:/etc/snell
```
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

