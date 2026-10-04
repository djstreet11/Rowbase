---
name: release
description: Build a distributable Rowbase.app / DMG, bump the version, sign and notarize. Use when asked to release, package, make an installer/DMG, sign or notarize the native app, or change the app icon.
---

# release — native app packaging

See docs/RELEASING.md for the full guide. Key facts:
- `bash native/scripts/release.sh` → `native/dist/Rowbase-<VERSION>.dmg` (app + /Applications link + volume icon).
- Signing/notarization are opt-in via env: `ROWBASE_SIGN_IDENTITY` (Developer ID Application) and `ROWBASE_NOTARY_PROFILE`
  (notarytool keychain profile). Without them: ad-hoc signature, local use only.
- This Mac currently has NO Developer ID identity (checked 2026-10-04) → notarization needs the user's Apple Developer account.
  Never ask for or type the Apple ID password / app-specific password — the user runs `notarytool store-credentials` themselves.
- Version: `native/VERSION`; build number from git commit count. Bump + commit + tag `vX.Y.Z`.
- Icon: `swift scripts/make-icon.swift` (cwd native/) regenerates Resources/AppIcon.icns; bundle.sh copies it.
- Verify a DMG: `hdiutil attach -nobrowse -readonly …`, check Info.plist version and `codesign -dv`, then detach.
- Hardened runtime entitlements: native/Rowbase.entitlements (empty: not sandboxed; network + ssh subprocess need nothing).
