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

## Auto-update key (Sparkle EdDSA) — one-time, done by the developer
Each tagged release publishes `Rowbase-<v>.zip`, `SHA256SUMS` and — once this key exists — `appcast.xml` (docs/UPDATES.md).
1. Download the Sparkle tools (same version as `SPARKLE_VERSION` in .github/workflows/release.yml), e.g.
   `curl -L https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz | tar xJ -C ~/sparkle`.
2. `~/sparkle/bin/generate_keys` → stores the private key in your login Keychain and prints the **public** key
   → Info.plist `SUPublicEDKey` in native/scripts/bundle.sh (public, safe to commit). Current key (2026-10-05):
   `UkOKTzt1PkcCC7qWiHHgHptn0b4yowWM392/i3/yVVo=`.
3. `~/sparkle/bin/generate_keys -x sparkle-private.txt` → GitHub → Settings → Secrets and variables → Actions →
   **Repository secrets** → New repository secret `SPARKLE_ED_PRIVATE_KEY` = file content → `rm sparkle-private.txt`.
   Not an *environment* secret (e.g. `pypi`): those reach only jobs that declare that environment, and the `dmg` job doesn't.
4. Back up the private key (password manager). **Losing it means installed apps can never auto-update again.**
   Never paste it into chats, issues or logs.
Without the secret the release still succeeds; the `dmg` job only warns that no appcast was produced.

## Versioning
- One version everywhere: `rowbase/__init__.py`, `pyproject.toml`, `native/VERSION`, `server.json` (twice).
  Build number of the app = `git rev-list --count HEAD`.
- Bump, commit, tag `vX.Y.Z`, push the tag → GitHub release (binaries + DMG), PyPI `rowbase-db`, MCP Registry.

## Assets
- App icon is code: `swift native/scripts/make-icon.swift` (from `native/`) regenerates `Resources/AppIcon.icns` + `AppIcon-1024.png`.

## Later
- Auto-update (Sparkle with EdDSA-signed appcast) — design in docs/UPDATES.md, universal binary (`--arch arm64 --arch x86_64`) if Intel support is wanted.
