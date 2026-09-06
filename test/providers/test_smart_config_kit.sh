#!/usr/bin/env bash
set -euo pipefail

# Offline integration tests for providers/smart-config-kit/provider.sh
# Uses self-contained fake upstream scripts; never touches the network or real subscriptions.

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
PROVIDER="$ROOT_DIR/providers/smart-config-kit/provider.sh"
FIXTURES="$ROOT_DIR/test/providers/fixtures"
FAILED=0

tmpdir() { mktemp -d 2>/dev/null || mktemp -d -t mpk-provider-test; }

assert() {
  local desc="$1"; shift
  if "$@"; then
    echo "ok - $desc"
  else
    echo "FAIL - $desc" >&2
    FAILED=1
  fi
}

write_source_yaml() {
  local f="$1"
  cat > "$f" <<YAML
proxies:
  - name: Source-A
    type: ss
    server: 127.0.0.1
    port: 8443
    cipher: aes-128-gcm
    password: fake
YAML
}

echo "== provider wrapper offline tests =="

# 1) local upstream is preferred
T1="$(tmpdir)"; trap 'rm -rf "$T1"' EXIT
write_source_yaml "$T1/source.yaml"
OUT="$(MPK_PROVIDER_LOCAL="$FIXTURES/fake-normal-upstream.sh" bash "$PROVIDER" "$T1/source.yaml" 2>&1 || true)"
assert "local upstream preferred" grep -q "use local upstream" <<< "$OUT"
assert "local upstream transforms proxies" grep -q "Fake-US-01" "$T1/source.yaml"
assert "oc-normal accepted" bash -c "echo '$OUT' | grep -q 'VERSION_TAG=oc-normal-2026.01' || echo '$OUT' | grep -q 'oc-normal-2026.01'"
assert "node client-fingerprint preserved after provider" grep -q "client-fingerprint: chrome" "$T1/source.yaml"
assert "provider leaves proxies non-empty" grep -q "name: Fake-US-01" "$T1/source.yaml"

# 2) smart upstream is refused
T2="$(tmpdir)"; trap 'rm -rf "$T2"' EXIT
write_source_yaml "$T2/source.yaml"
OUT2="$(MPK_PROVIDER_LOCAL="$FIXTURES/fake-smart-upstream.sh" bash "$PROVIDER" "$T2/source.yaml" 2>&1 || true)"
assert "smart upstream refused" bash -c "echo '$OUT2' | grep -q 'refusing non-Normal'"
assert "smart upstream leaves source intact" grep -q "Source-A" "$T2/source.yaml"

# 3) missing version tag refused
T3="$(tmpdir)"; trap 'rm -rf "$T3"' EXIT
write_source_yaml "$T3/source.yaml"
OUT3="$(MPK_PROVIDER_LOCAL="$FIXTURES/fake-noversion-upstream.sh" bash "$PROVIDER" "$T3/source.yaml" 2>&1 || true)"
assert "missing VERSION_TAG refused" bash -c "echo '$OUT3' | grep -q 'VERSION_TAG not found'"

# 4) openclash log dependency patched: patched script runs without /usr/share/openclash/log.sh
T4="$(tmpdir)"; trap 'rm -rf "$T4"' EXIT
write_source_yaml "$T4/source.yaml"
OUT4="$(MPK_PROVIDER_LOCAL="$FIXTURES/fake-normal-upstream.sh" bash "$PROVIDER" "$T4/source.yaml" 2>&1)"
assert "patched script completes transform" bash -c "echo '$OUT4' | grep -q 'provider transform completed'"
assert "no residual log.sh path in source" bash -c "! grep -q '/usr/share/openclash/log.sh' '$T4/source.yaml'"

# 5) failing provider is not reported as success
T5="$(tmpdir)"; trap 'rm -rf "$T5"' EXIT
write_source_yaml "$T5/source.yaml"
if MPK_PROVIDER_LOCAL="$FIXTURES/fake-failing-upstream.sh" bash "$PROVIDER" "$T5/source.yaml" >/dev/null 2>&1; then
  echo "FAIL - failing provider reported success" >&2
  FAILED=1
else
  echo "ok - failing provider is not reported as success"
fi
assert "failed provider leaves source intact" grep -q "Source-A" "$T5/source.yaml"

rm -rf "$T1" "$T2" "$T3" "$T4" "$T5"
trap - EXIT

if [ "$FAILED" -ne 0 ]; then
  echo "provider tests FAILED" >&2
  exit 1
fi
echo "provider tests OK"