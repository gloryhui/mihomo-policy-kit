#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
for candidate in "${MPK_RUBY:-}" /opt/homebrew/opt/ruby/bin/ruby /usr/local/opt/ruby/bin/ruby "$(command -v ruby || true)"; do
  if [ -n "$candidate" ] && [ -x "$candidate" ] && "$candidate" -e 'exit(RUBY_VERSION.to_f >= 3.0 ? 0 : 1)' 2>/dev/null; then
    exec "$candidate" "$SCRIPT_DIR/generate-personal-config.rb" "$@"
  fi
done
echo '[ERROR] Ruby 3 or newer required. Install Ruby or set MPK_RUBY to its executable.' >&2
exit 1
