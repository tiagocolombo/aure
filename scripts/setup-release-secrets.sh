#!/usr/bin/env bash
# One-time maintainer setup for automatic releases (.github/workflows/release.yml).
#
#   1. Creates the "Aure Local" code-signing identity (scripts/bootstrap.sh) and
#      stores it as the AURE_SIGNING_P12 / AURE_SIGNING_P12_PASSWORD secrets, so
#      every release has the same signature and keeps macOS permissions.
#   2. Creates a Sparkle EdDSA key pair in your login keychain, stores the
#      private key as SPARKLE_PRIVATE_KEY and writes the public key into
#      Resources/Info.plist (commit that change).
#
# Needs: gh (logged in, admin on the repo) and a built package
# (scripts/test.sh or scripts/build-app.sh) so Sparkle's tools exist.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
root="$AURE_ROOT"
repo="${AURE_REPO:-tiagocolombo/aure}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if security find-identity -v -p codesigning | grep -q '"Aure Local"'; then
  cat <<EOF
error: an "Aure Local" identity already exists, and its private key can only be
exported from Keychain Access. Export it there (right-click > Export, .p12, with
a password), then run:
  base64 -i Aure.p12 | gh secret set AURE_SIGNING_P12 --repo $repo
  gh secret set AURE_SIGNING_P12_PASSWORD --repo $repo
and re-run this script with AURE_SKIP_SIGNING=1.
EOF
  [ "${AURE_SKIP_SIGNING:-0}" = 1 ] || exit 1
else
  AURE_P12_OUT="$tmp/aure.p12" "$root/scripts/bootstrap.sh"
  base64 -i "$tmp/aure.p12" | gh secret set AURE_SIGNING_P12 --repo "$repo"
  gh secret set AURE_SIGNING_P12_PASSWORD --repo "$repo" < "$tmp/aure.p12.password"
  echo "==> stored AURE_SIGNING_P12 and AURE_SIGNING_P12_PASSWORD"
fi

bin="$(find "$root/Packages/AureKit/.build/artifacts" -path '*Sparkle/bin' -type d | head -1)"
[ -n "$bin" ] || { echo "error: Sparkle tools not found; build the package first"; exit 1; }
# Creates the key in the login keychain on first run and prints the public key.
"$bin/generate_keys" >/dev/null
public="$("$bin/generate_keys" -p)"
"$bin/generate_keys" -x "$tmp/sparkle.key"
gh secret set SPARKLE_PRIVATE_KEY --repo "$repo" < "$tmp/sparkle.key"
sed -i '' "s|<key>SUPublicEDKey</key><string>[^<]*</string>|<key>SUPublicEDKey</key><string>$public</string>|" \
  "$root/Resources/Info.plist"
echo "==> stored SPARKLE_PRIVATE_KEY; public key written to Resources/Info.plist: $public"
echo "    The private key also stays in your login keychain. Back it up: losing it means"
echo "    installed copies can no longer verify updates."
