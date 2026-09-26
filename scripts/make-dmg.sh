#!/usr/bin/env bash
# Package build/Aure.app into a drag-to-Applications DMG.
#
#   scripts/make-dmg.sh            # builds a universal release app first
#   AURE_SKIP_BUILD=1 scripts/make-dmg.sh   # package the existing build/Aure.app
#
# Output: dist/Aure-<version>.dmg
set -euo pipefail
. "$(dirname "$0")/lib.sh"
root="$AURE_ROOT"
app="$root/build/Aure.app"

if [ "${AURE_SKIP_BUILD:-0}" != 1 ]; then
  [ -x "$root/build/llama/llama-server" ] || "$root/scripts/build-llama.sh"
  "$root/scripts/build-app.sh" release
fi
[ -d "$app" ] || { echo "error: $app not found"; exit 1; }

version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
mkdir -p "$root/dist"
dmg="$root/dist/Aure-$version.dmg"
stage="$(mktemp -d)/Aure"
mkdir -p "$stage"

cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
cat > "$stage/READ ME FIRST.txt" <<'EOF'
Installing Aure
===============

1. Drag Aure onto the Applications folder.
2. Open Applications, right-click Aure and choose Open, then click Open.
   (Aure is signed for personal use and not notarized by Apple, so macOS
   asks for this once. Double-clicking works normally afterwards.)
3. Aure appears in the menu bar at the top of the screen. The setup window
   helps you download a model (about 0.5–2.5 GB, one time).

Everything runs on your Mac. Your text is never sent anywhere.
EOF

rm -f "$dmg"
echo "==> creating $dmg"
apple hdiutil create -volname "Aure $version" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
rm -rf "$(dirname "$stage")"

# Sign the DMG itself when a stable identity exists.
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Aure Local"'; then
  apple codesign --force --sign "Aure Local" "$dmg"
fi

apple hdiutil verify "$dmg" >/dev/null
echo "==> $(du -h "$dmg" | cut -f1)  $dmg"
