#!/bin/bash
# Create a local, self-signed code-signing identity for Myna.
#
# Why: an ad-hoc signature's designated requirement is its cdhash, which changes
# on every build. macOS TCC then treats each build as a different app and drops
# Screen Recording / Accessibility grants. A self-signed certificate gives a
# stable requirement (bundle id + certificate leaf), so grants survive rebuilds.
#
# The certificate is NOT trusted by Gatekeeper; it is only used for local builds.
# Release artifacts remain ad-hoc (the private key must never be committed).
set -euo pipefail

SUPPORT="$HOME/Library/Application Support/Myna/signing"
KEYCHAIN="$HOME/Library/Keychains/myna-signing.keychain-db"
IDENTITY="Myna Local Code Signing"

mkdir -p "$SUPPORT"
chmod 700 "$SUPPORT"
cd "$SUPPORT"

if [ ! -f cert.pem ] || [ ! -f key.pem ]; then
  openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
    -subj "/CN=$IDENTITY" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" 2>/dev/null
  openssl pkcs12 -export -legacy -macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES \
    -out cert.p12 -inkey key.pem -in cert.pem -passout pass:myna 2>/dev/null
fi

if [ ! -f password ]; then
  openssl rand -hex 24 > password
fi
chmod 600 password cert.pem key.pem cert.p12 2>/dev/null || true
PASS="$(cat password)"

if [ ! -f "$KEYCHAIN" ]; then
  security create-keychain -p "$PASS" "$KEYCHAIN"
fi
security unlock-keychain -p "$PASS" "$KEYCHAIN"
security import cert.p12 -k "$KEYCHAIN" -P myna -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$KEYCHAIN" >/dev/null 2>&1 || true

CURRENT=$(security list-keychains -d user | tr -d '"' | tr '\n' ' ')
if ! echo "$CURRENT" | grep -q myna-signing; then
  security list-keychains -d user -s "$KEYCHAIN" $CURRENT
fi

echo "Local signing identity ready: $IDENTITY"
echo "Keychain: $KEYCHAIN"
security find-identity -p codesigning "$KEYCHAIN" | sed -n '1,4p'
echo
echo "Run ./build.sh to sign Myna.app with it."
echo "After the first launch, grant Screen Recording and Accessibility once;"
echo "the designated requirement stays stable across future builds."
