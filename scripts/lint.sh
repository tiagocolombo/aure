#!/usr/bin/env bash
# Lint: compile with warnings visible; run extension lint when present.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
root="$AURE_ROOT"

echo "==> swift build (warnings shown)"
apple swift build --package-path "$root/Packages/AureKit"

if command -v swift-format >/dev/null 2>&1; then
  apple swift-format lint --recursive "$root/Packages/AureKit/Sources" "$root/Packages/AureKit/Tests"
fi

if [ -f "$root/extension/chrome/package.json" ]; then
  (cd "$root/extension/chrome" && pnpm install --frozen-lockfile >/dev/null && pnpm lint)
fi
