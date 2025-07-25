[中文](README.md) ｜ [English](README.en.md)

## 协议简介
### Snell 协议
Snell 协议是由 Surge 团队设计的一种轻量级、高效的加密代理协议，专注于提供安全、快速的网络传输服务。该协议通过简洁的设计和强大的加密技术，满足了用户对隐私保护和高性能传输的需求。

#### Snell v4 vs v5 对比
| 特性 | Snell v4 | Snell v5 |
|------|----------|----------|
| 状态 | 稳定版 | 最新版 |
| 完全性 | ✅ | ✅ |
| QUIC Proxy | ❌ | ✅ |
| Dynamic Record Sizing | ❌ | ✅ |
| 出口控制 | ❌ | ✅ |

### ShadowTLS
ShadowTLS 是一个轻量级的 TLS 伪装工具，能够有效规避 TLS 指纹检测。它通过模拟正常的 HTTPS 流量，提供更好的隐私保护和连接稳定性。

## 脚本介绍
该管理脚本为基于 Linux 系统的 Snell 和 ShadowTLS 代理服务提供了高效、自动化的管理解决方案，已支持debian、ubuntu、centos、alpine。脚本支持一键部署 Snell v4/v5 或 Snell + ShadowTLS 组合，通过简洁的命令实现安装、配置、版本控制以及卸载，帮助用户快速搭建安全可靠的代理服务。

## 食用教程
### snell 安装脚本使用
```bash
sh -c "$(curl -fsSL https://install.jinqians.com)"
```
### 多功能管理菜单使用(仅支持debian/ubuntu)
```bash
bash <(curl -L -s menu.jinqians.com)
```

#### Debian/Ubuntu安装
```bash
bash <(curl -L -s snell.jinqians.com)
```
#### CentOS安装
```bash
bash <(curl -L -s snell-centos.jinqians.com)
```
#### Alpine安装
```bash
sh -c "$(curl -fsSL https://snell-alpine.jinqians.com)"
```
## 🥇 感谢赞助
+ [ZMTO](https://console.zmto.com/?affid=1567)
+ [ZMTO 测评](https://vps.jinqians.com/zmto/)

## 手搓教程
[点击跳转](https://vps.jinqians.com/snell-v4%e9%83%a8%e7%bd%b2%e6%95%99%e7%a8%8b/)

## Surge配置文件
自用配置文件：https://raw.githubusercontent.com/jinqians/snell.sh/refs/heads/main/surge.conf
### 配置文件说明
- Snell V4 配置示例
- Snell V5 配置示例
- Snell + ShadowTLS 配置示例
- VMESS 配置示例
- surge 订阅示例

## 功能
### 基础功能
- 一键部署 Snell v4/v5
- 一键卸载 Snell
- 一键重启 Snell 服务
- 一键输出 Snell 配置
- 一键输出 Snell + ShadowTLS 配置
- Snell 版本检查与升级
- Snell、ShadowTLS 安装、运行状态查看

### 增强功能
- ShadowTLS 安装与配置
   - 一键安装 ShadowTLS
   - 一键卸载 ShadowTLS
   - 支持 ShadowTLS 配置查看
- BBR 网络优化
   - 一键配置 bbr
- 多用户管理
   - 支持多端口多用户配置

### 系统功能
- 脚本更新维护
- 配置备份与恢复

### 架构支持
- AMD64/x86_64
- i386
- ARM64/aarch64
- ARMv7/armv7l

## 系统要求
- Debian/Ubuntu 系统（snell.sh）
- CentOS/Red Hat/Fedora 系统（snell-centos.sh）
- Root 或 sudo 权限
- 内核版本 ≥ 4.9

## 使用方法
运行脚本后，会显示以下菜单：
```
============================================
          Snell 管理脚本 v4.0
============================================
作者: jinqian
网站：https://jinqians.com
============================================
=============== 服务状态检查 ===============
Snell 已安装  CPU：0.12%  内存：2.45 MB  运行中：1/1
ShadowTLS 未安装
============================================

=== 基础功能 ===
1. 安装 Snell
2. 卸载 Snell
3. 查看配置
4. 重启服务

=== 增强功能 ===
5. ShadowTLS 管理
6. BBR 管理
7. 多用户管理

=== 系统功能 ===
8. 更新Snell
9. 更新脚本
10. 查看服务状态
0. 退出脚本
============================================
请输入选项 [0-10]:
```

## 选项说明
1. **安装 Snell**：
   - 支持选择 Snell v4 或 v5 版本
   - 自动生成随机端口和密码
   - 配置系统服务并设置开机自启
   - 根据版本输出相应的 Surge 配置

2. **卸载 Snell**：
   - 停止并移除 Snell 服务
   - 清理相关配置文件

3. **查看配置信息**：
   - 显示当前安装的 Snell 版本
   - 显示服务器 IP 地址和国家信息
   - 显示 Snell 配置（端口和 PSK）
   - 如果安装了 ShadowTLS，显示完整的组合配置

4. **重启服务**：
   - 重启所有 Snell 相关服务

5. **ShadowTLS 管理**：
   - 安装 ShadowTLS 服务
   - 自动配置与 Snell 的集成
   - 生成随机监听端口和密码
   - 配置 TLS 域名伪装

6. **BBR 管理**：
   - 安装并启用 BBR 拥塞控制算法
   - 优化网络传输性能

7. **多用户管理**：
   - 支持多端口多用户配置
   - 独立管理每个用户的服务

8. **更新 Snell**：
   - 检测当前 Snell 版本
   - 支持从 v4 升级到 v5
   - 提供版本选择更新
   - **重要：这是更新操作，不是重新安装**
   - 所有现有配置将被保留（端口、密码、用户配置）
   - 服务会自动重启
   - 配置文件会自动备份

9. **更新脚本**：
   - 更新管理脚本到最新版本

10. **查看服务状态**：
    - 显示所有服务的运行状态
    - 显示资源使用情况

## 配置示例
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

## 版本升级说明
### 从 v4 升级到 v5
1. 运行脚本选择"更新 Snell"
2. 脚本会检测当前版本为 v4
3. 选择"升级到 Snell v5"
4. 脚本会自动下载并安装 v5 版本
5. 配置会自动保留，无需重新配置

### 版本兼容性
- Snell v5 服务端向下兼容 v4 客户端
- 如果不想使用 v5 的新特性，客户端设置为 v4 版本即可
- Dynamic Record Sizing 优化只和服务端有关

## 注意事项
1. Snell v5 为测试版本，生产环境请谨慎使用
2. 安装 ShadowTLS 前需要先安装 Snell
3. 卸载 Snell 后，ShadowTLS 需要进行重新配置
4. 配置更新后需要重启相关服务
5. 请确保系统时间准确
