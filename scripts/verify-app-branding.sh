#!/usr/bin/env bash
# Verify branding survived packaging; also works on an installed or mounted app.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
app="${1:-$AURE_ROOT/build/Aure.app}"
resources="$app/Contents/Resources"
icon="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIconFile' "$app/Contents/Info.plist")"
[ "$icon" = AppIcon ] || { echo "error: unexpected CFBundleIconFile: $icon"; exit 1; }
cmp "$AURE_ROOT/Resources/AppIcon.icns" "$resources/AppIcon.icns"
# Newer SwiftPM toolchains emit a full bundle layout (Contents/Resources/...);
# older ones keep the resources at the bundle root.
bundle="$resources/AureKit_AureUI.bundle"
for name in AureLogo.png AureMenuBar.png; do
  packaged="$bundle/Resources/$name"
  [ -f "$packaged" ] || packaged="$bundle/Contents/Resources/Resources/$name"
  cmp "$AURE_ROOT/Packages/AureKit/Sources/AureUI/Resources/$name" "$packaged"
done
apple codesign --verify --deep --strict "$app"
echo "==> verified app icon, UI branding resources, and signature: $app"
