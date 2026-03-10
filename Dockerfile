# =========================================
# Snell Server Docker 镜像
# 支持多架构: amd64 / arm64 / armv7
# =========================================

ARG SNELL_VERSION=v5.0.1

# 第一阶段: 使用 Debian 下载二进制并提供 glibc 运行时库
FROM debian:bookworm-slim AS builder

ARG SNELL_VERSION
ARG TARGETARCH

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl unzip ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 根据目标架构选择下载链接
RUN case "${TARGETARCH}" in \
        "amd64")  ARCH_SUFFIX="amd64" ;; \
        "arm64")  ARCH_SUFFIX="aarch64" ;; \
        "arm")    ARCH_SUFFIX="armv7l" ;; \
        *)        echo "Unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    curl -L -o snell.zip "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-${ARCH_SUFFIX}.zip" && \
    unzip -o snell.zip && \
    rm -f snell.zip && \
    chmod +x /app/snell-server

# 第二阶段: Alpine 最终镜像，注入 glibc 运行时
FROM alpine:3.19

ARG TARGETARCH

RUN apk add --no-cache ca-certificates

WORKDIR /app

COPY --from=builder /app/snell-server /app/snell-server

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

# 创建配置目录和 entrypoint 脚本
RUN mkdir -p /etc/snell

# 复制 entrypoint 脚本
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

EXPOSE 6160

ENTRYPOINT ["/app/entrypoint.sh"]

