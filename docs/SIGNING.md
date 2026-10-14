# Signing and notarization

This document describes how to produce a Developer ID-signed and notarized
`AiSiri.app` so that it launches without Gatekeeper warnings on other Macs.

The build itself does not require full Xcode — Command Line Tools are sufficient.
What it does require is an Apple Developer account with a **Developer ID
Application** certificate, plus notarization credentials.

## Prerequisites

1. **Apple Developer Program membership.** Developer ID certificates are only
   available to paid members. Enroll at
   https://developer.apple.com/programs/ if you have not already.
2. **Command Line Tools.** Verify:
   ```sh
   xcode-select -p            # /Library/Developer/CommandLineTools
   xcrun --find notarytool    # path to notarytool
   ```

## 1. Create a Developer ID Application certificate (without Xcode)

1. Open **Keychain Access** → menu **Keychain Access → Certificate Assistant →
   Request a Certificate From a Certificate Authority**.
   - User Email Address: your Apple ID
   - Common Name: e.g. `AiSiri Developer ID`
   - CA Email Address: leave empty
   - Request is: **Saved to disk**
   - Save `CertificateSigningRequest.certSigningRequest`.
2. Go to https://developer.apple.com/account/resources/certificates/list
   → **+** → **Developer ID Application** → upload the CSR file → **Continue**.
3. Download the generated `.cer` file and **double-click** it to import it into
   the login keychain.
4. Verify that the identity is now available:
   ```sh
   security find-identity -v -p codesigning
   ```
   You should see a line like
   `"Developer ID Application: Your Name (TEAMID)"`.

## 2. Store notarization credentials

Notarization authenticates with either an app-specific password or an App Store
Connect API key. Choose one.

### Option A — App-specific password

1. Sign in at https://appleid.apple.com → **Sign-In and Security** →
   **App-Specific Passwords** → generate one.
2. Store it in the keychain:
   ```sh
   xcrun notarytool store-credentials "AiSiri" \
     --apple-id "<your-apple-id>" \
     --team-id "<TEAMID>" \
     --password "<app-specific-password>"
   ```
   `TEAMID` is the 10-character team identifier shown next to your name in the
   developer portal, and also in the `(...)` of the certificate name.

### Option B — App Store Connect API key

1. https://appstoreconnect.apple.com → **Users and Access** → **Integrations** →
   **App Store Connect API** → create a key with the **Developer** role.
2. Download `AuthKey_<KEYID>.p8` and note the **Key ID** and **Issuer ID**.
3. Store it:
   ```sh
   xcrun notarytool store-credentials "AiSiri" \
     --key ~/Downloads/AuthKey_<KEYID>.p8 \
     --key-id "<KEYID>" \
     --issuer "<ISSUER-ID>"
   ```

## 3. Build, sign, and notarize

```sh
cd macos-ai-assistant
./release.sh 0.3.2
```

The script performs six steps:

1. Build and sign with the Developer ID identity (hardened runtime, timestamp).
2. Verify the signature.
3. Zip the app.
4. Submit to the notary service and wait for the result.
5. Staple the notarization ticket to the app.
6. Re-zip, producing `AiSiri-v<version>.zip`.

Override defaults with environment variables if needed:

```sh
AISIRI_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
AISIRI_NOTARY_PROFILE="AiSiri" \
./release.sh 0.3.2
```

## Notes

- **Hardened runtime** is enabled during signing (`--options runtime`). The
  required entitlements are already declared in
  `Resources/AiSiri.entitlements`: `com.apple.security.device.audio-input` and
  `com.apple.security.automation.apple-events`.
- Without a Developer ID certificate, `./build.sh` falls back to an **ad-hoc**
  signature, which is fine for local use but triggers Gatekeeper on other Macs.
- If notarization fails, inspect the log:
  ```sh
  xcrun notarytool log <submission-id> --keychain-profile "AiSiri"
  ```
- The `--timestamp` flag requires network access to Apple's timestamp server.
