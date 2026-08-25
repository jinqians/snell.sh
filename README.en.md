<div align="center">

# Snell One-Click Script & Docker Image

[![Stars](https://img.shields.io/github/stars/jinqians/snell.sh?style=flat-square&logo=github&color=blue)](https://github.com/jinqians/snell.sh/stargazers)
[![Forks](https://img.shields.io/github/forks/jinqians/snell.sh?style=flat-square&logo=github&color=blue)](https://github.com/jinqians/snell.sh/network/members)
[![Pull Requests](https://img.shields.io/github/issues-pr/jinqians/snell.sh?style=flat-square&logo=github&color=blue)](https://github.com/jinqians/snell.sh/pulls)
[![Docker Pulls](https://img.shields.io/docker/pulls/jinqians/snell-server?style=flat-square&logo=docker&color=blue)](https://hub.docker.com/r/jinqians/snell-server)
[![License](https://img.shields.io/github/license/jinqians/snell.sh?style=flat-square&color=blue)](LICENSE)

Install and manage Snell v4 / v5 / v6 with one command — with ShadowTLS v3,
multi-user support and BBR, plus multi-arch Docker images that print the client
config on every start.

[English](README.en.md) ｜ [中文](README.md) ｜ [Author's site](https://jinqians.com)

</div>

---

## Quick Start

Three steps to a working node; step ④ (ShadowTLS) is optional. Full details in [Usage](#usage).

**① Install** — pick one of three

**Option A: script** (auto-detects Debian / Ubuntu / CentOS / Alpine)

```bash
sh -c "$(curl -fsSL https://install.jinqians.com)"
```

**Option B: docker run**

```bash
docker run -d --name snell-server --restart unless-stopped \
  -p 6160:6160/tcp -p 6160:6160/udp \
  -e SNELL_VER=v5 -e SNELL_PORT=6160 \
  -v ./snell-config:/etc/snell \
  jinqians/snell-server:v5
```

**Option C: docker compose** — create `compose.yml`:

```yaml
services:
  snell:
    image: jinqians/snell-server:v5
    container_name: snell-server
    restart: unless-stopped
    ports:
      - "6160:6160/tcp"
      - "6160:6160/udp"
    environment:
      - SNELL_VER=v5
      - SNELL_PORT=6160
    volumes:
      - ./snell-config:/etc/snell
```

```bash
docker compose up -d
```

**② Get the config** — all three print a ready-to-use Surge config

```bash
# Option A (script): open the menu and pick "3. Show config"
snell

# Option B (docker run): it is already in the container log
docker logs snell-server

# Option C (docker compose):
docker compose logs snell
```

**③ Paste into Surge**

```text
HK = snell, 1.2.3.4, 6160, psk = your_psk, version = 5, reuse = true, tfo = true
```

**④ Want ShadowTLS camouflage?** (optional)

With ShadowTLS in front, the Snell backend listens on localhost only and just the
ShadowTLS port is exposed. See [ShadowTLS](#shadowtls) for how it works.

<details>
<summary><b>Expand: script / docker run / docker compose</b></summary>

*Option A (script)*: after installing Snell, open the menu and pick
`5. ShadowTLS`; the script switches Snell to `127.0.0.1` and prints a new client config.

```bash
snell        # menu → 5. ShadowTLS
```

*Option B (docker run)*: add four env vars and publish only the ShadowTLS port —
do **not** publish 6160.

```bash
docker run -d --name snell-shadowtls --restart unless-stopped \
  -p 8443:8443/tcp \
  -e SNELL_VER=v5 -e SNELL_PORT=6160 \
  -e SNELL_LISTEN_HOST=127.0.0.1 \
  -e SHADOWTLS_ENABLE=1 \
  -e SHADOWTLS_PORT=8443 \
  -e SHADOWTLS_SNI=www.microsoft.com \
  -v ./snell-config:/etc/snell \
  jinqians/snell-server:v5

docker logs snell-shadowtls     # PSK and ShadowTLS password are both there
```

*Option C (docker compose)*:

```yaml
services:
  snell-shadowtls:
    image: jinqians/snell-server:v5
    container_name: snell-shadowtls
    restart: unless-stopped
    ports:
      - "8443:8443/tcp"
    environment:
      - SNELL_VER=v5
      - SNELL_PORT=6160
      - SNELL_LISTEN_HOST=127.0.0.1
      - SHADOWTLS_ENABLE=1
      - SHADOWTLS_PORT=8443
      - SHADOWTLS_SNI=www.microsoft.com
    volumes:
      - ./snell-config:/etc/snell
```

```bash
docker compose up -d
docker compose logs snell-shadowtls
```

The resulting client config looks like this (**use the ShadowTLS port**; the PSK and the
ShadowTLS password are two different values):

```text
HK = snell, 1.2.3.4, 8443, psk = your_psk, version = 5, reuse = true, tfo = true, shadow-tls-password = your_stls_password, shadow-tls-sni = www.microsoft.com, shadow-tls-version = 3
```

</details>

| I want to… | Go to |
|------------|-------|
| Install on a VPS with the script | [Script install](#1-script-install) |
| Use Docker / Docker Compose | [Docker](#2-docker) ｜ [Docker Compose](#3-docker-compose) |
| Find the PSK, ShadowTLS password, client config | [Viewing the client config](#4-viewing-the-client-config) |
| Look up Docker env vars | [Environment variables](#5-environment-variables) |
| Add ShadowTLS camouflage | [ShadowTLS](#shadowtls) |
| Decide between v4 / v5 / v6 | [Protocols](#protocols) |
| Set traffic quotas | [Traffic Management](#traffic-management) |
| Alpine 3.19+ won't install | [Alpine version limits](#alpine-version-limits) |

## Table of Contents

- [Quick Start](#quick-start)
- [About](#about)
- [Usage](#usage)
  - [Script install](#1-script-install)
  - [Docker](#2-docker)
  - [Docker Compose](#3-docker-compose)
  - [Viewing the client config](#4-viewing-the-client-config)
  - [Environment variables](#5-environment-variables)
- [Traffic Management](#traffic-management)
- [PSM: the full proxy stack](#psm-the-full-proxy-stack)
- [Protocols](#protocols)
- [Surge Config File](#surge-config-file)
- [Sponsors](#sponsors)

---

## About

This project offers **two ways** to deploy a Snell server; pick whichever fits:

- **One-click scripts** — install a systemd / OpenRC-managed Snell directly on a VPS. Covers Debian, Ubuntu, CentOS, RHEL and Alpine, with an interactive management menu.
- **Docker images** — multi-arch [`jinqians/snell-server`](https://hub.docker.com/r/jinqians/snell-server); one `docker run` starts the service and **prints a Surge-ready client config to the log**.

Capabilities:

| Capability | Notes |
|------------|-------|
| Snell v4 / v5 / v6 | Pick any channel; scripts and images can switch between them |
| ShadowTLS v3 | Wraps Snell in TLS camouflage and hides the raw port |
| Multi-user | Multiple ports / PSKs on one host, managed separately |
| BBR | One-click BBR congestion control |
| Egress control | `egress-interface` setting for Snell v5 / v6 |
| Auto update | Scripts self-update; images track upstream weekly via GitHub Actions |
| Client config output | Both scripts and containers emit Surge-format config, with country tags |

> For **traffic quotas, VLESS Reality, Hysteria2 and other larger setups**, use the same
> author's [PSM (Proxy Stack Manager)](#psm-the-full-proxy-stack) — this project stays
> focused on Snell itself.

<details>
<summary><b>Repository layout</b> (click to expand)</summary>

```
snell.sh            # Debian / Ubuntu main script (install, manage, update)
snell-centos.sh     # CentOS / RHEL script
snell-alpine.sh     # Alpine 3.18 script
snell-docker.sh     # Alpine local Docker build
shadowtls.sh        # ShadowTLS v3 management
multi-user.sh       # Snell multi-user management
menu.sh             # All-in-one menu (Snell / SS-2022 / ShadowTLS ...)
bbr.sh              # BBR management
install.sh          # Distro-detecting installer entry
Dockerfile          # Multi-arch image build
entrypoint.sh       # Entrypoint: generate config + print client config
build-docker-images.sh  # Local batch image build
surge.conf          # Surge reference config
```

> ⚠️ Do not move the scripts out of the repository root: installed copies self-update from
> `https://raw.githubusercontent.com/jinqians/snell.sh/main/<script>.sh`, and the
> `*.jinqians.com` short domains point at those fixed paths — moving them would break
> auto-update for existing users.

---

</details>

## Usage

### 1. Script install

**a. Auto-detect the system (easiest)**

```bash
sh -c "$(curl -fsSL https://install.jinqians.com)"
```

**b. All-in-one menu (recommended on Debian / Ubuntu)**

```bash
bash <(curl -L -s menu.jinqians.com)
```

After installation, type `menu` to reopen it:

```
=== Install ===              === Uninstall ===        === System ===
1. Snell                     5. Remove Snell          8.  Update script
2. SS-2022                   6. Remove SS-2022        9.  Traffic mgmt (→ PSM)
3. VLESS Reality             7. Remove ShadowTLS      10. Mainland-China blocking
4. ShadowTLS
```

> Options 3 (VLESS Reality) and 9 (traffic management) are handled by PSM; selecting them
> guides you through installing PSM.

**c. Per-distro scripts**

| System | Command |
|--------|---------|
| Debian / Ubuntu | `bash <(curl -L -s snell.jinqians.com)` |
| CentOS / RHEL | `bash <(curl -L -s snell-centos.jinqians.com)` |
| Alpine (local Docker build) | `sh -c "$(curl -fsSL https://snell-docker.jinqians.com)"` |
| Alpine 3.18 and older (native install) | `sh -c "$(curl -fsSL https://snell-alpine.jinqians.com)"` |

#### Alpine version limits

The official Snell binaries need glibc, while Alpine ships musl, so a compatibility layer
([sgerrand/alpine-pkg-glibc](https://github.com/sgerrand/alpine-pkg-glibc)) is required.
That approach **stopped working on Alpine 3.19**, therefore:

| Alpine version | Native install (`snell-alpine.jinqians.com`) | Docker |
|----------------|-----------------------------------------------|--------|
| ≤ 3.18 | ✅ works | ✅ works |
| ≥ 3.19 | ❌ the script refuses and exits | ✅ works (recommended) |

When `install.jinqians.com` detects Alpine it **automatically uses the Docker path**
(`snell-docker.jinqians.com`), so Alpine 3.19+ still works — Snell just runs in a
container instead of directly on the host. If you need a host-level install on Alpine,
you have to stay on 3.18.

Snell script menu:

```
=== Basics ===          === Extras ===           === System ===
1. Install Snell         5. ShadowTLS             8.  Update Snell
2. Uninstall Snell       6. BBR                   9.  Update script
3. Show config           7. Multi-user            10. Service status
4. Restart service                                11. v5/v6 egress control
```

Pick **3. Show config** after installing and the script prints a Surge config with a
country tag, ready to copy:

```text
=== Config ===
Installed version: Snell v5
HK = snell, 1.2.3.4, 57891, psk = xxxxxxxxxxxx, version = 4, reuse = true, tfo = true
HK = snell, 1.2.3.4, 57891, psk = xxxxxxxxxxxx, version = 5, reuse = true, tfo = true
```

### 2. Docker

Image: [`jinqians/snell-server`](https://hub.docker.com/r/jinqians/snell-server)

**Tags**

| Tag | Version | Notes |
|-----|---------|-------|
| `latest` | Snell v5.0.1 | Pinned to the v5 channel, never auto-jumps to v6 |
| `v4` | Snell v4.1.1 | Latest in the v4 channel |
| `v5` | Snell v5.0.1 | Latest in the v5 channel |
| `v6` | Snell v6.0.0rc2 | Latest in the v6 channel (pre-release) |
| `v4.0.0` `v4.0.1` `v4.1.0` `v4.1.1` | Snell v4 | Pinned versions |
| `v5.0.0` `v5.0.1` | Snell v5 | Pinned versions |
| `v6.0.0b1` … `v6.0.0b4` `v6.0.0rc` `v6.0.0rc2` | Snell v6 | Pinned pre-releases |

Architectures: v4 / v5 ship `amd64`, `arm64`, `armv7`; v6 has no upstream armv7 build, so
`amd64` and `arm64` only.

**a. Snell only**

```bash
docker run -d --name snell-server \
  --restart unless-stopped \
  -p 6160:6160/tcp \
  -p 6160:6160/udp \
  -e SNELL_VER=v5 \
  -e SNELL_PORT=6160 \
  -v ./snell-config:/etc/snell \
  jinqians/snell-server:v5

# print the client config
docker logs snell-server
```

**b. Snell + ShadowTLS v3**

The Snell backend stays on `127.0.0.1` inside the container, so there is **no need** to
publish 6160.

```bash
docker run -d --name snell-shadowtls \
  --restart unless-stopped \
  -p 8443:8443/tcp \
  -e SNELL_VER=v5 \
  -e SNELL_PORT=6160 \
  -e SNELL_LISTEN_HOST=127.0.0.1 \
  -e SHADOWTLS_ENABLE=1 \
  -e SHADOWTLS_PORT=8443 \
  -e SHADOWTLS_SNI=www.microsoft.com \
  -v ./snell-config:/etc/snell \
  jinqians/snell-server:v5

docker logs snell-shadowtls
```

**c. Switching Snell versions**

Change **both** the image tag and `SNELL_VER`. Deleting the old config regenerates the
PSK; keeping it reuses the existing one:

```bash
docker rm -f snell-server
rm -f ./snell-config/snell-server.conf     # skip this to keep the current PSK

docker run -d --name snell-server \
  --restart unless-stopped \
  -p 6160:6160/tcp -p 6160:6160/udp \
  -e SNELL_VER=v6 -e SNELL_PORT=6160 -e SNELL_MODE=default \
  -v ./snell-config:/etc/snell \
  jinqians/snell-server:v6
```

**d. Building images locally**

```bash
./build-docker-images.sh                      # all channels and versions
USE_BUILDX=1 PUSH=1 ./build-docker-images.sh  # multi-arch build and push
```

### 3. Docker Compose

**Snell only** — create `compose.yml`:

```yaml
services:
  snell:
    image: jinqians/snell-server:v5
    container_name: snell-server
    restart: unless-stopped
    ports:
      - "6160:6160/tcp"
      - "6160:6160/udp"
    environment:
      - SNELL_VER=v5
      - SNELL_PORT=6160
      # - SNELL_PSK=your_psk         # random on first start if unset
      # - SNELL_SERVER_IP=1.2.3.4    # auto-probed if unset
      # - SNELL_NODE_NAME=HK         # node name in the printed config
    volumes:
      - ./snell-config:/etc/snell
```

**Snell + ShadowTLS**:

```yaml
services:
  snell-shadowtls:
    image: jinqians/snell-server:v5
    container_name: snell-shadowtls
    restart: unless-stopped
    ports:
      - "8443:8443/tcp"
    environment:
      - SNELL_VER=v5
      - SNELL_PORT=6160
      - SNELL_LISTEN_HOST=127.0.0.1
      - SHADOWTLS_ENABLE=1
      - SHADOWTLS_PORT=8443
      - SHADOWTLS_SNI=www.microsoft.com
    volumes:
      - ./snell-config:/etc/snell
```

Common commands:

```bash
docker compose up -d                  # start
docker compose logs snell-shadowtls   # client config
docker compose down                   # stop and remove
```

### 4. Viewing the client config

**Every** container start prints a Surge-ready config to the log — no manual assembly:

```bash
docker logs snell-server              # started with docker run
docker compose logs snell-shadowtls   # started with docker compose
```

Example output:

```text
==============================================================
  Snell 客户端配置 (Surge 格式)
==============================================================
  服务器          : 1.2.3.4
  端口            : 8443
  PSK             : duBN4HXibFaJejO2LC61/A==
  Snell 版本      : 5
  ShadowTLS       : v3, SNI = www.microsoft.com
  ShadowTLS 密码  : vwiOI52JPMPYhpTA/n/BKQ==
  Snell 后端端口  : 6160 (仅容器内监听)
--------------------------------------------------------------
Snell = snell, 1.2.3.4, 8443, psk = duBN4HXibFaJejO2LC61/A==, version = 5, reuse = true, tfo = true, shadow-tls-password = vwiOI52JPMPYhpTA/n/BKQ==, shadow-tls-sni = www.microsoft.com, shadow-tls-version = 3
--------------------------------------------------------------
```

The same content is written to the mounted volume:

```bash
cat ./snell-config/client-config.txt      # client config
cat ./snell-config/snell-server.conf      # server config
cat ./snell-config/shadowtls-password     # ShadowTLS password
```

> - The server address comes from an automatic public-IP probe; on failure a placeholder is printed — set `SNELL_SERVER_IP` to override.
> - The port shown is the container's listening port; replace it if the host maps a different one.
> - Logs contain the PSK and ShadowTLS password — do not share them publicly.

### 5. Environment variables

**Common**

| Variable | Default | Description |
|----------|---------|-------------|
| `SNELL_VER` | follows image tag | Config mode: `v4` / `v5` / `v6` |
| `SNELL_PORT` | `6160` | Snell listening port |
| `SNELL_PSK` | random | Snell PSK |
| `SNELL_LISTEN_HOST` | `0.0.0.0` | Listen address; use `127.0.0.1` with ShadowTLS |
| `SNELL_IPV6` | `true` | v4 option; mapped to `dns-ip-preference` on v6 (`false` → `ipv4-only`) |
| `SNELL_TFO` | `true` | v4 option, not written for v5 / v6 |

**Snell v6 only**

| Variable | Default | Description |
|----------|---------|-------------|
| `SNELL_MODE` | `default` | `default` / `unshaped` / `unsafe-raw` — **must match the client** |
| `SNELL_DNS_IP_PREFERENCE` | follows `SNELL_IPV6` | `default` / `prefer-ipv4` / `prefer-ipv6` / `ipv4-only` / `ipv6-only` |
| `SNELL_DNS` | unset | Custom DNS servers, comma-separated |

**ShadowTLS**

| Variable | Default | Description |
|----------|---------|-------------|
| `SHADOWTLS_ENABLE` | `0` | Set to `1` to enable ShadowTLS v3 |
| `SHADOWTLS_PORT` | `8443` | Public ShadowTLS port |
| `SHADOWTLS_PASSWORD` | random | Stored at `/etc/snell/shadowtls-password` |
| `SHADOWTLS_SNI` | `www.microsoft.com` | TLS camouflage SNI |

**Client config output**

| Variable | Default | Description |
|----------|---------|-------------|
| `SNELL_NODE_NAME` | `Snell` | Node name in the printed config |
| `SNELL_SERVER_IP` | auto-probed | Server address (IP or domain) to print |
| `SNELL_IP_LOOKUP` | `1` | Set to `0` to skip the public-IP probe |

---

## Traffic Management

The scripts in this repository **no longer bundle traffic management** (the old
implementation was retired as incomplete). Quotas are handled by
[PSM (Proxy Stack Manager)](https://github.com/jinqians/proxy-stack) instead —
picking **9. Traffic management** in the menu guides you through installing PSM.

What PSM offers:

- Per-node **monthly quota (GB)** with an automatic reset day
- **Auto-suspend on overage**, auto-unblock after a reset or manual resume
- Precise iptables byte accounting, persisted so counting resumes after a reboot
- One place to manage traffic for Snell / SS-2022 / Xray nodes

```bash
# install PSM
bash <(curl -fsSL https://psm.jinqians.com)

# then pick: 15. Traffic management
```

> **Note**: Snell runs over TCP, so UDP is not counted; suspending a node blocks **new**
> connections only — established TCP connections drop off naturally.

---

## PSM: the full proxy stack

If you need more than Snell, use the same author's
**[PSM — Proxy Stack Manager](https://github.com/jinqians/proxy-stack)**: a single `psm`
command that manages multi-protocol, multi-core proxy servers on Linux.

```bash
bash <(curl -fsSL https://psm.jinqians.com)
```

| Area | Details |
|------|---------|
| Protocols | VLESS Reality / Vision / XHTTP, Shadowsocks, Hysteria2, **Snell**, AnyTLS |
| Cores | Xray, sing-box and mihomo running in parallel |
| Port sharing | Nginx SNI routing, multiple protocols on port 443 |
| Certificates | Automatic issuance and renewal via acme.sh |
| Traffic | Accounting, monthly quotas, auto-suspend on overage |
| Notifications | Telegram bot |
| Hardening | SSH hardening, Fail2ban, honeypots |
| Extras | Multi-language UI (zh/en/ko/ru), Docker app management, backup & restore, node URI and QR export |

**Which one to use?**

| Scenario | Suggestion |
|----------|------------|
| Just spin up a Snell node quickly | This project's script or Docker image |
| Snell plus other protocols, 443 sharing, certs, quotas | [PSM](https://github.com/jinqians/proxy-stack) |
| VLESS Reality / traffic management in this menu | Already merged into PSM |

---

## Protocols

### Snell

Snell is a lightweight encrypted proxy protocol designed by the Surge team, balancing
privacy and performance through a deliberately minimal protocol design.
It is supported by the **Surge client only**.

### Snell v4 / v5 / v6

| Feature | Snell v4 | Snell v5 | Snell v6 (RC) |
|---------|----------|----------|---------------|
| Status | Stable | Stable | Pre-release (rc2) |
| QUIC Proxy | No | Yes | Removed |
| Dynamic Record Sizing | No | Yes | Yes |
| Egress control (`egress-interface`) | No | Yes | Yes |
| Deployment-level protocol diversity | No | No | Yes (PSK-derived) |
| Cipher `mode` | No | No | `default` / `unshaped` / `unsafe-raw` |
| obfs | `http` | `http` | Removed |
| `ipv6` option | Yes | Yes | Deprecated, use `dns-ip-preference` |
| Multi-address listen | No | No | Yes (comma-separated `listen`) |
| Official armv7l build | Yes | Yes | No |

Recommendation: choose **v5** for stability (a v5 server also serves v4 clients), **v6**
if you want the newest features, and **v4 / v5** for older or armv7 devices.

**Client config format**

```text
# v4 / v5
HK = snell, 1.2.3.4, 6160, psk = your_psk, version = 5, reuse = true, tfo = true

# v6: mode must match the server
HK = snell, 1.2.3.4, 6160, psk = your_psk, version = 6, mode = default, reuse = true, tfo = true
```

### ShadowTLS

ShadowTLS is a lightweight TLS camouflage tool that makes proxy traffic look like ordinary
HTTPS traffic, improving stealth and stability. This project uses **ShadowTLS v3**.

Once enabled, the Snell backend listens **only on `127.0.0.1:<snell port>`**; clients
connect to the ShadowTLS port, so the raw Snell port is no longer exposed:

```
client ──TLS camouflage──▶ ShadowTLS(:8443) ──plain──▶ Snell(127.0.0.1:6160)
```

```text
# Snell + ShadowTLS: use the ShadowTLS port
HK = snell, 1.2.3.4, 8443, psk = your_psk, version = 5, reuse = true, tfo = true, shadow-tls-password = your_stls_password, shadow-tls-sni = www.microsoft.com, shadow-tls-version = 3
```

---

## Surge Config File

A complete Surge configuration is included for reference: [surge.conf](surge.conf)

```
https://raw.githubusercontent.com/jinqians/snell.sh/refs/heads/main/surge.conf
```

What's inside:

| Section | Contents |
|---------|----------|
| `[General]` | DNS, skip-proxy, log level and other basics |
| `[Proxy]` | Snell v4 / v5, Snell + ShadowTLS and VMess node examples |
| `[Proxy Group]` | Policy group examples |
| `[Rule]` | Common routing rules |
| `[URL Rewrite]` / `[MITM]` | Rewrite and MITM examples |

> The server addresses and PSKs in the file are examples — replace them with your own.

**Manual deployment guide**: [Snell v4 tutorial](https://vps.jinqians.com/snell-v4%e9%83%a8%e7%bd%b2%e6%95%99%e7%a8%8b/)

---

## Sponsors

Thanks to the sponsors supporting this project:

- 🥇 **[ZMTO](https://console.zmto.com/?affid=1567)** — [ZMTO review](https://vps.jinqians.com/zmto/)

If this project helps you, a ⭐ Star is appreciated.

---

## Links

- Author's site: [jinqians.com](https://jinqians.com)
- PSM: [jinqians/proxy-stack](https://github.com/jinqians/proxy-stack)
- Docker Hub: [jinqians/snell-server](https://hub.docker.com/r/jinqians/snell-server)
- License: [GPL-3.0](LICENSE)
