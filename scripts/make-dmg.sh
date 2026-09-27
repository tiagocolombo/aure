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
"$root/scripts/verify-app-branding.sh" "$app"

version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
mkdir -p "$root/dist"
dmg="$root/dist/Aure-$version.dmg"
work="$(mktemp -d)"
stage="$work/Aure"
mount="$work/mounted"
mounted=0
cleanup() {
  if [ "$mounted" = 1 ]; then apple hdiutil detach "$mount" >/dev/null 2>&1 || return; fi
  rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$stage"

cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
# Finder uses this icon for the mounted installation volume.
cp "$app/Contents/Resources/AppIcon.icns" "$stage/.VolumeIcon.icns"

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
# hdiutil does not preserve the staging directory's custom-icon flag on the
# volume root. Set it on the mounted writable image before compressing.
apple hdiutil create -volname "Aure $version" -srcfolder "$stage" -fs HFS+ -format UDRW "$work/writable.dmg" >/dev/null
apple hdiutil attach -nobrowse -mountpoint "$mount" "$work/writable.dmg" >/dev/null
mounted=1
apple xcrun SetFile -a C "$mount"
apple hdiutil detach "$mount" >/dev/null
mounted=0
apple hdiutil convert "$work/writable.dmg" -format UDZO -o "$dmg" >/dev/null

# Sign the DMG itself when a stable identity exists.
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Aure Local"'; then
  apple codesign --force --sign "Aure Local" "$dmg"
fi

apple hdiutil verify "$dmg" >/dev/null
apple hdiutil attach -readonly -nobrowse -mountpoint "$mount" "$dmg" >/dev/null
mounted=1
"$root/scripts/verify-app-branding.sh" "$mount/Aure.app"
cmp "$app/Contents/Resources/AppIcon.icns" "$mount/.VolumeIcon.icns"
case "$(apple xcrun GetFileInfo -a "$mount")" in
  *C*) ;;
  *) echo "error: mounted installer is missing its custom-icon flag"; exit 1 ;;
esac
apple hdiutil detach "$mount" >/dev/null
mounted=0
echo "==> $(du -h "$dmg" | cut -f1)  $dmg"
