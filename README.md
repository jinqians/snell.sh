<div align="center">

# Snell 一键脚本 & Docker 镜像

[![Stars](https://img.shields.io/github/stars/jinqians/snell.sh?style=flat-square&logo=github&color=blue)](https://github.com/jinqians/snell.sh/stargazers)
[![Forks](https://img.shields.io/github/forks/jinqians/snell.sh?style=flat-square&logo=github&color=blue)](https://github.com/jinqians/snell.sh/network/members)
[![Pull Requests](https://img.shields.io/github/issues-pr/jinqians/snell.sh?style=flat-square&logo=github&color=blue)](https://github.com/jinqians/snell.sh/pulls)
[![Docker Pulls](https://img.shields.io/docker/pulls/jinqians/snell-server?style=flat-square&logo=docker&color=blue)](https://hub.docker.com/r/jinqians/snell-server)
[![License](https://img.shields.io/github/license/jinqians/snell.sh?style=flat-square&color=blue)](LICENSE)

一键安装与管理 Snell v4 / v5 / v6，支持 ShadowTLS v3、多用户与 BBR，
并提供启动即输出客户端配置的多架构 Docker 镜像。

[中文](README.md) ｜ [English](README.en.md) ｜ [作者网站](https://jinqians.com)

</div>

---

## 快速开始

三步拿到一个可用节点，第 ④ 步（ShadowTLS 伪装）可选。详细说明见 [使用方法](#使用方法)。

**① 安装** —— 三选一

**方式 A：脚本安装**（自动识别 Debian / Ubuntu / CentOS / Alpine ≤ 3.18）

```bash
sh -c "$(curl -fsSL https://install.jinqians.com)"
```

**方式 B：docker run**

```bash
docker run -d --name snell-server --restart unless-stopped \
  -p 6160:6160/tcp -p 6160:6160/udp \
  -e SNELL_VER=v5 -e SNELL_PORT=6160 \
  -v ./snell-config:/etc/snell \
  jinqians/snell-server:v5
```

**方式 C：docker compose** —— 新建 `compose.yml`：

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

**② 获取配置** —— 三种装法都会直接输出 Surge 格式配置，复制即可用

```bash
# 方式 A（脚本）：进入菜单选 “3. 查看配置”
snell

# 方式 B（docker run）：配置已打印在容器日志里
docker logs snell-server

# 方式 C（docker compose）：
docker compose logs snell
```

**③ 粘贴到 Surge**

```text
HK = snell, 1.2.3.4, 6160, psk = your_psk, version = 5, reuse = true, tfo = true
```

**④ 需要 ShadowTLS 伪装？**（可选）

套一层 TLS 伪装后，Snell 后端只在本机监听，对外只暴露 ShadowTLS 端口。
详见 [ShadowTLS 说明](#shadowtls)。

<details>
<summary><b>展开：脚本 / docker run / docker compose 三种装法</b></summary>

*方式 A（脚本）*：装完 Snell 后进入菜单选 `5. ShadowTLS 管理`，按提示填端口和 SNI，
脚本会自动把 Snell 改为只监听 `127.0.0.1` 并生成新的客户端配置。

```bash
snell        # 进入菜单 → 5. ShadowTLS 管理
```

*方式 B（docker run）*：加 4 个环境变量，对外只映射 ShadowTLS 端口，**不要**映射 6160。

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

docker logs snell-shadowtls     # PSK 和 ShadowTLS 密码都在里面
```

*方式 C（docker compose）*：

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

得到的客户端配置形如（**端口填 ShadowTLS 端口**，PSK 与 ShadowTLS 密码是两个不同的值）：

```text
HK = snell, 1.2.3.4, 8443, psk = your_psk, version = 5, reuse = true, tfo = true, shadow-tls-password = your_stls_password, shadow-tls-sni = www.microsoft.com, shadow-tls-version = 3
```

</details>

| 我想…… | 看这里 |
|--------|--------|
| 用脚本装在 VPS 上 | [脚本安装](#一脚本安装) |
| 用 Docker / Docker Compose | [Docker 部署](#二docker-部署) ｜ [Docker Compose](#三docker-compose) |
| 找 PSK、ShadowTLS 密码、客户端配置 | [查看客户端配置](#四查看客户端配置) |
| 查 Docker 环境变量 | [环境变量](#五环境变量) |
| 加 ShadowTLS 伪装 | [ShadowTLS](#shadowtls) |
| 搞不清 v4 / v5 / v6 选哪个 | [协议介绍](#协议介绍) |
| 做流量限额 | [流量管理](#流量管理) |
| Alpine 3.19+ 装不上 | [Alpine 版本限制](#alpine-版本限制) |

## 目录

- [Snell 一键脚本 \& Docker 镜像](#snell-一键脚本--docker-镜像)
  - [快速开始](#快速开始)
  - [目录](#目录)
  - [项目介绍](#项目介绍)
  - [使用方法](#使用方法)
    - [一、脚本安装](#一脚本安装)
      - [Alpine 版本限制](#alpine-版本限制)
    - [二、Docker 部署](#二docker-部署)
    - [三、Docker Compose](#三docker-compose)
    - [四、查看客户端配置](#四查看客户端配置)
    - [五、环境变量](#五环境变量)
  - [流量管理](#流量管理)
  - [PSM：更完整的代理管理方案](#psm更完整的代理管理方案)
  - [协议介绍](#协议介绍)
    - [Snell](#snell)
    - [Snell v4 / v5 / v6 对比](#snell-v4--v5--v6-对比)
    - [ShadowTLS](#shadowtls)
  - [Surge 配置文件](#surge-配置文件)
  - [赞助](#赞助)
  - [相关链接](#相关链接)

---

## 项目介绍

本项目提供 Snell 服务端的**两种部署方式**，两者可按需选用：

- **一键脚本** —— 直接在 VPS 上安装 systemd / OpenRC 托管的 Snell，覆盖 Debian、Ubuntu、CentOS、RHEL、Alpine，附带交互式管理菜单
- **Docker 镜像** —— 多架构镜像 [`jinqians/snell-server`](https://hub.docker.com/r/jinqians/snell-server)，`docker run` 一条命令起服务，**启动即在日志中输出可粘贴到 Surge 的客户端配置**

主要能力：

| 能力 | 说明 |
|------|------|
| Snell v4 / v5 / v6 | 三个版本任选，脚本与镜像均可互相切换 |
| ShadowTLS v3 | 为 Snell 套一层 TLS 伪装，隐藏原始端口 |
| 多用户 | 单机多端口 / 多 PSK，独立增删改查 |
| BBR | 一键开启 BBR 拥塞控制 |
| 出口控制 | Snell v5 / v6 的 `egress-interface` 设置 |
| 自动更新 | 脚本内置自更新；镜像由 GitHub Actions 每周跟随上游发布 |
| 客户端配置输出 | 脚本与容器都会自动生成 Surge 格式配置，含国家/地区标识 |

> **流量管理、VLESS Reality、Hysteria2 等更复杂的场景**，请使用同作者的
> [PSM（Proxy Stack Manager）](#psm更完整的代理管理方案)，本项目专注于 Snell 本身。

<details>
<summary><b>仓库结构</b>（点击展开）</summary>

```
snell.sh            # Debian / Ubuntu 主脚本（安装、管理、更新）
snell-centos.sh     # CentOS / RHEL 脚本
snell-alpine.sh     # Alpine 3.18 脚本
snell-docker.sh     # Alpine 本地构建 Docker 方案
shadowtls.sh        # ShadowTLS v3 管理
multi-user.sh       # Snell 多用户管理
menu.sh             # 统一管理菜单（Snell / SS-2022 / ShadowTLS 等）
bbr.sh              # BBR 管理
install.sh          # 自动识别系统的安装入口
Dockerfile          # 多架构镜像构建
entrypoint.sh       # 容器入口：生成配置 + 输出客户端配置
build-docker-images.sh  # 本地批量构建镜像
surge.conf          # Surge 参考配置文件
```

> ⚠️ 根目录脚本的路径不要变动：服务端已安装的脚本通过
> `https://raw.githubusercontent.com/jinqians/snell.sh/main/<脚本名>.sh` 自更新，
> `*.jinqians.com` 短域名也指向这些固定路径，移动文件会导致存量用户的自动更新失效。

---

</details>

## 使用方法

### 一、脚本安装

**1. 自动识别系统（推荐入门）**

脚本会检测发行版并调用对应的安装脚本：

```bash
sh -c "$(curl -fsSL https://install.jinqians.com)"
```

**2. 多功能管理菜单（推荐 Debian / Ubuntu）**

```bash
bash <(curl -L -s menu.jinqians.com)
```

安装后输入 `menu` 即可再次进入：

```
=== 安装管理 ===              === 卸载功能 ===          === 系统功能 ===
1. Snell 安装管理             5. 卸载 Snell             8.  更新脚本
2. SS-2022 安装管理           6. 卸载 SS-2022           9.  流量管理（转 PSM）
3. VLESS Reality 安装管理     7. 卸载 ShadowTLS         10. 中国大陆屏蔽管理
4. ShadowTLS 安装管理
```

> 选项 3（VLESS Reality）与选项 9（流量管理）已整合到 PSM，选择后会引导安装 PSM。

**3. 按系统单独安装**

| 系统 | 命令 |
|------|------|
| Debian / Ubuntu | `bash <(curl -L -s snell.jinqians.com)` |
| CentOS / RHEL | `bash <(curl -L -s snell-centos.jinqians.com)` |
| Alpine（Docker 本地构建） | `sh -c "$(curl -fsSL https://snell-docker.jinqians.com)"` |
| Alpine 3.18 及以下（原生安装） | `sh -c "$(curl -fsSL https://snell-alpine.jinqians.com)"` |

#### Alpine 版本限制

Snell 官方二进制依赖 glibc，而 Alpine 使用 musl，需要借助
[sgerrand/alpine-pkg-glibc](https://github.com/sgerrand/alpine-pkg-glibc) 兼容包。
该方案在 **Alpine 3.19 起失效**，因此：

| Alpine 版本 | 原生安装（`snell-alpine.jinqians.com`） | Docker 方案 |
|-------------|------------------------------------------|-------------|
| ≤ 3.18 | ✅ 可用 | ✅ 可用 |
| ≥ 3.19 | ❌ 脚本会主动拒绝并退出 | ✅ 可用（推荐） |

`install.jinqians.com` 检测到 Alpine 时会**自动走 Docker 方案**（`snell-docker.jinqians.com`），
所以 Alpine 3.19+ 用它也能装上，只是跑在容器里而非直接跑在宿主机上。
想要纯宿主机安装又必须用 Alpine 的话，只能停留在 3.18。

Snell 主脚本菜单：

```
=== 基础功能 ===        === 增强功能 ===        === 系统功能 ===
1. 安装 Snell            5. ShadowTLS 管理       8.  更新 Snell
2. 卸载 Snell            6. BBR 管理             9.  更新脚本
3. 查看配置              7. 多用户管理           10. 查看服务状态
4. 重启服务                                      11. Snell v5/v6 出口控制设置
```

安装完成后选择 **3. 查看配置**，脚本会输出带国家/地区标识的 Surge 配置，直接复制即可：

```text
=== 配置信息 ===
当前安装版本: Snell v5
HK = snell, 1.2.3.4, 57891, psk = xxxxxxxxxxxx, version = 4, reuse = true, tfo = true
HK = snell, 1.2.3.4, 57891, psk = xxxxxxxxxxxx, version = 5, reuse = true, tfo = true
```

### 二、Docker 部署

镜像地址：[`jinqians/snell-server`](https://hub.docker.com/r/jinqians/snell-server)

**镜像标签**

| 标签 | 对应版本 | 说明 |
|------|----------|------|
| `latest` | Snell v5.0.1 | 固定跟随 v5 通道，不会自动升到 v6 |
| `v4` | Snell v4.1.1 | v4 通道最新 |
| `v5` | Snell v5.0.1 | v5 通道最新 |
| `v6` | Snell v6.0.0rc2 | v6 通道最新（预发布） |
| `v4.0.0` `v4.0.1` `v4.1.0` `v4.1.1` | Snell v4 | 固定版本 |
| `v5.0.0` `v5.0.1` | Snell v5 | 固定版本 |
| `v6.0.0b1` … `v6.0.0b4` `v6.0.0rc` `v6.0.0rc2` | Snell v6 | 固定版本（预发布） |

架构支持：v4 / v5 为 `amd64`、`arm64`、`armv7`；v6 上游未提供 armv7 构建，仅 `amd64`、`arm64`。

**1. 仅 Snell**

```bash
docker run -d --name snell-server \
  --restart unless-stopped \
  -p 6160:6160/tcp \
  -p 6160:6160/udp \
  -e SNELL_VER=v5 \
  -e SNELL_PORT=6160 \
  -v ./snell-config:/etc/snell \
  jinqians/snell-server:v5

# 查看客户端配置
docker logs snell-server
```

**2. Snell + ShadowTLS v3**

Snell 后端只在容器内监听 `127.0.0.1`，对外仅暴露 ShadowTLS 端口，因此**不需要**映射 6160。

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

**3. 切换 Snell 版本**

需同时修改**镜像标签**和 `SNELL_VER`；删除旧配置文件会重新生成 PSK，保留则沿用原 PSK：

```bash
docker rm -f snell-server
rm -f ./snell-config/snell-server.conf     # 想保留原 PSK 就跳过这一步

docker run -d --name snell-server \
  --restart unless-stopped \
  -p 6160:6160/tcp -p 6160:6160/udp \
  -e SNELL_VER=v6 -e SNELL_PORT=6160 -e SNELL_MODE=default \
  -v ./snell-config:/etc/snell \
  jinqians/snell-server:v6
```

**4. 本地构建镜像**

```bash
./build-docker-images.sh                      # 构建全部通道与版本
USE_BUILDX=1 PUSH=1 ./build-docker-images.sh  # 多架构构建并推送
```

### 三、Docker Compose

**仅 Snell** —— 创建 `compose.yml`：

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
      # - SNELL_PSK=自定义PSK        # 不填则首次启动随机生成
      # - SNELL_SERVER_IP=1.2.3.4    # 不填则容器自动探测公网 IP
      # - SNELL_NODE_NAME=HK         # 客户端配置里的节点名
    volumes:
      - ./snell-config:/etc/snell
```

**Snell + ShadowTLS**：

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

常用命令：

```bash
docker compose up -d                  # 启动
docker compose logs snell-shadowtls   # 查看客户端配置
docker compose down                   # 停止并删除
```

### 四、查看客户端配置

容器**每次启动**都会在日志中打印一份可直接粘贴到 Surge 的配置，无需手动拼接：

```bash
docker logs snell-server              # docker run 启动
docker compose logs snell-shadowtls   # docker compose 启动
```

输出示例：

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

同一份内容也会写入挂载目录，随时可查：

```bash
cat ./snell-config/client-config.txt      # 客户端配置
cat ./snell-config/snell-server.conf      # 服务端配置
cat ./snell-config/shadowtls-password     # ShadowTLS 密码
```

> - 服务器地址由容器自动探测公网 IP 得到；探测失败会显示为 `服务器IP`，可用 `SNELL_SERVER_IP` 手动指定。
> - 端口按容器内监听端口输出，若宿主机映射了不同端口请自行替换。
> - 日志中含 PSK 与 ShadowTLS 密码，请勿公开分享容器日志。

### 五、环境变量

**Snell 通用**

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `SNELL_VER` | 跟随镜像标签 | Snell 配置模式：`v4` / `v5` / `v6` |
| `SNELL_PORT` | `6160` | Snell 监听端口 |
| `SNELL_PSK` | 自动生成 | Snell PSK |
| `SNELL_LISTEN_HOST` | `0.0.0.0` | 监听地址；搭配 ShadowTLS 时用 `127.0.0.1` |
| `SNELL_IPV6` | `true` | v4 配置项；v6 下会转换为 `dns-ip-preference`（`false` → `ipv4-only`） |
| `SNELL_TFO` | `true` | v4 配置项，v5 / v6 不再写入 |

**仅 Snell v6**

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `SNELL_MODE` | `default` | 加密模式 `default` / `unshaped` / `unsafe-raw`，**客户端必须一致** |
| `SNELL_DNS_IP_PREFERENCE` | 跟随 `SNELL_IPV6` | `default` / `prefer-ipv4` / `prefer-ipv6` / `ipv4-only` / `ipv6-only` |
| `SNELL_DNS` | 未设置 | 自定义 DNS 服务器，多个用逗号分隔 |

**ShadowTLS**

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `SHADOWTLS_ENABLE` | `0` | 设为 `1` 启用 ShadowTLS v3 |
| `SHADOWTLS_PORT` | `8443` | ShadowTLS 对外监听端口 |
| `SHADOWTLS_PASSWORD` | 自动生成 | 生成后保存到 `/etc/snell/shadowtls-password` |
| `SHADOWTLS_SNI` | `www.microsoft.com` | TLS 伪装 SNI |

**客户端配置输出**

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `SNELL_NODE_NAME` | `Snell` | 输出配置中的节点名 |
| `SNELL_SERVER_IP` | 自动探测 | 手动指定服务器地址（IP 或域名） |
| `SNELL_IP_LOOKUP` | `1` | 设为 `0` 关闭公网 IP 自动探测 |

---

## 流量管理

本仓库的脚本**不再内置流量管理**（原实现不够完善已下线），流量限额统一交由
[PSM（Proxy Stack Manager）](https://github.com/jinqians/proxy-stack) 处理。
在管理菜单中选择 **9. 流量管理** 会直接引导你安装 PSM。

PSM 的流量管理能力：

- 按节点设置**月度流量上限（GB）**与每月自动重置日
- **超限自动暂停节点**，重置或手动恢复后自动解封
- 基于 iptables 精确计数，数据持久化保存，服务器重启后断点续计
- 统一管理 Snell / SS-2022 / Xray 等多种协议的节点流量

```bash
# 安装 PSM
bash <(curl -fsSL https://psm.jinqians.com)

# 进入后选择：15. 流量管理
```

> **注意**：Snell 使用 TCP，流量计数不含 UDP；暂停节点只阻断**新连接**，
> 已建立的 TCP 连接会在自然断开后失效。

---

## PSM：更完整的代理管理方案

如果你的需求不止 Snell，推荐使用同作者的
**[PSM — Proxy Stack Manager](https://github.com/jinqians/proxy-stack)**：
一个用单条 `psm` 命令统一管理多协议、多内核的 Linux 代理服务端工具。

```bash
bash <(curl -fsSL https://psm.jinqians.com)
```

| 维度 | 内容 |
|------|------|
| 支持协议 | VLESS Reality / Vision / XHTTP、Shadowsocks、Hysteria2、**Snell**、AnyTLS |
| 并行内核 | Xray、sing-box、mihomo 三套内核可同时运行 |
| 端口复用 | Nginx SNI 分流，多协议共用 443 端口 |
| 证书管理 | 基于 acme.sh 自动申请与续期 |
| 流量管理 | 流量统计、月度限额、超限自动暂停 |
| 通知 | Telegram Bot 推送 |
| 安全加固 | SSH 加固、Fail2ban、蜜罐 |
| 其他 | 多语言界面（中/英/韩/俄）、Docker 应用管理、备份还原、节点 URI 与二维码导出 |

**怎么选？**

| 场景 | 建议 |
|------|------|
| 只想快速起一个 Snell 节点 | 用本项目的一键脚本或 Docker 镜像 |
| 需要 Snell + 其他协议、443 复用、证书、流量限额 | 用 [PSM](https://github.com/jinqians/proxy-stack) |
| 本项目菜单里的 VLESS Reality / 流量管理 | 均已整合进 PSM |

---

## 协议介绍

### Snell

Snell 是 Surge 团队设计的轻量级加密代理协议，以极简的协议设计和加密传输兼顾隐私保护与传输性能。
目前** Surge/shadowrocket等 客户端支持** Snell。

### Snell v4 / v5 / v6 对比

| 特性 | Snell v4 | Snell v5 | Snell v6 (RC) |
|------|----------|----------|---------------|
| 状态 | 稳定版 | 稳定版 | 预发布（rc2） |
| QUIC Proxy | 不支持 | 支持 | 已移除 |
| Dynamic Record Sizing | 不支持 | 支持 | 支持 |
| 出口控制 (`egress-interface`) | 不支持 | 支持 | 支持 |
| 部署级协议多样性 | 不支持 | 不支持 | 支持（PSK 派生） |
| 加密模式 `mode` | 不支持 | 不支持 | `default` / `unshaped` / `unsafe-raw` |
| obfs 混淆 | 支持 `http` | 支持 `http` | 已移除 |
| `ipv6` 参数 | 支持 | 支持 | 已废弃，改用 `dns-ip-preference` |
| 多地址监听 | 不支持 | 不支持 | 支持（`listen` 逗号分隔） |
| armv7l 官方构建 | 提供 | 提供 | 不提供 |

选择建议：追求稳定选 **v5**（服务端 v5 同时兼容 v4 客户端），需要尝鲜 v6 特性再选 **v6**，老设备 / armv7 只能用 **v4 / v5**。

**客户端配置格式**

```text
# v4 / v5
HK = snell, 1.2.3.4, 6160, psk = your_psk, version = 5, reuse = true, tfo = true

# v6：mode 必须与服务端一致
HK = snell, 1.2.3.4, 6160, psk = your_psk, version = 6, mode = default, reuse = true, tfo = true
```

### ShadowTLS

ShadowTLS 是轻量级 TLS 伪装工具，把代理流量伪装成访问正常 HTTPS 站点的流量，用于提升隐蔽性与稳定性。本项目使用 **ShadowTLS v3**。

启用后 Snell 后端改为**仅监听 `127.0.0.1:Snell端口`**，客户端只连接 ShadowTLS 对外端口，原始 Snell 端口不再暴露在公网：

```
客户端 ──TLS 伪装──▶ ShadowTLS(:8443) ──明文──▶ Snell(127.0.0.1:6160)
```

```text
# Snell + ShadowTLS：端口填 ShadowTLS 端口
HK = snell, 1.2.3.4, 8443, psk = your_psk, version = 5, reuse = true, tfo = true, shadow-tls-password = your_stls_password, shadow-tls-sni = www.microsoft.com, shadow-tls-version = 3
```

---

## Surge 配置文件

仓库内提供一份可参考的 Surge 完整配置：[surge.conf](surge.conf)

```
https://raw.githubusercontent.com/jinqians/snell.sh/refs/heads/main/surge.conf
```

包含的内容：

| 段落 | 内容 |
|------|------|
| `[General]` | DNS、跳过代理、日志级别等基础参数 |
| `[Proxy]` | Snell v4 / v5、Snell + ShadowTLS、VMess 等节点写法示例 |
| `[Proxy Group]` | 策略组划分示例 |
| `[Rule]` | 常用分流规则 |
| `[URL Rewrite]` / `[MITM]` | 重写与 MITM 示例 |

> 配置中的服务器地址与 PSK 均为示例，使用前请替换成你自己的节点信息。

**手搓 Snell 教程**：[Snell v4 部署教程](https://vps.jinqians.com/snell-v4%e9%83%a8%e7%bd%b2%e6%95%99%e7%a8%8b/)

---

## 赞助

感谢以下赞助商对本项目的支持：

- 🥇 **[ZMTO](https://console.zmto.com/?affid=1567)** —— [ZMTO 测评](https://vps.jinqians.com/zmto/)

如果这个项目对你有帮助，欢迎点一个 ⭐ Star。

---

## 相关链接

- 作者网站：[jinqians.com](https://jinqians.com)
- PSM 项目：[jinqians/proxy-stack](https://github.com/jinqians/proxy-stack)
- Docker Hub：[jinqians/snell-server](https://hub.docker.com/r/jinqians/snell-server)
- 开源协议：[GPL-3.0](LICENSE)
