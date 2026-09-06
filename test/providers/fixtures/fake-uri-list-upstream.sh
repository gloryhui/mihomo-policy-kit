#!/bin/bash
# Fake upstream that accepts a base64-decoded URI list (vless:// / ss:// / trojan://)
# and produces a minimal Mihomo YAML, so offline E2E can exercise the uri_list
# source path without needing the real Smart-Config-Kit Ruby runtime.
source /usr/share/openclash/log.sh
VERSION_TAG="oc-normal-2026.01"
TARGET="${1:-}"
echo "[fake-uri-list] transforming $TARGET"
if [ -n "$TARGET" ] && [ -f "$TARGET" ]; then
  NODES=$(grep -c '://' "$TARGET" || true)
  cat > "$TARGET" <<YAML
proxies:
  - name: Fake-US-01
    type: vless
    server: 127.0.0.1
    port: 443
    uuid: 00000000-0000-0000-0000-000000000000
    network: tcp
    tls: true
    client-fingerprint: chrome
proxy-groups:
  - name: "🌍 全球节点"
    type: select
    proxies: [Fake-US-01]
rules:
  - MATCH,"🌍 全球节点"
YAML
  echo "[fake-uri-list] consumed ${NODES} uri lines"
fi