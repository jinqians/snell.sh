#!/usr/bin/env bash
# 把 src/ 下的脚本连同它们用到的 src/lib 合成单个文件，写到仓库根目录的同名文件。
# 用户 bash <(curl …) 下载的、短域名重定向到的、PSM 调用的都是根目录这些文件，
# 地址因此不变；改代码请改 src/，然后重新生成。
#
#   bash tools/build.sh          生成
#   bash tools/build.sh --check  只检查根目录的文件与 src/ 是否一致（不一致时退出码 1）
#
# src 里的写法：
#   SNELL_LIB=…  # @dev        只在直接运行 src/ 下的脚本时有用，合成时去掉
#   . "$SNELL_LIB/common.sh"  # @bundle   合成时换成 src/lib/common.sh 的内容
set -euo pipefail
cd "$(dirname "$0")/.."

# 发布文件:源文件
TARGETS=(
    "snell.sh:src/snell.sh"
    # CentOS / RHEL 与 Debian 用同一个脚本；旧的 snell-centos 地址继续可用
    "snell-centos.sh:src/snell.sh"
    "multi-user.sh:src/multi-user.sh"
    "shadowtls.sh:src/shadowtls.sh"
    "menu.sh:src/menu.sh"
    "snell-alpine.sh:src/snell-alpine.sh"
    "snell-docker.sh:src/snell-docker.sh"
)

bundle() {   # <源文件> → 标准输出
    local src="$1" line lib n=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        if (( n == 1 )); then
            printf '%s\n' "$line"
            printf '# 此文件由 tools/build.sh 从 %s 和 src/lib 生成：请修改 src/ 下的文件后重新生成。\n' "$src"
            continue
        fi
        [[ "$line" =~ \#\ @dev$ ]] && continue
        if [[ "$line" =~ ^\.\ \"\$SNELL_LIB/([a-z_-]+\.sh)\"[[:space:]]*\#\ @bundle$ ]]; then
            lib="src/lib/${BASH_REMATCH[1]}"
            [[ -f "$lib" ]] || { echo "$src:$n: 找不到 $lib" >&2; exit 1; }
            cat "$lib"
            printf '\n'
            continue
        fi
        if [[ "$line" == *'$SNELL_LIB'* ]]; then
            echo "$src:$n: 用到 \$SNELL_LIB 的行只能是 # @bundle 或 # @dev" >&2
            exit 1
        fi
        printf '%s\n' "$line"
    done < "$src"
}

check=false
[[ "${1:-}" == "--check" ]] && check=true
stale=0
for t in "${TARGETS[@]}"; do
    out="${t%%:*}" src="${t#*:}"
    if $check; then
        if ! diff -q <(bundle "$src") "$out" >/dev/null 2>&1; then
            echo "过期：$out（与 $src 不一致，运行 bash tools/build.sh）"
            stale=1
        fi
    else
        bundle "$src" > "$out.tmp"
        chmod 755 "$out.tmp"
        mv "$out.tmp" "$out"
        echo "生成 $out ← $src"
    fi
done
exit "$stale"
