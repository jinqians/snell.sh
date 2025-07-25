#!/bin/sh

# ==============================================================================
# - 采用更安全的“下载到本地再执行”模式。
# - 自动清理临时文件。
# - 强制 Root 执行，并自动安装依赖。
# ==============================================================================

# --- 0. 清理机制 ---
# 使用 trap 命令，确保脚本在任何情况下退出时（正常结束、出错、被中断），
# 都能自动删除临时文件。$$ 代表当前脚本的进程ID。
TMP_FILE="/tmp/install_payload_$$"
trap 'rm -f "$TMP_FILE"' EXIT

# --- 1. 权限检查 ---
if [ "$(id -u)" -ne 0 ]; then
  echo "错误：此脚本必须以 root 用户身份运行。" >&2
  exit 1
fi

# --- 2. 操作系统检测 ---
OS_FAMILY=""
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_ID=$(echo "$ID" | tr '[:upper:]' '[:lower:]')
  ID_LIKE=$(echo "$ID_LIKE" | tr '[:upper:]' '[:lower:]')
  if echo "$ID_LIKE" | grep -q "debian" || [ "$OS_ID" = "debian" ] || [ "$OS_ID" = "ubuntu" ]; then
    OS_FAMILY="debian"
  elif echo "$ID_LIKE" | grep -q "rhel" || echo "$ID_LIKE" | grep -q "centos" || [ "$OS_ID" = "centos" ] || [ "$OS_ID" = "rhel" ] || [ "$OS_ID" = "fedora" ]; then
    OS_FAMILY="rhel"
  elif [ "$OS_ID" = "alpine" ]; then
    OS_FAMILY="alpine"
  fi
fi
if [ -z "$OS_FAMILY" ]; then
  echo "错误：无法确定操作系统类型。" >&2; exit 1;
fi

# --- 3. 依赖自检与自动安装 ---
ensure_packages() {
  for pkg in "$@"; do
    if ! command -v "$pkg" >/dev/null 2>&1; then
      echo "--> 未找到命令 '$pkg'，正在尝试自动安装..."
      case "$OS_FAMILY" in
        debian) apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq "$pkg" ;;
        rhel) if command -v dnf >/dev/null 2>&1; then dnf install -y "$pkg"; else yum install -y "$pkg"; fi ;;
        alpine) apk add --no-cache "$pkg" ;;
      esac
      if ! command -v "$pkg" >/dev/null 2>&1; then
        echo "错误：自动安装 '$pkg' 失败，请手动安装后重试。" >&2; exit 1;
      else
        echo "--> '$pkg' 安装成功。";
      fi
    fi
  done
}

# --- 4. 执行主逻辑 ---
ensure_packages "curl"

DEBIAN_URL="http://snell.jinqians.com"
CENTOS_URL="http://snell-centos.jinqians.com"
ALPINE_URL="http://snell-alpine.jinqians.com"

main() {
  url=$1
  os_name=$2
  shell_to_use=$3

  echo "--------------------------------------------------"
  echo "系统类型: $os_name"
  echo "远程脚本: $url"
  echo "操作模式: 下载脚本到 $TMP_FILE 后再执行"
  echo "--------------------------------------------------"
  printf "您确定要继续吗? [y/N]: "
  read -r choice

  case "$choice" in
    y|Y)
      echo "--> 正在下载脚本到 $TMP_FILE ..."
      # 使用 -o 选项将内容输出到文件，-f 选项让 curl 在服务器出错时静默失败
      if ! curl -sSL -f -o "$TMP_FILE" "$url"; then
        echo "错误：下载脚本失败，请检查 URL 或网络连接。" >&2
        # trap 会自动清理失败下载的空文件
        exit 1
      fi

      echo "--> 下载完成。正在赋予执行权限..."
      chmod +x "$TMP_FILE"

      echo "--> 正在执行本地脚本 $TMP_FILE ..."
      # 直接执行本地脚本
      "$TMP_FILE"
      echo "--> 本地脚本执行完毕。"
      ;;
    *)
      echo "--> 操作已取消。"
      exit 0
      ;;
  esac
}

case "$OS_FAMILY" in
  debian) main "$DEBIAN_URL" "Debian/Ubuntu" "bash" ;;
  rhel)   main "$CENTOS_URL" "CentOS/RHEL" "bash" ;;
  alpine) main "$ALPINE_URL" "Alpine" "sh" ;;
esac

# trap 会在脚本最后一步执行，清理文件
exit 0
