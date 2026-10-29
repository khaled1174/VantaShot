# VantaShot

Native macOS screenshot and screen recording application, built with Swift,
AppKit, SwiftUI, and ScreenCaptureKit.

## Requirements

- macOS 13 or newer
- Xcode with Swift 5.9 or newer and command line tools

## Build

```bash
swift build
```

To create the development app bundle:

```bash
bash bundle-app.sh
```

The bundle is written to `dist/VantaShot.app`. The script uses an available
Apple Development signing identity, or an ad-hoc signature when none is found.
See [NOTARIZATION.md](NOTARIZATION.md) for Developer ID distribution.

## Tests

```bash
swift test
```

Manual runtime checks are documented in [Tests/ManualAcceptance.md](Tests/ManualAcceptance.md)
and [Tests/ManualShortcutsAcceptance.md](Tests/ManualShortcutsAcceptance.md).

## Restore from GitHub

```bash
git clone https://github.com/khaled1174/VantaShot.git
cd VantaShot
bash bundle-app.sh
```

This repository backs up the source, tests, app resources, build scripts, and
project documentation. Generated build/distribution output, local Codex settings,
and signing credentials are excluded. Signing identities and notarization
credentials stay in the macOS Keychain and must be configured separately on a
new Mac. External REA research notes and original third-party artifacts are not
part of this application repository.
