# Snell Management Script

## Introduction
This script allows you to easily manage the installation, uninstallation, and configuration of the Snell proxy server. It provides a menu-based interface to perform these operations.

## Features
+ Install Snell Proxy Server
+ Uninstall Snell Proxy Server
+ View Snell Configuration
+ Supports both AMD64 and ARM64 architectures

## Prerequisites
+ A Debian-based system (e.g., Ubuntu)
+ Root or sudo access

## Installation
1. Download and Run the script:
```shell
wget https://raw.githubusercontent.com/jinqians/snell.sh/main/snell.sh -O snell.sh && chmod +x snell.sh && ./snell.sh
```


## Usage
When you run the script, you will see the following menu:
```shell
 ========================================= 
 作者: jinqian 
 网站：https://jinqians.com 
 描述: 这个脚本用于安装、卸载、查看和更新 Snell 代理 
 ========================================= 
 ============== Snell 管理工具 ============== 
1) 安装 Snell
2) 卸载 Snell
3) 查看 Snell 配置
4) 检查 Snell 更新
0) 退出
请选择操作:
```

## Options
1. 安装 Snell:
  + Installs the Snell proxy server.
  + Generates a random port and password for Snell configuration.
  + Starts the Snell service and enables it to run at startup.
2. 升级 Snell
  + Check the difference between the current version and the latest version and upgrade if necessary.
3. 卸载 Snell
  + Stops the Snell service.
  + Disables Snell from running at startup.
  + Removes all Snell-related files and configurations.
4. 查看 Snell 配置:
  + Displays the current Snell configuration, including the IP address, port, and password.
5. 退出
  + Exits the script.

## Example Output
After installing Snell, the script will display the configuration details:
```shell
Snell 安装成功
CN = snell, 123.456.789.012, 54321, psk = abcdefghijklmnopqrst, version = 4, reuse = true, tfo = true
```

