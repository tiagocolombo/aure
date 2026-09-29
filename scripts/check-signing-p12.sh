#!/usr/bin/env bash
# Check that a .p12 imports as a code-signing identity the way the release
# workflow imports it (.github/workflows/release.yml), before uploading it as
# AURE_SIGNING_P12. Asks for the .p12 password; prints names and hashes only.
# (`security import` only takes the password as an argument, so it is briefly
# visible to other accounts on this Mac through ps.)
#
#   scripts/check-signing-p12.sh Aure.p12
#   scripts/check-signing-p12.sh --fix Aure.p12   # also write Aure-compatible.p12
#
# --fix re-encrypts the file with the older algorithms `security import` reads
# (Keychain Access may export with newer ones it does not), same password.
# It needs OpenSSL 3 (Homebrew or Nix).
set -euo pipefail
fix=0
if [ "${1:-}" = "--fix" ]; then fix=1; shift; fi
p12="${1:?usage: $0 [--fix] file.p12}"
[ -f "$p12" ] || { echo "error: $p12 not found"; exit 1; }
read -r -s -p "Password for $(basename "$p12"): " AURE_P12_PASSWORD; echo
export AURE_P12_PASSWORD

tmp="$(mktemp -d)"
kc="$tmp/check.keychain-db"
cleanup() { security delete-keychain "$kc" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT

check() {
  local file="$1" kc_pass
  kc_pass="$(uuidgen)"
  security delete-keychain "$kc" 2>/dev/null || true
  security create-keychain -p "$kc_pass" "$kc"
  security unlock-keychain -p "$kc_pass" "$kc"
  echo "==> security import $(basename "$file")"
  security import "$file" -k "$kc" -P "$AURE_P12_PASSWORD" -T /usr/bin/codesign || return 1
  echo "==> code-signing identities in it:"
  security find-identity -p codesigning "$kc" | sed -n 's/^ *[0-9]*) //p'
  security find-identity -p codesigning "$kc" | grep -q '"Aure Local"'
}

echo "==> encryption: $(/usr/bin/openssl pkcs12 -in "$p12" -passin env:AURE_P12_PASSWORD -info -noout 2>&1 \
  | grep -E 'Encrypted data|Shrouded Keybag' | tr '\n' ' ')"
if check "$p12"; then
  echo "OK: $p12 works with the release workflow. Upload it as AURE_SIGNING_P12."
  exit 0
fi
echo "FAIL: no 'Aure Local' code-signing identity after importing $p12."
[ "$fix" = 1 ] || { echo "Re-run with --fix to write a compatible copy."; exit 1; }

out="$(dirname "$p12")/Aure-compatible.p12"
# Reading a modern .p12 needs OpenSSL 3 (macOS's /usr/bin/openssl is LibreSSL);
# -legacy then writes the algorithms `security import` reads.
ossl=""
for c in openssl /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl /nix/store/*-openssl-3*-bin/bin/openssl; do
  if command -v "$c" >/dev/null 2>&1 && "$c" version 2>/dev/null | grep -q '^OpenSSL 3'; then ossl="$c"; fi
done
[ -n "$ossl" ] || { echo "error: --fix needs OpenSSL 3 (brew install openssl@3, or nix shell nixpkgs#openssl)"; exit 1; }
# The key stays in memory and pipes, never a file. -export reads the certificate
# and the key separately, so each gets its own pipe.
pem="$("$ossl" pkcs12 -in "$p12" -passin env:AURE_P12_PASSWORD -nodes)"
"$ossl" pkcs12 -export -legacy -in <(printf '%s\n' "$pem") -inkey <(printf '%s\n' "$pem") \
  -name "Aure Local" -passout env:AURE_P12_PASSWORD -out "$out"
unset pem
chmod 600 "$out"
if check "$out"; then
  echo "OK: wrote $out (same password). Upload it as AURE_SIGNING_P12, then delete both files: rm -P $p12 $out"
else
  echo "FAIL: the compatible copy has no 'Aure Local' code-signing identity either. Either the export"
  echo "lacks the private key (in Keychain Access, export from 'My Certificates', the entry with a key"
  echo "under it), or the certificate is not the 'Aure Local' code-signing certificate."
  rm -P "$out"
  exit 1
fi
