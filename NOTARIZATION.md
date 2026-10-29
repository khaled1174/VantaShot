# Developer ID distribution

The local development bundle is built by `bundle-app.sh`. For distribution, use
`script/notarize_release.sh`. It requires a Developer ID Application signing
identity, its private key in Keychain, and a validated notarytool Keychain profile.

## One-time account setup

1. Open Xcode → Settings → Accounts → your Apple Account → Manage Certificates.
   Use **+ → Developer ID Application**. If that option is unavailable, verify
   that you selected the paid developer team and have the required account role.
2. Create an app-specific password at <https://account.apple.com/> under
   Sign-In and Security → App-Specific Passwords.
3. In your own Terminal, run the following command. It prompts for the Apple
   Account email, app-specific password, and Developer Team ID, validates them,
   and stores them in Keychain. Enter credentials directly in Terminal.

   ```bash
   xcrun notarytool store-credentials VantaShot-Notary
   ```

The Developer Team ID is in the Apple Developer account membership details.
Do not put passwords, API keys, certificate private keys, or `.p12` exports into
this project or chat. The build script only receives the Keychain profile name.

## Check and release

From this directory:

```bash
bash script/notarize_release.sh --check
bash script/notarize_release.sh
```

To select a different Keychain profile, append its name. If multiple Developer ID
identities exist, set `CODE_SIGN_IDENTITY` to the intended identity's SHA-1 hash
from `security find-identity -v -p codesigning`.

The script validates the certificate and authentication before building. It signs
a copy of the bundle with the hardened runtime and the audio-input entitlement,
submits a ZIP to Apple, checks `Accepted`, and staples and verifies the app. It
then creates and signs the DMG, submits it, checks acceptance, staples it, and
verifies the disk image, signature, Gatekeeper assessment, and final SHA-256.

Successful output is under a new `dist/notarized-<version>-<build>.<suffix>/`
directory, including the app, DMG, checksum, and Apple's JSON submission results.
Previous DMGs remain available. Runtime testing of screen capture, microphone,
recording, and shortcuts on the distribution-signed app is still required.

## Failed or delayed submissions

A rejected submission does not produce a final DMG. Read the saved
`notary-app.json` or `notary-dmg.json`, then fetch Apple's diagnostic log using
its submission ID:

```bash
xcrun notarytool log SUBMISSION_ID --keychain-profile VantaShot-Notary
```

A wait timeout does not cancel Apple's processing. Query the saved submission ID
with `xcrun notarytool info SUBMISSION_ID --keychain-profile VantaShot-Notary`
before retrying. The script does not resume an interrupted submission; rerunning
the full release command creates a new output directory and new submissions.

References: [Apple notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
[audio-input entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input).
