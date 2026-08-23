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

## Docker

Docker Hub image tags:
- `jinqians/snell-server:latest`: pinned to Snell v5.0.1, not v6
- `jinqians/snell-server:v4`: current v4 tag, points to v4.1.1
- `jinqians/snell-server:v5`: current v5 tag, points to v5.0.1
- `jinqians/snell-server:v6`: current v6 pre-release tag, points to v6.0.0rc2
- Fixed v4 tags: `v4.0.0`, `v4.0.1`, `v4.1.0`, `v4.1.1`
- Fixed v5 tags: `v5.0.0`, `v5.0.1`
- Fixed v6 pre-release tags: `v6.0.0b1`, `v6.0.0b2`, `v6.0.0b3`, `v6.0.0b4`, `v6.0.0rc`, `v6.0.0rc2`

Supported platforms:
- v4/v5: `linux/amd64`, `linux/arm64`, `linux/arm/v7`
- v6: `linux/amd64`, `linux/arm64`

After installing Docker, run v5 directly:

```bash
docker run -d --name snell-server \
  --restart unless-stopped \
  -p 6160:6160/tcp \
  -p 6160:6160/udp \
  -e SNELL_PORT=6160 \
  -e SNELL_PSK=your_16_plus_char_psk \
  -e SNELL_VER=v5 \
  jinqians/snell-server:v5
```

If `SNELL_PSK` is omitted, the container generates one on first start:

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

View the generated PSK and config:

```bash
docker logs snell-server
cat ./snell-config/snell-server.conf
```

To switch versions, change both the image tag and `SNELL_VER`:

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
  -e SNELL_MODE=default \
  -v ./snell-config:/etc/snell \
  jinqians/snell-server:v6
```

v6-only environment variables: `SNELL_MODE` (`default` / `unshaped` / `unsafe-raw`, must match the client),
`SNELL_DNS_IP_PREFERENCE` (`default` / `prefer-ipv4` / `prefer-ipv6` / `ipv4-only` / `ipv6-only`), and `SNELL_DNS`.
`SNELL_IPV6=false` is translated to `dns-ip-preference = ipv4-only`; `SNELL_TFO` is ignored by v6.

If you set `SNELL_PSK` manually, use at least 16 characters for v6 compatibility. v5 and v6 require both TCP and UDP port mappings. v4 only needs TCP, but keeping the UDP mapping is harmless.

Run Snell with ShadowTLS:

```bash
docker run -d --name snell-shadowtls \
  --restart unless-stopped \
  -p 8443:8443/tcp \
  -e SNELL_PORT=6160 \
  -e SNELL_VER=v5 \
  -e SNELL_LISTEN_HOST=127.0.0.1 \
  -e SNELL_PSK=your_16_plus_char_psk \
  -e SHADOWTLS_ENABLE=1 \
  -e SHADOWTLS_PORT=8443 \
  -e SHADOWTLS_PASSWORD=your_shadowtls_password \
  -e SHADOWTLS_SNI=www.microsoft.com \
  -v ./snell-config:/etc/snell \
  jinqians/snell-server:v5
```

If `SHADOWTLS_PASSWORD` is omitted, the container generates one on first start and saves it to `./snell-config/shadowtls-password`. When ShadowTLS is enabled, clients connect to port `8443`; the Snell backend port `6160` is used inside the container and normally does not need to be published.

View the generated ShadowTLS password:

```bash
cat ./snell-config/shadowtls-password
```

Client settings:

| Item | Value |
|------|-------|
| Server | VPS public IP or domain |
| Port | ShadowTLS public port, `8443` in the example |
| Snell version | `5` |
| Snell PSK | The `psk` value in `./snell-config/snell-server.conf` |
| ShadowTLS password | The content of `./snell-config/shadowtls-password`, or the manually supplied `SHADOWTLS_PASSWORD` |
| ShadowTLS SNI | `SHADOWTLS_SNI`, default `www.microsoft.com` |

View the client secrets:

```bash
grep '^psk' ./snell-config/snell-server.conf
cat ./snell-config/shadowtls-password
```

Surge example:

```text
HK = snell, SERVER_IP, 8443, psk = your_16_plus_char_psk, version = 5, reuse = true, tfo = true, shadow-tls-password = your_shadowtls_password, shadow-tls-sni = www.microsoft.com, shadow-tls-version = 3
```

Upgrade the image:

```bash
docker pull jinqians/snell-server:v5
docker rm -f snell-server
docker run -d --name snell-server \
  --restart unless-stopped \
  -p 6160:6160/tcp \
  -p 6160:6160/udp \
  -e SNELL_PORT=6160 \
  -e SNELL_VER=v5 \
  -v ./snell-config:/etc/snell \
  jinqians/snell-server:v5
