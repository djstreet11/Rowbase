# Releasing Rowbase.app

## Quick (local use)
```
bash native/scripts/release.sh        # → native/dist/Rowbase-<VERSION>.dmg (ad-hoc signed)
```
Ad-hoc builds run on this Mac. On other Macs Gatekeeper blocks them (right-click → Open, or System Settings → Privacy & Security → Open Anyway).

## Signed + notarized (for distribution) — one-time setup, done by the developer
1. Join the Apple Developer Program (paid) and create a **Developer ID Application** certificate
   (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application).
   Check: `security find-identity -v -p codesigning` shows `Developer ID Application: <Name> (<TEAMID>)`.
2. Create an app-specific password at appleid.apple.com, then store notarization credentials in the Keychain
   (you type the password yourself; it is never stored in the repo):
   ```
   xcrun notarytool store-credentials rowbase-notary --apple-id <you@example.com> --team-id <TEAMID>
   ```
3. Release:
   ```
   ROWBASE_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" ROWBASE_NOTARY_PROFILE=rowbase-notary \
     bash native/scripts/release.sh
   ```
   The script signs the app with the hardened runtime (`native/Rowbase.entitlements`), builds the DMG, signs it,
   submits it to Apple's notary service, waits, staples the ticket and runs `spctl --assess`.

## Versioning
- One version everywhere: `rowbase/__init__.py`, `pyproject.toml`, `native/VERSION`, `server.json` (twice).
  Build number of the app = `git rev-list --count HEAD`.
- Bump, commit, tag `vX.Y.Z`, push the tag → GitHub release (binaries + DMG), PyPI `rowbase-db`, MCP Registry.

## Assets
- App icon is code: `swift native/scripts/make-icon.swift` (from `native/`) regenerates `Resources/AppIcon.icns` + `AppIcon-1024.png`.

## Later
- Auto-update (Sparkle with EdDSA-signed appcast), universal binary (`--arch arm64 --arch x86_64`) if Intel support is wanted.
