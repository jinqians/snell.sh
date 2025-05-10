- [English](README.en.md) ｜ [中文](README.md)

## Manual Deployment Tutorial

[Click to open](https://vps.jinqians.com/snell-v4%e9%83%a8%e7%bd%b2%e6%95%99%e7%a8%8b/)


# Debian / Ubuntu

Snell + ShadowTLS One-Click Installation Script
*Please ensure `curl` or `wget` is installed*
**Choose the appropriate script as needed**

This script supports installing Snell v4, and can also install Snell v4 + ShadowTLS v3 + Snell | SS 2022 | ShadowTLS with a multifunctional management menu:

```bash
bash <(curl -L -s menu.jinqians.com)
```

* Snell Installation Script

```bash
bash <(curl -L -s snell.jinqians.com)
```

* Download Script Locally and Run

```bash
wget https://raw.githubusercontent.com/jinqians/snell.sh/main/snell.sh -O snell.sh && chmod +x snell.sh && ./snell.sh
```


# CentOS

Snell One-Click Installation Script
**The CentOS version only supports Snell for now; Snell + ShadowTLS is not supported**

* Snell Installation Script

```bash
bash <(curl -L -s snell-centos.jinqians.com)
```

* Download Script Locally and Run

```bash
wget https://raw.githubusercontent.com/jinqians/snell.sh/refs/heads/main/snell-centos.sh -O snell-centos.sh && chmod +x snell-centos.sh && ./snell-centos.sh
```

## Protocol Introduction

### Snell Protocol

Snell is a lightweight and efficient encrypted proxy protocol designed by the Surge team. It focuses on providing secure and fast network transmission through simple design and strong encryption to meet users’ needs for privacy and performance.

### ShadowTLS

ShadowTLS is a lightweight TLS camouflage tool that effectively evades TLS fingerprint detection. By simulating normal HTTPS traffic, it offers improved privacy and connection stability.

## Overview

This management script provides an efficient and automated solution for deploying Snell and ShadowTLS proxy services on Linux systems. It supports one-click deployment of Snell or Snell + ShadowTLS, and offers easy commands for installation, configuration, version control, and uninstallation, helping users quickly set up secure and reliable proxy services.

## Surge Configuration File

Personal configuration file:
[https://raw.githubusercontent.com/jinqians/snell.sh/refs/heads/main/surge.conf](https://raw.githubusercontent.com/jinqians/snell.sh/refs/heads/main/surge.conf)

### Configuration Examples

* Snell V4 Configuration Example
* Snell + ShadowTLS Configuration Example
* VMESS Configuration Example
* Surge Subscription Example

## Features

### Basic Features

* One-click Snell deployment
* One-click Snell uninstallation
* One-click Snell service restart
* One-click Snell configuration output
* One-click Snell + ShadowTLS configuration output
* Snell version check and upgrade
* Installation and status check of Snell and ShadowTLS

### Advanced Features

* ShadowTLS installation and configuration
* One-click ShadowTLS installation
* One-click ShadowTLS uninstallation
* ShadowTLS configuration display support
* BBR network optimization
* One-click BBR configuration

### System Features

* Script updates and maintenance

### Architecture Support

* AMD64/x86\_64
* ARM64/aarch64

## System Requirements

* Debian/Ubuntu systems
* Root or sudo privileges
* Kernel version ≥ 4.9

## How to Use

After running the script, the following menu will appear:

```text
=========================================
Author: jinqian  
Website: https://jinqians.com  
Description: Snell + ShadowTLS One-Click Management Script  
=========================================

============= Basic Features =============
1) Install Snell  
2) Uninstall Snell  
3) Restart Snell  
4) View Configuration  

============ Advanced Features ============
5) Install ShadowTLS  
6) Uninstall ShadowTLS  
7) Install/Configure BBR  

============= System Features =============
8) Update Snell  
9) Update Script  
0) Exit  

Please select an action:
```

## Option Descriptions

1. **Install Snell**:

   * Installs the Snell proxy service
   * Randomly generates port and password
   * Configures system service and enables auto-start

2. **Uninstall Snell**:

   * Stops and removes the Snell service
   * Cleans up configuration files

3. **View Configuration**:

   * Displays server IP and country info
   * Displays Snell configuration (port and PSK)
   * If ShadowTLS is installed, shows the full combined configuration

4. **Install ShadowTLS**:

   * Installs ShadowTLS service
   * Auto-integrates with Snell
   * Randomly generates port and password
   * Configures TLS domain camouflage

5. **Uninstall ShadowTLS**:

   * Stops and removes ShadowTLS service
   * Cleans up configuration files

6. **Install/Configure BBR**:

   * Installs and enables BBR congestion control
   * Optimizes network performance

7. **Check for Updates**:

   * Checks latest versions of Snell and ShadowTLS
   * Offers one-click update option

8. **Update Script**:

   * Updates management script to latest version

## Configuration Example

After installation, the script will display the following configuration:

```text
=== Configuration Information ===

# Raw Snell Config  
HK = snell, 1.2.3.4, 57891, psk = xxxxxxxxxxxx, version = 4, reuse = true, tfo = true  
HK = snell, ::1, 57891, psk = xxxxxxxxxxxx, version = 4, reuse = true, tfo = true  

# Snell + ShadowTLS Config  
HK = snell, 1.2.3.4, 8989, psk = xxxxxxxxxxxx, version = 4, reuse = true, tfo = true, shadow-tls-password = yyyyyyyyyyyy, shadow-tls-sni = www.microsoft.com, shadow-tls-version = 3  
HK = snell, ::1, 8989, psk = xxxxxxxxxxxx, version = 4, reuse = true, tfo = true, shadow-tls-password = yyyyyyyyyyyy, shadow-tls-sni = www.microsoft.com, shadow-tls-version = 3  
```

## Notes

1. Snell must be installed before installing ShadowTLS
2. After uninstalling Snell, ShadowTLS must be reconfigured
3. Services must be restarted after configuration updates
4. Ensure system time is accurate
5. It’s recommended to regularly check for updates for new features and security patches
