- [中文](README.md)
- [English](README.en.md)
- 
# Snell 管理脚本

## snell协议简介
Snell 是由 Surge 开发者设计的一种轻量级、高效的加密代理协议，专注于提供安全、快速的网络传输服务。该协议通过简洁的设计和强大的加密技术，满足了用户对隐私保护和高性能传输的需求。Snell 的跨平台支持和可靠性能，使其广泛应用于需要高效代理服务的场景，例如跨网络访问、隐私保护和数据加密传输。

## 介绍  
该 Snell 管理脚本为基于 Linux 系统的 Snell 代理服务提供了高效、自动化的管理解决方案。无论是搭建新的 Snell 代理，还是管理已有的实例，脚本都能通过简洁的命令实现安装、配置、版本控制以及卸载，帮助用户节省时间，减少管理复杂性，是需要高性能加密代理服务用户的理想选择。

## 功能  
+ 简单易用的安装流程  
+ 一键卸载  
+ 配置查看  
+ 版本检查与升级
+ 一键配置BBR
+ 支持 AMD64 和 ARM64 架构  

## 系统要求  
+ 一台基于 Debian 的系统（如 Ubuntu）  
+ 拥有 Root 或 sudo 权限  

## 安装  
1. 下载并运行脚本：  
```shell  
wget https://raw.githubusercontent.com/jinqians/snell.sh/main/snell.sh -O snell.sh && chmod +x snell.sh && ./snell.sh
```

## 使用方法  
运行脚本后，会显示以下菜单：  
```shell  
 =========================================  
 作者: jinqian  
 网站：https://jinqians.com  
 描述: 该脚本用于安装、卸载、查看和更新 Snell 代理  
 =========================================  
 ============= Snell 管理工具 =============  
1) 安装 Snell  
2) 卸载 Snell  
3) 查看 Snell 配置  
4) 检查 Snell 更新  
5) 更新脚本  
6) 安装/配置 BBR  
0) 退出  
请选择操作：  
```

## 选项说明  
1. **安装 Snell**：  
   + 安装 Snell 代理服务。  
   + 自动生成随机端口和密码用于 Snell 配置。  
   + 启动 Snell 服务并设置为开机自启。  
2. **卸载 Snell**：  
   + 停止 Snell 服务。  
   + 禁止 Snell 服务开机启动。  
   + 删除与 Snell 相关的所有文件和配置。  
3. **查看 Snell 配置**：  
   + 显示当前 Snell 配置，包括 IP 地址、端口和密码。  
4. **检查 Snell 更新**：  
   + 自动检查最新版本 Snell，并提供便捷的升级选项，确保代理服务始终保持最新状态。  
5. **更新脚本**：  
   + 更新当前 Snell 管理脚本至最新版。  
6. **安装/配置 BBR**：  
   + 安装并配置 BBR 网络优化模块。  
0. **退出**：  
   + 退出脚本。  

## 示例输出  
安装 Snell 完成后，脚本会显示以下配置信息：  
```shell  
Snell 安装成功。  
CN = snell, 123.456.789.012, 54321, psk = abcdefghijklmnopqrst, version = 4, reuse = true, tfo = true  
CN = snell, ::1, 54321, psk = abcdefghijklmnopqrst, version = 4, reuse = true, tfo = true  
```  