```

Remove the container:

```bash
docker rm -f snell-server
```

Run with Docker Compose:

```yaml
services:
  snell:
    image: jinqians/snell-server:latest
    container_name: snell-server
    restart: unless-stopped
    ports:
      - "6160:6160/tcp"
      - "6160:6160/udp"
    environment:
      - SNELL_PORT=6160
      - SNELL_VER=v5
    volumes:
      - ./snell-config:/etc/snell
```

Start it:

```bash
docker compose up -d
```

View the generated PSK and service logs:

```bash
docker logs snell-server
cat ./snell-config/snell-server.conf
```

To set a PSK manually, add this to `environment`:

```yaml
      - SNELL_PSK=your_16_plus_char_psk
```

Run Snell with ShadowTLS using Docker Compose:

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
      - SNELL_PSK=your_16_plus_char_psk
      - SHADOWTLS_ENABLE=1
      - SHADOWTLS_PORT=8443
      - SHADOWTLS_PASSWORD=your_shadowtls_password
      - SHADOWTLS_SNI=www.microsoft.com
    volumes:
      - ./snell-config:/etc/snell
```

Stop and remove the container:

```bash
docker compose down
```

Build v4/v5/v6 images locally:

```bash
./build-docker-images.sh
```

Build and push multi-architecture images:

```bash
USE_BUILDX=1 PUSH=1 ./build-docker-images.sh
```

## 🆕 New Version Features (v4.0)
### Snell Version Support
- ✅ **Snell v4** - Stable version, recommended for production environments
- ✅ **Snell v5** - Stable version, supports QUIC Proxy, Dynamic Record Sizing, egress control
- ✅ **Snell v6 (RC)** - Deployment-level protocol diversity, `mode` setting, `dns-ip-preference`; QUIC Proxy and obfs removed
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

#### Snell v4 / v5 / v6 Comparison
| Feature | Snell v4 | Snell v5 | Snell v6 (RC) |
|---------|----------|----------|---------------|
| Status | Stable | Stable | Pre-release (rc2) |
| Compatibility | Fully compatible | Backward compatible with v4 | Client must use `version = 6` |
| QUIC Proxy | ❌ | ✅ | Removed |
| Dynamic Record Sizing | ❌ | ✅ | ✅ |
| Egress Control (`egress-interface`) | ❌ | ✅ | ✅ |
| Deployment-level protocol diversity | ❌ | ❌ | ✅ (PSK-derived) |
| `mode` setting | ❌ | ❌ | `default` / `unshaped` / `unsafe-raw` |
| obfs | `http` | `http` | Removed |
| `ipv6` parameter | ✅ | ✅ | Deprecated, use `dns-ip-preference` |
| Multi-address `listen` | ❌ | ❌ | ✅ (comma separated) |
| armv7l build | ✅ | ✅ | ❌ |
| Production Use | ✅ Recommended | ✅ Recommended | ⚠️ For testing |

> Server and client `mode` must match. Surge example:
> `Proxy = snell, 1.2.3.4, 6160, psk = xxx, version = 6, mode = default, reuse = true, tfo = true`

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
