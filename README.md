# Snell Management Script

## Introduction
This Snell management script provides an efficient and automated solution for managing the Snell proxy service on Linux-based systems. Whether you are setting up a new Snell proxy or managing an existing instance, the script streamlines the process with simple commands for installation, configuration, version control, and uninstallation. It is designed to save time and reduce complexity for users who require a high-performance encrypted proxy service.


## Features
+ Easy Installation
+ Seamless Removal
+ Configuration Review
+ Version Check and Upgrad
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
5) 更新脚本
0) 退出
请选择操作:
```

## Options
1. 安装 Snell:
  + Installs the Snell proxy server.
  + Generates a random port and password for Snell configuration.
  + Starts the Snell service and enables it to run at startup.
2. 卸载 Snell
  + Stops the Snell service.
  + Disables Snell from running at startup.
  + Removes all Snell-related files and configurations.
3. 查看 Snell 配置:
  + Displays the current Snell configuration, including the IP address, port, and password.
4. 检查 Snell 更新:
  + Automatically checks for the latest Snell version and offers easy upgrading options, keeping the proxy service up-to-date with minimal effort.
5. 更新脚本
  + Update script 
6. 退出
  + Exits the script.

## Example Output
After installing Snell, the script will display the configuration details:
```shell
Snell 安装成功
CN = snell, 123.456.789.012, 54321, psk = abcdefghijklmnopqrst, version = 4, reuse = true, tfo = true
CN = snell, ::1, 54321, psk = abcdefghijklmnopqrst, version = 4, reuse = true, tfo = true

```

