#!/usr/bin/env bash
# Build Aure.app from the Swift package (no Xcode project needed).
#
#   scripts/build-app.sh [debug|release]      default: release
#
# Output: build/Aure.app
# - universal (arm64 + x86_64) when both slices build; set AURE_ARCHS=native
#   to build only for this machine (faster during development).
# - embeds build/llama/llama-server into Contents/Helpers when it exists
#   (run scripts/build-llama.sh first).
# - signs with the stable "Aure Local" identity when it exists in the
#   keychain (scripts/bootstrap.sh creates it), else ad-hoc with a warning:
#   ad-hoc signatures change every build, so macOS forgets the Accessibility
#   permission.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
root="$AURE_ROOT"
config="${1:-release}"
pkg="$root/Packages/AureKit"
out="$root/build"
app="$out/Aure.app"
archs="${AURE_ARCHS:-universal}"
version="$(sed -n 's/.*string = "\(.*\)".*/\1/p' "$pkg/Sources/AureCore/AureCore.swift")"

# Branding is required, not an optional copy that silently ships a generic icon.
"$root/scripts/test-brand-assets.sh"

# `swift build --arch a --arch b` needs full Xcode (xcbuild), so build each
# slice with its own triple and join them with lipo. Works with only the
# Command Line Tools.
if [ "$archs" = "universal" ]; then
  triples=(arm64-apple-macosx14.0 x86_64-apple-macosx14.0)
else
  triples=("$(uname -m)-apple-macosx14.0")
fi

slices=()
for t in "${triples[@]}"; do
  echo "==> swift build -c $config --triple $t"
  apple swift build --package-path "$pkg" -c "$config" --triple "$t" --product Aure
  bin_dir="$(apple swift build --package-path "$pkg" -c "$config" --triple "$t" --show-bin-path)"
  slices+=("$bin_dir/Aure")
done

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Helpers"
apple lipo -create "${slices[@]}" -output "$app/Contents/MacOS/Aure"

# SwiftPM resource bundles (Bundle.module) must sit next to the executable's
# resources for a packaged .app.
# (Resource bundles are architecture-independent; take them from the last slice.)
for b in "$bin_dir"/*.bundle; do
  if [ -e "$b" ]; then cp -R "$b" "$app/Contents/Resources/"; fi
done

sed "s/__VERSION__/$version/g" "$root/Resources/Info.plist" > "$app/Contents/Info.plist"
cp "$root/Resources/AppIcon.icns" "$app/Contents/Resources/"

if [ -x "$root/build/llama/llama-server" ]; then
  cp "$root/build/llama/llama-server" "$app/Contents/Helpers/llama-server"
else
  echo "warning: build/llama/llama-server missing — run scripts/build-llama.sh (the app will look for llama-server on PATH)"
fi

"$root/scripts/sign-app.sh" "$app"
"$root/scripts/verify-app-branding.sh" "$app"
echo "==> built $app"
