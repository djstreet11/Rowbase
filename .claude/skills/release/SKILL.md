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
- Bump `rowbase/__init__.py`, `pyproject.toml`, `native/VERSION` and BOTH versions in `server.json` together → commit →
  `git tag -a vX.Y.Z` → push main + tag. The `pypi` job fails if pyproject version ≠ tag.
- .github/workflows/release.yml builds Linux x64/arm64, Windows x64 (doctor runs on the runner), macOS arm64 one-files + DMG
  (embeds the CLI) and publishes them to https://github.com/djstreet11/Rowbase/releases (~20–30 min).
- Watch by run id: `curl -s https://api.github.com/repos/djstreet11/Rowbase/actions/runs/<id>` (match the run id, not a text pattern
  across several runs — a pattern once matched another run's "completed").

## Auto-update assets (docs/UPDATES.md)
- release.sh also makes `native/dist/Rowbase-<v>.zip` (Sparkle payload, `ditto --keepParent`); publish job adds `SHA256SUMS`.
- `dmg` job signs the zip with secret `SPARKLE_ED_PRIVATE_KEY` (Sparkle `sign_update --ed-key-file -`, tools pinned by
  `SPARKLE_VERSION`) and runs `packaging/appcast.py`, merging the previous feed from `releases/latest/download/appcast.xml`.
  No secret → warning, no appcast. `sparkle:version` = build number (`git rev-list --count HEAD`) — must keep growing.

- `rowbase update` e2e (verified 2026-10-05 on a real Nuitka linux-x64 build): build twice (temporarily bump
  `rowbase/__init__.py`, revert!), serve a fake release dir (`latest` JSON + asset + SHA256SUMS) and point
  `ROWBASE_UPDATE_URL` at it; CLI `rowbase update -y` and the web UI button (Playwright) both swap the binary and the UI
  re-execs on the same port. A one-file build takes ~6 min in the cloud container (no ccache).

## PyPI + MCP Registry (release.yml job `pypi`; workflow mcp-registry.yml)
- PyPI project `rowbase-db` via Trusted Publishing (OIDC, no tokens): publisher = djstreet11/Rowbase, workflow release.yml, environment pypi.
- MCP Registry name `io.github.djstreet11/rowbase`; ownership = GitHub OIDC + `<!-- mcp-name: io.github.djstreet11/rowbase -->` in README
  (it becomes the PyPI description). server.json schema 2025-12-11; `mcp-publisher validate` runs before publish.
- A version can never be re-uploaded to PyPI → bump the patch version for every published fix.
- mcp-registry.yml runs after a successful Release (workflow_run), on server.json changes on main, or manually; skips if the
  version isn't on PyPI yet or is already registered. Registry limits: description ≤ 100 chars (v0.2.1 failed on that) —
  check locally first: download mcp-publisher (official registry releases) → `mcp-publisher validate`.

## Release notes for the user (MANDATORY after every release)
The workflow publishes auto-generated notes; the user pastes a proper text himself. After the release run is green, reply with:
- `git log --oneline v<prev>..v<new>` → group into Highlights / Fixes (user-facing wording, no internals);
- downloads table (DMG, macos-arm64, linux-x64/arm64, windows-x64.exe);
- install lines: `pipx install rowbase-db`, `claude mcp add rowbase -- uvx --from rowbase-db rowbase mcp`;
- the "not code-signed yet" note (until Developer ID / Windows signing exist).
Tell the user: Releases → the version → Edit → replace the text → Update release.
