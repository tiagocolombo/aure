#!/usr/bin/env bash
# Run every test suite: Swift package, then the Chrome extension (when present).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
root="$AURE_ROOT"

echo "==> swift test (Packages/AureKit)"
apple swift test --package-path "$root/Packages/AureKit" "$@"

if [ -f "$root/extension/chrome/package.json" ]; then
  echo "==> extension tests"
  (cd "$root/extension/chrome" && pnpm install --frozen-lockfile >/dev/null && pnpm test)
fi
