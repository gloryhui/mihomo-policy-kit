#!/bin/bash
# Preserving fake upstream: keeps source proxies / dns / fingerprint and
# prepends a provider-style rule, approximating Smart-Config-Kit Normal output.
source /usr/share/openclash/log.sh
VERSION_TAG="oc-normal-2026.01"
TARGET="${1:-}"
echo "[fake-preserving] transforming $TARGET"
if [ -n "$TARGET" ] && [ -f "$TARGET" ]; then
  sed -i '0,/^rules:/s//rules:\n  - DOMAIN-SUFFIX,provider-tracked.example,global/' "$TARGET"
fi