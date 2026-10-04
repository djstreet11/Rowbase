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

## One-file CLI/UI/MCP binaries (docs/BUILDING.md)
- macOS: `.venv/bin/python packaging/build.py` → dist/rowbase-macos-arm64 (~10 MB, ~3 min). Needs `--static-libpython=no` (Homebrew).
- Linux: `bash packaging/build-linux.sh arm64|x64` (Docker, quay.io/pypa/manylinux_2_28_*, unpack static-libs tarball) →
  glibc 2.28 → Ubuntu 20.04+. x64 on Apple Silicon is emulated (slow). Verify with `docker run ubuntu:20.04 … doctor`.
- Windows: only on Windows or via .github/workflows/release.yml (windows-2022 runner → runs on Win10 + Win11).
- Always rebuild dist/rowbase-macos-arm64 BEFORE native/scripts/release.sh — bundle.sh embeds it as Resources/rowbase (MCP).
- Pitfalls: Nuitka "self-execution" flag breaks our `-c` → `--no-deployment-flag=self-execution`; one-file binaries may get
  ASCII stdio/argv in C locale → cli._utf8_stdio + surrogate argv repair; keyring needs `--include-distribution-metadata=keyring`.

## GitHub release (verified 2026-10-04, v0.2.0)
- Bump `rowbase/__init__.py`, `pyproject.toml` and `native/VERSION` together → commit → `git tag -a vX.Y.Z` → push main + tag.
- .github/workflows/release.yml builds Linux x64/arm64, Windows x64 (doctor runs on the runner), macOS arm64 one-files + DMG
  (embeds the CLI) and publishes them to https://github.com/djstreet11/Rowbase/releases (~20–30 min).
- Watch by run id: `curl -s https://api.github.com/repos/djstreet11/Rowbase/actions/runs/<id>` (match the run id, not a text pattern
  across several runs — a pattern once matched another run's "completed").
