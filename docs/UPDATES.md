# Updates — design

Goal: the update flow users know from Claude Desktop, Antigravity and PhpStorm.
**Check for Updates…** → "You're up to date" *or* "Rowbase 0.3.0 is available" + release notes → **Install and Relaunch**
→ download (progress) → verify → replace the app → relaunch. One click after the check, no DMG dragging, no browser.

Status: step 1 (release pipeline) and step 2 (app code) implemented; CLI part is design. ADR: docs/decisions.md, "Auto-update".

## 1. What we update, per channel

| Channel | How the user installed | How it updates |
|---|---|---|
| **Rowbase.app** (macOS) | DMG → /Applications | **Sparkle 2** in-app: menu + Settings + background check (§2) |
| Embedded CLI / MCP (`Rowbase.app/Contents/Resources/rowbase`) | comes with the app | updated together with the app (one bundle, one version) |
| One-file binary (`rowbase-macos-arm64`, `-linux-*`, `-windows-x64.exe`) | download from Releases | `rowbase update` self-replace (§3) |
| PyPI `rowbase-db` | `pipx` / `uv tool` / `pip` | notice only: print the exact upgrade command (§3) |
| `uvx --from rowbase-db rowbase mcp` | MCP client config | nothing to do — uvx resolves the latest version |
| Web UI (`rowbase ui`) | served by whichever binary runs it | banner "Rowbase X is available" + button that runs the same flow as the binary (§3) |

One source of truth for "what is the latest version": **GitHub Releases** of djstreet11/Rowbase. No own server.

## 2. Native app — Sparkle 2

Why Sparkle and not a home-grown updater: it is the de-facto macOS standard (MIT, permissive — OK for Apache-2.0),
already solves the hard parts we would otherwise re-implement and get wrong: atomic bundle replacement, asking for an
admin password when /Applications is not writable, relaunch after the old process exits, EdDSA signature checks,
release-notes window, scheduled background checks, phased rollout, "skip this version", delta updates.

### UX
- **Rowbase → Check for Updates…** (app menu, right under *About*). Standard Sparkle window:
  - up to date → "Rowbase 0.2.4 is currently the newest version available." [OK]
  - update → title, version, release notes (HTML from the appcast), [Skip This Version] [Remind Me Later] **[Install Update]**
  - progress bar while downloading → "Ready to install" → **[Install and Relaunch]** → app restarts on the new version.
- **Settings → Updates**: ☑ Automatically check for updates (daily, default on, asked once on 2nd launch — Sparkle's
  standard permission prompt), ☐ Automatically download and install (default off), [Check Now], "Last checked: …".
- Background check never interrupts a running query: Sparkle shows a "gentle reminder" (badge / dock bounce) instead of
  a modal while the app is active; install happens on relaunch or on quit (`SUAutomaticallyUpdate`).
- Before relaunch the app goes through the normal quit path: pending edits trigger the existing "unsaved changes"
  confirmation, `TunnelManager.shutdown()` runs (`applicationWillTerminate`). If the user cancels quit, the update
  stays staged and is installed on the next quit.

### Code (small)
- `Package.swift`: Sparkle `from: "2.9.6"` → `Rowbase` target only (RowbaseCore stays UI/updater-free).
- `Updater.swift`: `AppUpdater.shared` wraps `SPUStandardUpdaterController(startingUpdater: true, …)`, created in
  `applicationDidFinishLaunching`; inert without `SUPublicEDKey` in Info.plist (dev builds, snapshots). App menu
  "Check for Updates…" (`CommandGroup(after: .appInfo)`), Settings (⌘,) pane: automatic checks / automatic download +
  install / current version / last checked / Check Now. No `canCheckForUpdates` binding: a second check while a session
  runs just brings Sparkle's window forward.
- `SUAutomaticallyUpdate` default = false for ad-hoc builds, true when bundle.sh signs with `ROWBASE_SIGN_IDENTITY`.

