- [English](README.en.md) ｜ [中文](README.md)

# Snell + ShadowTLS One-Click Installation Script

## Protocol Introduction
### Snell
Snell is a lightweight and efficient encrypted proxy protocol designed by the Surge developer, focused on providing secure and fast network transmission services. Through its concise design and robust encryption technology, it meets users' needs for privacy protection and high-performance transmission.

### ShadowTLS
ShadowTLS is a lightweight TLS camouflage tool that effectively evades TLS fingerprint detection. By simulating normal HTTPS traffic, it provides better privacy protection and connection stability.

## Introduction
This management script provides an efficient and automated solution for managing Snell and ShadowTLS proxy services on Linux-based systems. The script supports one-click deployment of the Snell + ShadowTLS combination, implementing installation, configuration, version control, and uninstallation through simple commands, helping users quickly set up secure and reliable proxy services.

## Features
### Basic Functions
- Simple and easy installation process
- One-click uninstallation
- Configuration viewing
- Version check and upgrade

### Enhanced Functions
- ShadowTLS installation and configuration
- BBR network optimization

### System Functions
- Script update maintenance

### Architecture Support
- AMD64/x86_64
- ARM64/aarch64

## System Requirements
- Debian/Ubuntu system
- Root or sudo privileges
- Kernel version ≥ 4.9

## Installation
```bash
wget https://raw.githubusercontent.com/jinqians/snell.sh/main/snell.sh -O snell.sh && chmod +x snell.sh && ./snell.sh
```

## Usage
After running the script, you will see the following menu:
```
=========================================
Author: jinqian
Website: https://jinqians.com
Description: Snell + ShadowTLS One-Click Management Script
=========================================
============= Basic Functions =============
1) Install Snell
2) Uninstall Snell
3) View Configuration
============= Enhanced Functions =============
4) Install ShadowTLS
5) Uninstall ShadowTLS
6) Install/Configure BBR
============= System Functions =============
7) Check Updates
8) Update Script
0) Exit
Please select an operation:
```

## Option Details
1. **Install Snell**:
   - Install Snell proxy service
   - Automatically generate random port and password
   - Configure system service and set auto-start

2. **Uninstall Snell**:
   - Stop and remove Snell service
   - Clean up related configuration files

3. **View Configuration**:
   - Display server IP address and country information
   - Show Snell configuration (port and PSK)
   - If ShadowTLS is installed, show complete combined configuration

4. **Install ShadowTLS**:
   - Install ShadowTLS service
   - Automatically configure integration with Snell
   - Generate random listening port and password
   - Configure TLS domain disguise

5. **Uninstall ShadowTLS**:
   - Stop and remove ShadowTLS service
   - Clean up related configuration files

6. **Install/Configure BBR**:
   - Install and enable BBR congestion control algorithm
   - Optimize network transmission performance

7. **Check Updates**:
   - Check for latest versions of Snell and ShadowTLS
   - Provide one-click update option

8. **Update Script**:
   - Update management script to the latest version

## Configuration Example
After installation, the script will display the following configuration information:
```
=== Configuration Information ===
# Original Snell Configuration
HK = snell, 1.2.3.4, 57891, psk = xxxxxxxxxxxx, version = 4, reuse = true, tfo = true
HK = snell, ::1, 57891, psk = xxxxxxxxxxxx, version = 4, reuse = true, tfo = true

# Configuration with ShadowTLS
HK = snell, 1.2.3.4, 8989, psk = xxxxxxxxxxxx, version = 4, reuse = true, tfo = true, shadow-tls-password = yyyyyyyyyyyy, shadow-tls-sni = www.microsoft.com, shadow-tls-version = 3
HK = snell, ::1, 8989, psk = xxxxxxxxxxxx, version = 4, reuse = true, tfo = true, shadow-tls-password = yyyyyyyyyyyy, shadow-tls-sni = www.microsoft.com, shadow-tls-version = 3
```

## Notes
1. Snell must be installed before installing ShadowTLS
2. After uninstalling Snell, ShadowTLS needs to be reconfigured.
3. Services need to be restarted after configuration updates
4. Ensure system time is accurate
5. Regularly check for updates to get the latest features and security fixes
