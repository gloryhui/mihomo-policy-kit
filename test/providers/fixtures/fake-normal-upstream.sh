#!/bin/bash
source /usr/share/openclash/log.sh
# fake Smart-Config-Kit Normal upstream for offline tests only
VERSION_TAG="oc-normal-2026.01"
TARGET="${1:-}"
echo "[fake-upstream] transforming $TARGET"
if [ -n "$TARGET" ] && [ -f "$TARGET" ]; then
  cat > "$TARGET" <<YAML
proxies:
  - name: Fake-US-01
    type: ss
    server: 127.0.0.1
    port: 8443
    cipher: aes-128-gcm
    password: fake
    client-fingerprint: chrome
proxy-groups:
  - name: GLOBAL
    type: select
    proxies: [Fake-US-01]
rules:
  - MATCH,GLOBAL
YAML
fi
