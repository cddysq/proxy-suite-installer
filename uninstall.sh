#!/usr/bin/env bash
set -euo pipefail

[ -n "${HOME:-}" ] || { printf 'ERROR: $HOME is not set\n' >&2; exit 1; }

BIN_DIR="${BIN_DIR:-$HOME/bin}"

if [ -x "$BIN_DIR/proxy-uninstall" ]; then
  exec "$BIN_DIR/proxy-uninstall" "$@"
fi

echo "proxy-uninstall was not found in $BIN_DIR" >&2
echo "Nothing to uninstall from the current user profile." >&2
exit 1
