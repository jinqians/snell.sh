<div align="center">

# Snell One-Click Script & Docker Image

[![Stars](https://img.shields.io/github/stars/jinqians/snell.sh?style=flat-square&logo=github&color=blue)](https://github.com/jinqians/snell.sh/stargazers)
[![Forks](https://img.shields.io/github/forks/jinqians/snell.sh?style=flat-square&logo=github&color=blue)](https://github.com/jinqians/snell.sh/network/members)
[![Pull Requests](https://img.shields.io/github/issues-pr/jinqians/snell.sh?style=flat-square&logo=github&color=blue)](https://github.com/jinqians/snell.sh/pulls)
[![Docker Pulls](https://img.shields.io/docker/pulls/jinqians/snell-server?style=flat-square&logo=docker&color=blue)](https://hub.docker.com/r/jinqians/snell-server)
[![License](https://img.shields.io/github/license/jinqians/snell.sh?style=flat-square&color=blue)](LICENSE)

Install and manage Snell v4 / v5 / v6 with one command — with ShadowTLS v3,
multi-user support and BBR, plus multi-arch Docker images that print the client
config on first start.

[English](README.en.md) ｜ [中文](README.md) ｜ [Docs (wiki)](https://github.com/jinqians/snell.sh/wiki) ｜ [Author's site](https://jinqians.com)

</div>

---

## One-click script

Detects the system (Debian / Ubuntu / CentOS / RHEL / Alpine):

```bash
sh -c "$(curl -fsSL https://install.jinqians.com)"
```

Or run the one for your system:

| System | Command |
|--------|---------|
| Debian / Ubuntu / CentOS / RHEL / Rocky / AlmaLinux | `bash <(curl -fsSL https://snell.jinqians.com)` |
| Alpine 3.18 and older (native) | `sh -c "$(curl -fsSL https://snell-alpine.jinqians.com)"` |
| Alpine (in Docker; use this from 3.19 on) | `sh -c "$(curl -fsSL https://snell-docker.jinqians.com)"` |
| All-in-one menu (Snell / SS-2022 / ShadowTLS) | `bash <(curl -fsSL https://menu.jinqians.com)` |

Afterwards, `snell` opens the menu: the config, changing the port / PSK / DNS, more users, versions (v4 / v5 / v6 side by side), ShadowTLS, BBR, rule-based routing.
→ [Script install and management](https://github.com/jinqians/snell.sh/wiki/Script-Install-and-Management)

## Docker

Image [`jinqians/snell-server`](https://hub.docker.com/r/jinqians/snell-server) (amd64 / arm64 / armv7; no armv7 for v6). The container runs as `nobody`, so make its config directory first:

```bash
mkdir -p ./snell-config && chown -R 65534:65533 ./snell-config
docker run -d --name snell-server --restart unless-stopped \
  -p 6160:6160/tcp -p 6160:6160/udp \
  -e SNELL_VER=v5 -e SNELL_PORT=6160 \
  -v ./snell-config:/etc/snell \
  jinqians/snell-server:v5
```

docker compose (`compose.yml`):

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

For Snell v6: the `:v6` image, `SNELL_VER=v6`, and `SNELL_MODE` for the transport mode (clients must match) → [Deploying Snell v6](https://github.com/jinqians/snell.sh/wiki/Docker#c-deploying-snell-v6).
ShadowTLS, switching versions, every environment variable → [Docker](https://github.com/jinqians/snell.sh/wiki/Docker)

## Getting the client config

```bash
snell                          # script install: menu → "3. Show config"
docker logs snell-server       # Docker: printed on first start, also in ./snell-config/client-config.txt
```

It is Surge's format, ready to paste:

```text
HK = snell, 1.2.3.4, 6160, psk = your_psk, version = 5, reuse = true, tfo = true
```

## ShadowTLS (optional)

A TLS disguise around Snell; only the ShadowTLS port is exposed. Script install: menu → "9. ShadowTLS";
Docker: add `SHADOWTLS_ENABLE=1` and friends → [Snell + ShadowTLS v3](https://github.com/jinqians/snell.sh/wiki/Docker#b-snell--shadowtls-v3)

## Documentation

Features, usage and how it works are in the [wiki](https://github.com/jinqians/snell.sh/wiki):

- [Overview](https://github.com/jinqians/snell.sh/wiki/Overview) — features, repository layout
- [Script install and management](https://github.com/jinqians/snell.sh/wiki/Script-Install-and-Management) — the all-in-one menu, v4 / v5 / v6 side by side, Alpine, the main menu
- [Rule-based routing](https://github.com/jinqians/snell.sh/wiki/Rule-based-Routing) — rule sets with sing-box (the server stays the official snell-server)
- [Docker](https://github.com/jinqians/snell.sh/wiki/Docker) — image tags, ShadowTLS, v6, switching versions, Compose, environment variables
- [Traffic management](https://github.com/jinqians/snell.sh/wiki/Traffic-Management) ｜ [PSM](https://github.com/jinqians/snell.sh/wiki/PSM)
- [Protocols](https://github.com/jinqians/snell.sh/wiki/Protocols) — v4 / v5 / v6, choosing the v6 options, ShadowTLS
- [Surge config](https://github.com/jinqians/snell.sh/wiki/Surge-Config)

---

## Sponsors

Sponsorship from reputable vendors is welcome.

---

## Links

- Author's site: [jinqians.com](https://jinqians.com)
- PSM: [jinqians/proxy-stack](https://github.com/jinqians/proxy-stack)
- Docker Hub: [jinqians/snell-server](https://hub.docker.com/r/jinqians/snell-server)
- License: [GPL-3.0](LICENSE)

---

## Daily runs

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://stats.jinqians.com/chart/snell.svg?theme=dark">
  <img alt="Daily runs, last 30 days" src="https://stats.jinqians.com/chart/snell.svg">
</picture>
