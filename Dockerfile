# syntax=docker/dockerfile:1.7
# =========================================
# Snell Server Docker 镜像
# 支持多架构: amd64 / arm64 / armv7
# 注意: Snell v6 仅支持 amd64 / arm64，不支持 armv7
# =========================================

ARG SNELL_VERSION=v5.0.1
ARG SNELL_VER=v5
ARG SHADOWTLS_VERSION=v0.2.25
ARG BUILD_CREATED

# 第一阶段: 使用 Debian 下载二进制并提供 glibc 运行时库
FROM debian:bookworm-slim AS builder

ARG SNELL_VERSION
ARG TARGETARCH
ARG SHADOWTLS_VERSION

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl unzip ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 根据目标架构选择下载链接 (Snell v6 不支持 arm/armv7l)
RUN case "${TARGETARCH}" in \
        "amd64")  ARCH_SUFFIX="amd64" ;; \
        "arm64")  ARCH_SUFFIX="aarch64" ;; \
        "arm")    case "${SNELL_VERSION}" in \
                      v6*) echo "Error: Snell v6 does not support armv7l architecture" && exit 1 ;; \
                      *)   ARCH_SUFFIX="armv7l" ;; \
                  esac ;; \
        *)        echo "Unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    curl -L -o snell.zip "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-${ARCH_SUFFIX}.zip" && \
    unzip -o snell.zip && \
    rm -f snell.zip && \
    chmod +x /app/snell-server

RUN case "${TARGETARCH}" in \
        "amd64")  SHADOWTLS_ARCH="x86_64-unknown-linux-musl" ;; \
        "arm64")  SHADOWTLS_ARCH="aarch64-unknown-linux-musl" ;; \
        "arm")    SHADOWTLS_ARCH="armv7-unknown-linux-musleabihf" ;; \
        *)        echo "Unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    curl -L -o /app/shadow-tls "https://github.com/ihciah/shadow-tls/releases/download/${SHADOWTLS_VERSION}/shadow-tls-${SHADOWTLS_ARCH}" && \
    chmod +x /app/shadow-tls

# 第二阶段: Alpine 最终镜像，注入 glibc 运行时
FROM alpine:3.19

ARG TARGETARCH
ARG SNELL_VERSION
ARG SNELL_VER
ARG SHADOWTLS_VERSION
ARG BUILD_CREATED

RUN apk add --no-cache ca-certificates iproute2

WORKDIR /app

COPY --from=builder /app/snell-server /app/snell-server
COPY --from=builder /app/shadow-tls /app/shadow-tls

