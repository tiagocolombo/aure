#!/usr/bin/env bash
# Sign Aure.app inside-out with the hardened runtime.
# Identity: $AURE_SIGN_IDENTITY, else "Aure Local" if present, else ad-hoc.
set -euo pipefail
app="$1"
. "$(dirname "$0")/lib.sh"
root="$AURE_ROOT"
ent="$root/Resources/Aure.entitlements"

identity="${AURE_SIGN_IDENTITY:-}"
if [ -z "$identity" ]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Aure Local"'; then
    identity="Aure Local"
  else
    identity="-"
    echo "warning: signing ad-hoc. Run scripts/bootstrap.sh once to create the stable 'Aure Local' identity,"
    echo "         otherwise macOS asks for Accessibility permission again after every build."
  fi
fi

opts=(--force --options runtime --sign "$identity")
[ "$identity" != "-" ] && opts+=(--timestamp=none)

for h in "$app"/Contents/Helpers/*; do
  if [ -f "$h" ]; then apple codesign "${opts[@]}" "$h"; fi
done

# Sparkle, inside-out as its documentation describes (never --deep).
sparkle="$app/Contents/Frameworks/Sparkle.framework"
if [ -d "$sparkle" ]; then
  b="$sparkle/Versions/B"
  apple codesign "${opts[@]}" "$b/XPCServices/Installer.xpc"
  apple codesign "${opts[@]}" --preserve-metadata=entitlements "$b/XPCServices/Downloader.xpc"
  apple codesign "${opts[@]}" "$b/Autoupdate"
  apple codesign "${opts[@]}" "$b/Updater.app"
  apple codesign "${opts[@]}" "$sparkle"
fi
apple codesign "${opts[@]}" --entitlements "$ent" "$app"
apple codesign --verify --deep --strict "$app"
echo "==> signed with: $identity"
