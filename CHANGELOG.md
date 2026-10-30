# Changelog

## Unreleased

### Changed

- The main capture button is now called **Smart Capture** (was "All in One").

### Added

- `LICENSE` file (all rights reserved) and a README with download and install steps.

## 1.3.1 — 2026-10-30

First release signed with Developer ID and notarized by Apple. macOS opens it
without a Gatekeeper warning. [Download](https://github.com/khaled1174/VantaShot/releases/tag/v1.3.1)

### Fixed

- Screen Recording permission: **Turn On…** now adds VantaShot to System Settings,
  so captures work as soon as the switch is on.

### Changed

- Capture cards stay on screen across captures until you close them, and continue
  in a new column when the screen is full.
- Capture cards no longer hide themselves after a few seconds.

### Added

- History: **Select**, **Select All**, bulk delete, and **Empty Trash**, which removes
  the files from your Mac.
- Developer ID release workflow with hardened runtime, Apple notarization and stapling
  for the app and DMG, Gatekeeper checks, and SHA-256 checksums
  (`script/notarize_release.sh`, see `NOTARIZATION.md`).
