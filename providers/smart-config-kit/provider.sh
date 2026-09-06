#!/usr/bin/env bash
set -euo pipefail

TARGET_FILE="${1:-}"
if [ -z "$TARGET_FILE" ]; then
  echo "usage: provider.sh <mihomo.yaml>" >&2
  exit 2
fi

if [ ! -f "$TARGET_FILE" ]; then
  echo "[provider:smart-config-kit] target not found: $TARGET_FILE" >&2
  exit 1
fi

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
LOCAL_SCRIPT="${MPK_PROVIDER_LOCAL:-$ROOT_DIR/vendor/OpenClash(mihomo).sh}"
REMOTE_URL="${MPK_PROVIDER_REMOTE:-https://raw.githubusercontent.com/IvanSolis1989/Smart-Config-Kit/main/OpenClash/OpenClash%28mihomo%29.sh}"

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t mpk-scki)"
UPSTREAM_SCRIPT="$TMP_DIR/OpenClash(mihomo).sh"
PATCHED_SCRIPT="$TMP_DIR/provider-normal.sh"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

if [ -s "$LOCAL_SCRIPT" ]; then
  echo "[provider:smart-config-kit] use local upstream: $LOCAL_SCRIPT"
  cp -p "$LOCAL_SCRIPT" "$UPSTREAM_SCRIPT"
else
  echo "[provider:smart-config-kit] local upstream missing; downloading official Normal script"
  curl -fL --connect-timeout 15 --retry 3 --retry-delay 2 \
    "$REMOTE_URL" -o "$UPSTREAM_SCRIPT"
fi

if [ ! -s "$UPSTREAM_SCRIPT" ]; then
  echo "[provider:smart-config-kit] upstream script is empty" >&2
  exit 1
fi

VERSION_LINE="$(grep -m1 '^VERSION_TAG=' "$UPSTREAM_SCRIPT" || true)"
if [ -z "$VERSION_LINE" ]; then
  echo "[provider:smart-config-kit] upstream VERSION_TAG not found" >&2
  exit 1
fi

case "$VERSION_LINE" in
  *oc-normal*) ;;
  *)
    echo "[provider:smart-config-kit] refusing non-Normal upstream: $VERSION_LINE" >&2
    exit 1
    ;;
esac

echo "[provider:smart-config-kit] $VERSION_LINE"

# Smart-Config-Kit 的 OpenClash 入口仅有一个 OpenClash 日志依赖。
# 在中央构建机上替换为兼容 LOG_OUT，保持上游转换逻辑本身不变。
awk '
  NR == 2 && $0 ~ /\/usr\/share\/openclash\/log\.sh/ {
    print "LOG_OUT() { local level=\"$1\"; shift || true; printf \"[SCKI][%s] %s\\n\" \"$level\" \"$*\" >&2; }"
    next
  }
  { print }
' "$UPSTREAM_SCRIPT" > "$PATCHED_SCRIPT"
chmod +x "$PATCHED_SCRIPT"

if grep -q '/usr/share/openclash/log.sh' "$PATCHED_SCRIPT"; then
  echo "[provider:smart-config-kit] OpenClash log dependency patch failed" >&2
  exit 1
fi

# adaptive 与上游 OpenClash Normal 默认行为一致。
export SCKI_SUBSCRIPTION_ADAPTER_PROFILE="${SCKI_SUBSCRIPTION_ADAPTER_PROFILE:-adaptive}"

bash "$PATCHED_SCRIPT" "$TARGET_FILE"

echo "[provider:smart-config-kit] provider transform completed"
