- [中文](README.md) ｜ [English](README.en.md)

# Snell + ShadowTLS 一键安装脚本
*请确保已安装curl/wget*

**以下脚本根据需要选择**
+ snell | ss 2022 | shadowtls 多功能管理菜单
```bash
bash <(curl -L -s menu.jinqians.com)
```
+ snell安装脚本
```bash
bash <(curl -L -s snell.jinqians.com)
```
+ 下载脚本至本地执行 
```bash
wget https://raw.githubusercontent.com/jinqians/snell.sh/main/snell.sh -O snell.sh && chmod +x snell.sh && ./snell.sh
```

## 协议简介
### Snell 协议
Snell 协议是由 Surge 团队设计的一种轻量级、高效的加密代理协议，专注于提供安全、快速的网络传输服务。该协议通过简洁的设计和强大的加密技术，满足了用户对隐私保护和高性能传输的需求。

### ShadowTLS
ShadowTLS 是一个轻量级的 TLS 伪装工具，能够有效规避 TLS 指纹检测。它通过模拟正常的 HTTPS 流量，提供更好的隐私保护和连接稳定性。

## 介绍
该管理脚本为基于 Linux 系统的 Snell 和 ShadowTLS 代理服务提供了高效、自动化的管理解决方案。脚本支持一键部署Snell 和 Snell + ShadowTLS 组合，通过简洁的命令实现安装、配置、版本控制以及卸载，帮助用户快速搭建安全可靠的代理服务。

## Surge配置文件
自用配置文件：https://raw.githubusercontent.com/jinqians/snell.sh/refs/heads/main/surge.conf
### 配置文件说明
- Snell V4 配置示例
- Snell + ShadowTLS 配置示例
- VMESS 配置示例

## 功能
### 基础功能
- 一键部署Snell
- 一键卸载Snell
- 一键重启Snell服务
- 一键输出Snell配置
- 一键输出Snell + ShadowTLS配置
- Snell版本检查与升级
- Snell、ShadowTLS安装、运行状态查看

### 增强功能
- ShadowTLS 安装与配置
   - 一键安装ShadowTLS
   - 一键卸载ShadowTLS
   - 支持ShadowTLS配置查看
- BBR 网络优化
   - 一键配置bbr

### 系统功能
- 脚本更新维护

### 架构支持
- AMD64/x86_64
- ARM64/aarch64

## 系统要求
- Debian/Ubuntu 系统
- Root 或 sudo 权限
- 内核版本 ≥ 4.9

## 使用方法
运行脚本后，会显示以下菜单：
```
=========================================
作者: jinqian
网站：https://jinqians.com
描述: Snell + ShadowTLS 一键管理脚本
=========================================
============= 基础功能 =============
1) 安装 Snell
2) 卸载 Snell
3) 重启 Snell
4) 查看配置信息
============= 增强功能 =============
5) 安装 ShadowTLS
6) 卸载 ShadowTLS
7) 安装/配置 BBR
============= 系统功能 =============
8) 检查更新
9) 更新脚本
0) 退出
请选择操作：
```

## 选项说明
1. **安装 Snell**：
   - 安装 Snell 代理服务
   - 自动生成随机端口和密码
   - 配置系统服务并设置开机自启

2. **卸载 Snell**：
   - 停止并移除 Snell 服务
   - 清理相关配置文件

3. **查看配置信息**：
   - 显示服务器 IP 地址和国家信息
   - 显示 Snell 配置（端口和 PSK）
   - 如果安装了 ShadowTLS，显示完整的组合配置

4. **安装 ShadowTLS**：
   - 安装 ShadowTLS 服务
   - 自动配置与 Snell 的集成
   - 生成随机监听端口和密码
   - 配置 TLS 域名伪装

5. **卸载 ShadowTLS**：
   - 停止并移除 ShadowTLS 服务
   - 清理相关配置文件

6. **安装/配置 BBR**：
   - 安装并启用 BBR 拥塞控制算法
   - 优化网络传输性能

7. **检查更新**：
   - 检查 Snell 和 ShadowTLS 的最新版本
   - 提供一键更新选项

8. **更新脚本**：
   - 更新管理脚本到最新版本

## 配置示例
安装完成后，脚本会显示以下配置信息：
```
=== 配置信息 ===
# 原始 Snell 配置
HK = snell, 1.2.3.4, 57891, psk = xxxxxxxxxxxx, version = 4, reuse = true, tfo = true
HK = snell, ::1, 57891, psk = xxxxxxxxxxxx, version = 4, reuse = true, tfo = true

# 带 ShadowTLS 的配置
HK = snell, 1.2.3.4, 8989, psk = xxxxxxxxxxxx, version = 4, reuse = true, tfo = true, shadow-tls-password = yyyyyyyyyyyy, shadow-tls-sni = www.microsoft.com, shadow-tls-version = 3
HK = snell, ::1, 8989, psk = xxxxxxxxxxxx, version = 4, reuse = true, tfo = true, shadow-tls-password = yyyyyyyyyyyy, shadow-tls-sni = www.microsoft.com, shadow-tls-version = 3
```

## 注意事项
1. 安装 ShadowTLS 前需要先安装 Snell
2. 卸载Snell后，ShadowTLS需要进行重新配置
3. 配置更新后需要重启相关服务
4. 请确保系统时间准确
5. 建议定期检查更新以获得最新特性和安全修复