### Bundle (`native/scripts/bundle.sh`)
- Copy `.build/release/Sparkle.framework` → `Rowbase.app/Contents/Frameworks/`; add rpath
  `install_name_tool -add_rpath @executable_path/../Frameworks Contents/MacOS/Rowbase` (SwiftPM builds a bare executable).
- Info.plist: `SUFeedURL` = `https://github.com/djstreet11/Rowbase/releases/latest/download/appcast.xml`,
  `SUPublicEDKey` = public EdDSA key (already in bundle.sh), `SUEnableAutomaticChecks` (unset → Sparkle asks once), `SUScheduledCheckInterval` 86400.
- Signing order: sign `Sparkle.framework` (its XPC services / Autoupdate / Updater.app) first, then the app — never
  `--deep`. XPC services are kept and re-signed (Sparkle's documented order).

### Release pipeline (`.github/workflows/release.yml`, job `dmg`)
1. Build the app as today; additionally produce `Rowbase-<v>.zip` (`ditto -c -k --keepParent Rowbase.app`) — the
   **update payload** (DMG stays the first-install download).
2. `sign_update Rowbase-<v>.zip` with the private EdDSA key from secret `SPARKLE_ED_PRIVATE_KEY` (`--ed-key-file -`).
3. `generate_appcast` (or a 30-line script) writes `appcast.xml`: one `<item>` per release with
   `sparkle:version` = build number (`git rev-list --count HEAD`, monotonic — Sparkle compares this),
   `sparkle:shortVersionString` = `X.Y.Z`, `sparkle:minimumSystemVersion` 14.0, `sparkle:edSignature`, `length`,
   enclosure URL `…/releases/download/vX.Y.Z/Rowbase-X.Y.Z.zip`, release notes = `<description>` with the release text.
   Keep the previous items (download the current appcast first) so old installs can see history / deltas later.
4. Upload `appcast.xml` as a release asset. `releases/latest/download/appcast.xml` always redirects to the newest
   release → no GitHub Pages / own hosting. Pre-releases are not "latest" → a beta channel later = second feed
   (`appcast-beta.xml` on a fixed `beta` release, or Sparkle channels in one feed).

### Keys & secrets
- One-time on the developer's Mac: `generate_keys` (from Sparkle's release tarball) → private key in the login Keychain,
  prints the public key → goes into bundle.sh. Export once with `generate_keys -x <file>` → GitHub secret
  `SPARKLE_ED_PRIVATE_KEY` → delete the file. The private key never enters the repo, logs or chat.
- Losing the private key = existing installs can never auto-update again (they reject other keys). Back it up (password manager).
- Key rotation is possible only while the old key still works (ship a build that trusts the new key, signed with the old one).

### Signing reality check (important)
- **With Developer ID + notarization** (recommended, Phase 4): everything just works; Sparkle additionally verifies the
  new bundle has the same Team ID. No Gatekeeper prompts after updates.
- **Ad-hoc (today)**: the update itself works (EdDSA is the trust anchor; Sparkle-downloaded files carry no quarantine flag,
  so no Gatekeeper dialog), but every build has a new code identity → macOS **re-asks Keychain access for saved
  passwords after each update** ("Rowbase wants to use your confidential information… Always Allow"). Acceptable for
  early adopters; one more reason to get the Developer ID before advertising auto-update.
- Must be verified on a real Mac before shipping: update 0.x(ad-hoc) → 0.y(ad-hoc), and later ad-hoc → Developer ID
  (Sparkle allows it when the EdDSA signature is valid; confirm with the shipped Sparkle version).

## 3. Python track — one-file binaries, PyPI, web UI

`rowbase/update.py` (stdlib only: `urllib`, `json`, `hashlib`):
- `latest()` → `GET https://api.github.com/repos/djstreet11/Rowbase/releases/latest` (no token; 60 req/h/IP is plenty),
  cached for 24 h in `~/.config/rowbase/update.json` (`{checked_at, latest, url}`), timeout 3 s, all errors → "unknown".
