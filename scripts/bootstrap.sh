#!/usr/bin/env bash
# One-time setup: create the stable self-signed "Aure Local" code-signing
# identity in your login keychain.
#
# Why: without an Apple Developer ID, the alternative is ad-hoc signing, and an
# ad-hoc signature changes on every build, so macOS forgets the Accessibility
# permission each time. A stable certificate keeps permissions across builds.
#
# Safe to re-run: does nothing if the identity already exists.
set -euo pipefail
name="Aure Local"
keychain="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$name\""; then
  echo "==> '$name' identity already exists"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

echo "==> creating certificate '$name' (valid 10 years)"
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -config "$tmp/cert.cnf" 2>/dev/null

pass="aure-$(date +%s)"
# -legacy keeps the PKCS#12 readable by macOS `security` with OpenSSL 3.
legacy=""
/usr/bin/openssl pkcs12 -help 2>&1 | grep -q -- "-legacy" && legacy="-legacy"
/usr/bin/openssl pkcs12 -export $legacy -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
  -name "$name" -out "$tmp/aure.p12" -passout "pass:$pass"

echo "==> importing into the login keychain (allowing codesign to use the key)"
security import "$tmp/aure.p12" -k "$keychain" -P "$pass" -T /usr/bin/codesign >/dev/null

echo "==> trusting it for code signing (macOS may ask for your password)"
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$tmp/cert.pem"

# scripts/setup-release-secrets.sh keeps a copy so CI signs releases with the
# same identity (then Accessibility stays granted across updates).
if [ -n "${AURE_P12_OUT:-}" ]; then
  cp "$tmp/aure.p12" "$AURE_P12_OUT"
  printf '%s' "$pass" > "$AURE_P12_OUT.password"
fi

security find-identity -v -p codesigning | grep "\"$name\"" && echo "==> done"