# 根据架构拷贝正确的 glibc 动态库并创建链接
# 注意: libstdc++ 在 Debian 中位于 /usr/lib/ 而非 /lib/，需要同时挂载
RUN --mount=from=builder,source=/lib,target=/mnt/lib \
    --mount=from=builder,source=/usr/lib,target=/mnt/usr/lib \
    case "${TARGETARCH}" in \
        "amd64") \
            mkdir -p /usr/glibc-compat/lib /lib64 && \
            cp -a /mnt/lib/x86_64-linux-gnu/libc.so* /mnt/lib/x86_64-linux-gnu/libm.so* \
                  /mnt/lib/x86_64-linux-gnu/libpthread.so* /mnt/lib/x86_64-linux-gnu/libdl.so* \
                  /mnt/lib/x86_64-linux-gnu/librt.so* /mnt/lib/x86_64-linux-gnu/libgcc_s.so* \
                  /mnt/lib/x86_64-linux-gnu/libresolv.so* /mnt/lib/x86_64-linux-gnu/libnss_dns.so* \
                  /mnt/lib/x86_64-linux-gnu/libnss_files.so* \
                  /usr/glibc-compat/lib/ 2>/dev/null; \
            cp -a /mnt/usr/lib/x86_64-linux-gnu/libstdc++.so* /usr/glibc-compat/lib/ 2>/dev/null; \
            cp -a /mnt/lib/x86_64-linux-gnu/ld-linux-x86-64.so* /usr/glibc-compat/lib/ 2>/dev/null; \
            ln -sf /usr/glibc-compat/lib/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2 ;; \
        "arm64") \
            mkdir -p /usr/glibc-compat/lib && \
            cp -a /mnt/lib/aarch64-linux-gnu/libc.so* /mnt/lib/aarch64-linux-gnu/libm.so* \
                  /mnt/lib/aarch64-linux-gnu/libpthread.so* /mnt/lib/aarch64-linux-gnu/libdl.so* \
                  /mnt/lib/aarch64-linux-gnu/librt.so* /mnt/lib/aarch64-linux-gnu/libgcc_s.so* \
                  /mnt/lib/aarch64-linux-gnu/libresolv.so* /mnt/lib/aarch64-linux-gnu/libnss_dns.so* \
                  /mnt/lib/aarch64-linux-gnu/libnss_files.so* \
                  /usr/glibc-compat/lib/ 2>/dev/null; \
            cp -a /mnt/usr/lib/aarch64-linux-gnu/libstdc++.so* /usr/glibc-compat/lib/ 2>/dev/null; \
            cp -a /mnt/lib/aarch64-linux-gnu/ld-linux-aarch64.so* /usr/glibc-compat/lib/ 2>/dev/null; \
            ln -sf /usr/glibc-compat/lib/ld-linux-aarch64.so.1 /lib/ld-linux-aarch64.so.1 ;; \
        "arm") \
            mkdir -p /usr/glibc-compat/lib && \
            cp -a /mnt/lib/arm-linux-gnueabihf/libc.so* /mnt/lib/arm-linux-gnueabihf/libm.so* \
                  /mnt/lib/arm-linux-gnueabihf/libpthread.so* /mnt/lib/arm-linux-gnueabihf/libdl.so* \
                  /mnt/lib/arm-linux-gnueabihf/librt.so* /mnt/lib/arm-linux-gnueabihf/libgcc_s.so* \
                  /mnt/lib/arm-linux-gnueabihf/libresolv.so* /mnt/lib/arm-linux-gnueabihf/libnss_dns.so* \
                  /mnt/lib/arm-linux-gnueabihf/libnss_files.so* \
                  /usr/glibc-compat/lib/ 2>/dev/null; \
            cp -a /mnt/usr/lib/arm-linux-gnueabihf/libstdc++.so* /usr/glibc-compat/lib/ 2>/dev/null; \
            cp -a /mnt/lib/arm-linux-gnueabihf/ld-linux-armhf.so* /usr/glibc-compat/lib/ 2>/dev/null; \
            ln -sf /usr/glibc-compat/lib/ld-linux-armhf.so.3 /lib/ld-linux-armhf.so.3 ;; \
    esac

ENV LD_LIBRARY_PATH=/usr/glibc-compat/lib
ENV SNELL_VER=${SNELL_VER}

LABEL org.opencontainers.image.title="Snell Server" \
      org.opencontainers.image.version="${SNELL_VERSION}" \
      org.opencontainers.image.created="${BUILD_CREATED}" \
      org.opencontainers.image.source="https://github.com/jinqians/snell.sh"

# 创建配置目录（nobody 可写，供 entrypoint 首次启动时生成配置）
RUN mkdir -p /etc/snell && chown nobody:nogroup /etc/snell

# 复制 entrypoint 脚本
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

EXPOSE 6160/tcp 6160/udp 8443/tcp

# 以非特权用户运行：Snell 默认监听 6160/8443 高位端口，无需 root
USER nobody

# 健康检查：从配置文件解析实际监听端口，确认其处于 LISTEN 状态
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD sh -c 'p=$(sed -n "s/.*:\([0-9][0-9]*\)[[:space:]]*$/\1/p" /etc/snell/snell-server.conf | tail -n 1); p=${p:-6160}; ss -tln | grep -q ":$p " || exit 1'

ENTRYPOINT ["/app/entrypoint.sh"]