- `install_kind()` → `onefile` (Nuitka: `__compiled__` / `sys.argv[0]` is the binary), `app` (path inside `*.app/Contents/Resources`
  → updates come from Sparkle, CLI says "update Rowbase.app"), `pipx` / `uv` / `pip` (from `sys.prefix` / installer metadata).
- **`rowbase update [--check]`**
  - `--check`: prints `Rowbase 0.2.4 → 0.3.0 available` / `up to date`; exit code 0/10 for scripts.
  - `onefile`: download the asset for this OS/arch (`rowbase-<os>-<arch>[.exe]`) next to the binary as `.new`, verify
    SHA-256 against `SHA256SUMS` from the same release (CI publishes it; later also a minisign/EdDSA signature with the
    same key as Sparkle), `chmod +x`, run `<new> --version` as a smoke test, then atomic `os.replace`. Windows can't
    overwrite a running .exe → rename current to `.old`, move new in place, delete `.old` on next start.
    Directory not writable → print the manual command, never sudo.
  - `pipx` / `uv` / `pip` → print `pipx upgrade rowbase-db` / `uv tool upgrade rowbase-db` / `pip install -U rowbase-db`
    (we don't drive someone else's package manager).
- Passive notice: `rowbase ui` start and `rowbase doctor` show "update available" from the cache (one line, stderr).
  **Never** on `q`/`tables`/`mcp` output — agents parse stdout, the MCP stdio channel must stay clean.
- Web UI: `GET /api/version` → `{current, latest, kind, notes_url}`; header badge "Update available"; dialog with notes
  and **[Update and restart]** for `onefile` (server downloads, swaps the binary, re-execs itself, the page reconnects
  and reloads) or the copy-paste command for pip kinds.
- Opt-out everywhere: `ROWBASE_NO_UPDATE_CHECK=1` or setting `updates.check=false` (shared settings file, also respected
  by the native app's "Automatically check"). Corporate/offline users get zero network calls.

## 4. Privacy & safety
- The only network request is an anonymous GET to GitHub (api.github.com / github.com release assets). No telemetry,
  no IDs, no DB info. Documented in README → "Updates".
- Integrity: app = EdDSA (Sparkle) + Apple signature when available; binaries = HTTPS + SHA-256 (+ signature later).
- An update never touches `connections.json`, history, Keychain items or settings; schema migrations (if ever) are
  forward-only and run on first start of the new version.
- Downgrade is manual (old DMG / binary from Releases).

## 5. Rollout plan
1. ✅ **Pipeline first** (no user-visible change): `Rowbase-<v>.zip` (native/scripts/release.sh), `SHA256SUMS`, `appcast.xml`
   (packaging/appcast.py, tests/test_appcast.py) as release assets. appcast.xml appears once the secret
   `SPARKLE_ED_PRIVATE_KEY` exists (docs/RELEASING.md → "Auto-update key").
2. 🟡 **App** (code done, needs a Mac run): Sparkle + menu item + Settings pane (native/Sources/Rowbase/Updater.swift); release N ships the updater, release N+1 is the first real auto-update
   (users on versions without Sparkle must download the DMG once more — say so in N's release notes).
3. **CLI**: `rowbase update`, `/api/version`, web banner.
4. Developer ID + notarization → removes the Keychain re-prompt and Gatekeeper warnings.
5. Later: delta updates (`generate_appcast` creates them automatically), phased rollout
   (`sparkle:phasedRolloutInterval`), critical-update flag for security fixes.

## 6. Decisions (owner, 2026-10-05)
- **Ask before installing** while builds are ad-hoc: "Automatically download and install" defaults to **off**
  (PhpStorm-like). Once releases are Developer ID-signed + notarized → default **on** (Claude Desktop-like: downloaded
  silently, applied on quit/relaunch); the Settings toggle stays.
- **Ship auto-update before the Developer ID** — the Keychain re-prompt after an update is accepted for now.
- **No beta channel** — one feed, stable releases only.
