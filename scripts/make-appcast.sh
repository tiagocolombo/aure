#!/usr/bin/env bash
# Write dist/appcast.xml: the Sparkle feed for one release DMG, signed with
# the EdDSA private key in $SPARKLE_PRIVATE_KEY.
#
#   SPARKLE_PRIVATE_KEY=... scripts/make-appcast.sh dist/Aure-0.2.0.dmg 0.2.0 owner/repo
set -euo pipefail
. "$(dirname "$0")/lib.sh"
root="$AURE_ROOT"
dmg="$1" version="$2" repo="$3"
: "${SPARKLE_PRIVATE_KEY:?set SPARKLE_PRIVATE_KEY}"

sign_update="$(find "$root/Packages/AureKit/.build/artifacts" -path '*Sparkle/bin/sign_update' -type f | head -1)"
[ -x "$sign_update" ] || { echo "error: Sparkle's sign_update not found (build the package first)"; exit 1; }

key="$(mktemp)"
trap 'rm -f "$key"' EXIT
printf '%s' "$SPARKLE_PRIVATE_KEY" > "$key"
# Prints: sparkle:edSignature="..." length="..."
attrs="$("$sign_update" --ed-key-file "$key" "$dmg")"

name="$(basename "$dmg")"
url="https://github.com/$repo/releases/download/v$version/$name"
cat > "$root/dist/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Aure</title>
    <item>
      <title>Aure $version</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$version</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$repo/releases/tag/v$version</sparkle:fullReleaseNotesLink>
      <enclosure url="$url" type="application/octet-stream" $attrs />
    </item>
  </channel>
</rss>
EOF
echo "==> wrote $root/dist/appcast.xml"
