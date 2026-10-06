<div align="center">

# Snell 一键脚本 & Docker 镜像

[![Stars](https://img.shields.io/github/stars/jinqians/snell.sh?style=flat-square&logo=github&color=blue)](https://github.com/jinqians/snell.sh/stargazers)
[![Forks](https://img.shields.io/github/forks/jinqians/snell.sh?style=flat-square&logo=github&color=blue)](https://github.com/jinqians/snell.sh/network/members)
[![Pull Requests](https://img.shields.io/github/issues-pr/jinqians/snell.sh?style=flat-square&logo=github&color=blue)](https://github.com/jinqians/snell.sh/pulls)
[![Docker Pulls](https://img.shields.io/docker/pulls/jinqians/snell-server?style=flat-square&logo=docker&color=blue)](https://hub.docker.com/r/jinqians/snell-server)
[![License](https://img.shields.io/github/license/jinqians/snell.sh?style=flat-square&color=blue)](LICENSE)

一键安装与管理 Snell v4 / v5 / v6，支持 ShadowTLS v3、多用户与 BBR，
并提供启动即输出客户端配置的多架构 Docker 镜像。

[中文](README.md) ｜ [English](README.en.md) ｜ [文档（Wiki）](https://github.com/jinqians/snell.sh/wiki) ｜ [作者网站](https://jinqians.com)

</div>

---

## 一键脚本

自动识别系统（Debian / Ubuntu / CentOS / RHEL / Alpine）：

```bash
sh -c "$(curl -fsSL https://install.jinqians.com)"
```

也可以按系统直接运行：

| 系统 | 命令 |
|------|------|
| Debian / Ubuntu / CentOS / RHEL / Rocky / AlmaLinux | `bash <(curl -fsSL https://snell.jinqians.com)` |
| Alpine 3.18 及以下（原生安装） | `sh -c "$(curl -fsSL https://snell-alpine.jinqians.com)"` |
| Alpine（Docker 方案，3.19 起用这个） | `sh -c "$(curl -fsSL https://snell-docker.jinqians.com)"` |
| 多功能菜单（Snell / SS-2022 / ShadowTLS） | `bash <(curl -fsSL https://menu.jinqians.com)` |

装好后输入 `snell` 进入管理菜单：查看配置、修改端口 / PSK / DNS、多用户、版本管理（v4 / v5 / v6 同机共存）、ShadowTLS、BBR、规则分流。
→ [脚本安装与管理](https://github.com/jinqians/snell.sh/wiki/%E8%84%9A%E6%9C%AC%E5%AE%89%E8%A3%85%E4%B8%8E%E7%AE%A1%E7%90%86)

## Docker

镜像 [`jinqians/snell-server`](https://hub.docker.com/r/jinqians/snell-server)（amd64 / arm64 / armv7；v6 没有 armv7）。容器以 `nobody` 运行，先建好配置目录：

```bash
mkdir -p ./snell-config && chown -R 65534:65533 ./snell-config
docker run -d --name snell-server --restart unless-stopped \
  -p 6160:6160/tcp -p 6160:6160/udp \
  -e SNELL_VER=v5 -e SNELL_PORT=6160 \
  -v ./snell-config:/etc/snell \
  jinqians/snell-server:v5
```

docker compose（`compose.yml`）：

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

装 Snell v6：镜像用 `:v6`、`SNELL_VER=v6`，并用 `SNELL_MODE` 选加密模式（客户端必须一致）→ [部署 Snell v6](https://github.com/jinqians/snell.sh/wiki/Docker-%E9%83%A8%E7%BD%B2#3-%E9%83%A8%E7%BD%B2-snell-v6)。
ShadowTLS、切换版本、全部环境变量 → [Docker 部署](https://github.com/jinqians/snell.sh/wiki/Docker-%E9%83%A8%E7%BD%B2)

## 获取客户端配置

```bash
snell                          # 脚本安装：菜单选「3. 查看配置」
docker logs snell-server       # Docker：首次启动时打印在日志里，也保存在 ./snell-config/client-config.txt
```

得到的是 Surge 格式，直接粘贴：

```text
HK = snell, 1.2.3.4, 6160, psk = your_psk, version = 5, reuse = true, tfo = true
```

## ShadowTLS（可选）

给 Snell 套一层 TLS 伪装，对外只暴露 ShadowTLS 端口。脚本安装：菜单选「9. ShadowTLS」；
Docker：加 `SHADOWTLS_ENABLE=1` 等环境变量 → [Snell + ShadowTLS v3](https://github.com/jinqians/snell.sh/wiki/Docker-%E9%83%A8%E7%BD%B2#2-snell--shadowtls-v3)

## 文档

功能、用法和原理在 [Wiki](https://github.com/jinqians/snell.sh/wiki)：

- [项目介绍](https://github.com/jinqians/snell.sh/wiki/%E9%A1%B9%E7%9B%AE%E4%BB%8B%E7%BB%8D) —— 功能一览、仓库结构
- [脚本安装与管理](https://github.com/jinqians/snell.sh/wiki/%E8%84%9A%E6%9C%AC%E5%AE%89%E8%A3%85%E4%B8%8E%E7%AE%A1%E7%90%86) —— 多功能菜单、v4 / v5 / v6 同机共存、Alpine、主菜单
- [规则分流](https://github.com/jinqians/snell.sh/wiki/%E8%A7%84%E5%88%99%E5%88%86%E6%B5%81) —— 用 sing-box 按规则集分流（服务端仍是官方 snell-server）
- [Docker 部署](https://github.com/jinqians/snell.sh/wiki/Docker-%E9%83%A8%E7%BD%B2) —— 镜像标签、ShadowTLS、v6、切换版本、Compose、环境变量
- [流量管理](https://github.com/jinqians/snell.sh/wiki/%E6%B5%81%E9%87%8F%E7%AE%A1%E7%90%86) ｜ [PSM 代理管理](https://github.com/jinqians/snell.sh/wiki/PSM-%E4%BB%A3%E7%90%86%E7%AE%A1%E7%90%86)
- [协议介绍](https://github.com/jinqians/snell.sh/wiki/%E5%8D%8F%E8%AE%AE%E4%BB%8B%E7%BB%8D) —— v4 / v5 / v6 对比、v6 参数选择、ShadowTLS
- [Surge 配置文件](https://github.com/jinqians/snell.sh/wiki/Surge-%E9%85%8D%E7%BD%AE%E6%96%87%E4%BB%B6)

---

## 赞助

欢迎信誉良好的商家进行赞助。

---

## 相关链接

- 作者网站：[jinqians.com](https://jinqians.com)
- PSM 项目：[jinqians/proxy-stack](https://github.com/jinqians/proxy-stack)
- Docker Hub：[jinqians/snell-server](https://hub.docker.com/r/jinqians/snell-server)
- 开源协议：[GPL-3.0](LICENSE)

---

## 运行统计

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://stats.jinqians.com/chart/snell.svg?theme=dark&lang=zh">
  <img alt="近 30 天每日运行次数" src="https://stats.jinqians.com/chart/snell.svg?lang=zh">
</picture>
