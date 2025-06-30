- [English](README.en.md) ｜ [中文](README.md)

## Manual Deployment Tutorial

[Click to open](https://vps.jinqians.com/snell-v4%e9%83%a8%e7%bd%b2%e6%95%99%e7%a8%8b/)


# Debian / Ubuntu

Snell + ShadowTLS One-Click Installation Script
*Please ensure `curl` or `wget` is installed*
**Choose the appropriate script as needed**

This script supports installing Snell v4 and v5, and can also install Snell + ShadowTLS v3 + Snell | SS 2022 | ShadowTLS with a multifunctional management menu:

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
**The CentOS version supports Snell v4 and v5; Snell + ShadowTLS is not supported**

* Snell Installation Script

```bash
bash <(curl -L -s snell-centos.jinqians.com)
```

* Download Script Locally and Run

```bash
wget https://raw.githubusercontent.com/jinqians/snell.sh/refs/heads/main/snell-centos.sh -O snell-centos.sh && chmod +x snell-centos.sh && ./snell-centos.sh
```

## 🆕 New Version Features (v4.0)
### Snell Version Support
- ✅ **Snell v4** - Stable version, recommended for production environments
- ✅ **Snell v5** - Beta version, supports new features (QUIC Proxy, Dynamic Record Sizing, etc.)
- ✅ **Smart Version Detection** - Automatically detects currently installed Snell version
- ✅ **Version Upgrade Choice** - Support upgrading from v4 to v5, or continue using v4

### New Features
- 🎯 **Version Selection Installation** - Choose v4 or v5 version during installation
- 🔄 **Smart Updates** - Choose to upgrade to v5 or continue using v4 during updates
- 📊 **Version Status Display** - Shows currently installed Snell version
- 🔧 **Multi-Architecture Support** - Supports amd64, i386, aarch64, armv7l architectures
- 📝 **Optimized Configuration Output** - v5 version automatically outputs both v4 and v5 Surge configurations

## Protocol Introduction

### Snell Protocol

Snell is a lightweight and efficient encrypted proxy protocol designed by the Surge team. It focuses on providing secure and fast network transmission through simple design and strong encryption to meet users' needs for privacy and performance.

#### Snell v4 vs v5 Comparison
| Feature | Snell v4 | Snell v5 |
|---------|----------|----------|
| Status | Stable | Beta |
| Compatibility | Fully compatible | Backward compatible with v4 |
| QUIC Proxy | ❌ | ✅ |
| Dynamic Record Sizing | ❌ | ✅ |
| Egress Control | ❌ | ✅ |
| Production Use | ✅ Recommended | ⚠️ For testing |

### ShadowTLS

ShadowTLS is a lightweight TLS camouflage tool that effectively evades TLS fingerprint detection. By simulating normal HTTPS traffic, it offers improved privacy and connection stability.

## Thanks for sponsoring
[ZMTO](https://console.zmto.com/?affid=1567)

## Overview

This management script provides an efficient and automated solution for deploying Snell and ShadowTLS proxy services on Linux systems. It supports one-click deployment of Snell v4/v5 or Snell + ShadowTLS, and offers easy commands for installation, configuration, version control, and uninstallation, helping users quickly set up secure and reliable proxy services.

## Surge Configuration File

Personal configuration file:
[https://raw.githubusercontent.com/jinqians/snell.sh/refs/heads/main/surge.conf](https://raw.githubusercontent.com/jinqians/snell.sh/refs/heads/main/surge.conf)

### Configuration Examples

* Snell V4 Configuration Example
* Snell V5 Configuration Example
* Snell + ShadowTLS Configuration Example
* VMESS Configuration Example
* Surge Subscription Example

## Features

### Basic Features

* One-click Snell v4/v5 deployment
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
* Multi-user management
* Support for multi-port multi-user configuration

### System Features

* Script updates and maintenance
* Configuration backup and restore

### Architecture Support

* AMD64/x86_64
* i386
* ARM64/aarch64
* ARMv7/armv7l

## System Requirements

* Debian/Ubuntu systems (snell.sh)
* CentOS/Red Hat/Fedora systems (snell-centos.sh)
* Root or sudo privileges
* Kernel version ≥ 4.9

## How to Use

After running the script, the following menu will appear:

```text
============================================
          Snell Management Script v4.0
============================================
Author: jinqian  
Website: https://jinqians.com  
============================================
=============== Service Status Check ===============
Snell Installed  CPU: 0.12%  Memory: 2.45 MB  Running: 1/1
ShadowTLS Not Installed
============================================

=== Basic Features ===
1. Install Snell
2. Uninstall Snell
3. View Configuration
4. Restart Services

=== Advanced Features ===
5. ShadowTLS Management
6. BBR Management
7. Multi-User Management

=== System Features ===
8. Update Snell
9. Update Script
10. View Service Status
0. Exit Script
============================================
Please enter option [0-10]:
```

## Option Descriptions

1. **Install Snell**:

   * Supports choosing Snell v4 or v5 version
   * Randomly generates port and password
   * Configures system service and enables auto-start
   * Outputs corresponding Surge configuration based on version

2. **Uninstall Snell**:

   * Stops and removes the Snell service
   * Cleans up configuration files

3. **View Configuration**:

   * Shows currently installed Snell version
   * Displays server IP and country info
   * Displays Snell configuration (port and PSK)
   * If ShadowTLS is installed, shows the full combined configuration

4. **Restart Services**:

   * Restarts all Snell related services

5. **ShadowTLS Management**:

   * Installs ShadowTLS service
   * Auto-integrates with Snell
   * Randomly generates port and password
   * Configures TLS domain camouflage

6. **BBR Management**:

   * Installs and enables BBR congestion control
   * Optimizes network performance

7. **Multi-User Management**:

   * Supports multi-port multi-user configuration
   * Independently manages each user's service

8. **Update Snell**:

   * Detects current Snell version
   * Supports upgrading from v4 to v5
   * Provides version selection for updates
   * **Important: This is an update operation, not a reinstall**
   * All existing configurations will be preserved (port, password, user configs)
   * Services will automatically restart
   * Configuration files will be automatically backed up

9. **Update Script**:

   * Updates management script to latest version

10. **View Service Status**:

    * Shows running status of all services
    * Displays resource usage information

## Configuration Examples

### Snell v4 Configuration
```text
=== Configuration Information ===
Currently Installed Version: Snell v4
# Raw Snell Config  
HK = snell, 1.2.3.4, 57891, psk = xxxxxxxxxxxx, version = 4, reuse = true, tfo = true  
HK = snell, ::1, 57891, psk = xxxxxxxxxxxx, version = 4, reuse = true, tfo = true  
```

### Snell v5 Configuration
```text
=== Configuration Information ===
Currently Installed Version: Snell v5
# Snell v5 Config (supports both v4 and v5 clients)
HK = snell, 1.2.3.4, 57891, psk = xxxxxxxxxxxx, version = 4, reuse = true, tfo = true
HK = snell, 1.2.3.4, 57891, psk = xxxxxxxxxxxx, version = 5, reuse = true, tfo = true
```

### Snell + ShadowTLS Configuration
```text
=== Configuration Information ===
# Snell + ShadowTLS Config  
HK = snell, 1.2.3.4, 8989, psk = xxxxxxxxxxxx, version = 4, reuse = true, tfo = true, shadow-tls-password = yyyyyyyyyyyy, shadow-tls-sni = www.microsoft.com, shadow-tls-version = 3  
HK = snell, ::1, 8989, psk = xxxxxxxxxxxx, version = 4, reuse = true, tfo = true, shadow-tls-password = yyyyyyyyyyyy, shadow-tls-sni = www.microsoft.com, shadow-tls-version = 3  
```

## Version Upgrade Instructions
### Upgrading from v4 to v5
1. Run the script and select "Update Snell"
2. The script will detect current version as v4
3. Choose "Upgrade to Snell v5"
4. The script will automatically download and install v5 version
5. Configuration will be automatically preserved, no need to reconfigure

### Version Compatibility
- Snell v5 server is backward compatible with v4 clients
- If you don't want to use v5's new features, set client to v4 version
- Dynamic Record Sizing optimization only relates to server side

## Notes

1. Snell v5 is a beta version, use with caution in production environments
2. Snell must be installed before installing ShadowTLS
3. After uninstalling Snell, ShadowTLS must be reconfigured
4. Services must be restarted after configuration updates
5. Ensure system time is accurate
6. It's recommended to regularly check for updates for new features and security patches
7. v5 version supports more architectures, including i386 and armv7l
