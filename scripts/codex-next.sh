#!/usr/bin/env bash
set -euo pipefail

REPO="${MPK_REPO:-gloryhui/mihomo-policy-kit}"

if ! command -v gh >/dev/null 2>&1; then
  echo "[codex-next] gh CLI not found" >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "[codex-next] gh is not authenticated" >&2
  exit 1
fi

json="$(gh issue list \
  --repo "$REPO" \
  --state open \
  --search '"[READY]" in:title' \
  --limit 100 \
  --json number,title,url,createdAt)"

if [ "$json" = "[]" ]; then
  echo "[codex-next] no READY task"
  exit 3
fi

ruby -rjson -e '
issues = JSON.parse(STDIN.read)
issues.sort_by! { |i| [i.fetch("createdAt", ""), i.fetch("number")] }
i = issues.first
puts "NEXT_ISSUE=#{i.fetch("number")}" 
puts "TITLE=#{i.fetch("title")}" 
puts "URL=#{i.fetch("url")}" 
puts
puts "Run:"
puts "  gh issue view #{i.fetch("number")} --repo '"$REPO"'"
' <<< "$json"
