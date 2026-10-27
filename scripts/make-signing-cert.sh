#!/bin/zsh
# Creates the self-signed "Kobe Local Code Signing" identity in your login keychain, once. scripts/bundle.sh signs
# build/Kobe.app with it so macOS keeps the app's permissions (Accessibility, Focus, notifications) across rebuilds,
# which an ad hoc signature does not. Idempotent: if the identity already exists nothing changes.
# Usage: scripts/make-signing-cert.sh
#
# Recipe: an RSA key and a self-signed X.509 certificate with the Code Signing extended key usage (openssl), bundled
# into a PKCS#12 and imported into login.keychain with codesign allowed to use the key. The certificate is then
# marked trusted for code signing for your user only (security add-trusted-cert, no sudo).
set -euo pipefail
OPENSSL=/usr/bin/openssl   # the system LibreSSL writes a .p12 that macOS can import; Homebrew OpenSSL 3+ does not
NAME="${KOBE_SIGN_IDENTITY:-Kobe Local Code Signing}"
KEYCHAIN=~/Library/Keychains/login.keychain-db

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists in the login keychain; nothing to do."
  exit 0
fi
# Never create a second certificate of that name (codesign would call the name ambiguous).
if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "A \"$NAME\" certificate already exists but isn't a usable signing identity. Delete it in Keychain Access (login keychain), then run this script again."
  exit 2
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kobe-sign.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/openssl.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/openssl.cnf" 2>/dev/null
# A throwaway password: the .p12 only lives in this temp folder for a moment.
PASS=$("$OPENSSL" rand -hex 16)
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" -out "$WORK/identity.p12" -passout "pass:$PASS"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
# Trust it for code signing (user trust settings; macOS may ask for your login password once).
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

security find-identity -v -p codesigning "$KEYCHAIN" | grep "\"$NAME\"" || { echo "import failed"; exit 1; }
echo "Created \"$NAME\". scripts/bundle.sh will now sign with it."
