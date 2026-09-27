#!/usr/bin/env bash
# Verify branding survived packaging; also works on an installed or mounted app.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
app="${1:-$AURE_ROOT/build/Aure.app}"
resources="$app/Contents/Resources"
icon="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIconFile' "$app/Contents/Info.plist")"
[ "$icon" = AppIcon ] || { echo "error: unexpected CFBundleIconFile: $icon"; exit 1; }
cmp "$AURE_ROOT/Resources/AppIcon.icns" "$resources/AppIcon.icns"
for name in AureLogo.png AureMenuBar.png; do
  cmp "$AURE_ROOT/Packages/AureKit/Sources/AureUI/Resources/$name" \
      "$resources/AureKit_AureUI.bundle/Resources/$name"
done
apple codesign --verify --deep --strict "$app"
echo "==> verified app icon, UI branding resources, and signature: $app"
