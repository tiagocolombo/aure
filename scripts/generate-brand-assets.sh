#!/usr/bin/env bash
# Regenerate checked-in assets from docs/assets/aure-logo.svg (macOS only).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
apple swift "$AURE_ROOT/scripts/generate-brand-assets.swift" "$AURE_ROOT"
apple iconutil -c icns "$AURE_ROOT/build/branding/AppIcon.iconset" -o "$AURE_ROOT/Resources/AppIcon.icns"
"$AURE_ROOT/scripts/test-brand-assets.sh"
