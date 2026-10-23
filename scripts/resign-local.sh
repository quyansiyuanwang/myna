#!/bin/bash
# Re-sign an installed Myna.app with the local stable certificate.
#
# Use after a Homebrew cask / release update: the release is ad-hoc, which
# replaces the code requirement and drops TCC grants. Re-signing with the same
# local certificate restores the stable requirement without rebuilding.
set -euo pipefail

APP="${1:-$HOME/Applications/Myna.app}"
KEYCHAIN="$HOME/Library/Keychains/myna-signing.keychain-db"
PASSWORD_FILE="$HOME/Library/Application Support/Myna/signing/password"
IDENTITY="Myna Local Code Signing"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

if [ ! -d "$APP" ]; then
  echo "App not found: $APP" >&2
  exit 1
fi
if [ ! -f "$KEYCHAIN" ] || [ ! -f "$PASSWORD_FILE" ]; then
  echo "Local signing identity missing. Run $REPO/scripts/setup-local-signing.sh first." >&2
  exit 1
fi
if ! security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
  echo "Identity '$IDENTITY' not found in $KEYCHAIN" >&2
  exit 1
fi

security unlock-keychain -p "$(cat "$PASSWORD_FILE")" "$KEYCHAIN" >/dev/null 2>&1 || true
codesign --force --options runtime --keychain "$KEYCHAIN" --sign "$IDENTITY" \
  --entitlements "$REPO/Resources/Myna.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
echo "Re-signed $APP with $IDENTITY"
codesign -d -r- "$APP" 2>&1 | tail -1
