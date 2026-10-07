# Building the one-file `rowbase` binaries

One file per OS, no installer, no admin rights, no Python on the target machine. The binary contains the CLI,
the web UI (opens in the browser when started without arguments) and the MCP server.

| Target | How | Runs on |
|---|---|---|
| macOS arm64 | `python packaging/build.py` on a Mac | macOS 14+ (Apple Silicon) |
| Linux arm64 / x64 | `bash packaging/build-linux.sh arm64\|x64` (Docker; works on macOS) | glibc ≥ 2.28: Ubuntu 20.04+, Debian 10+, RHEL 8+ |
| Ubuntu/Debian `.deb` | `bash packaging/make-deb.sh dist/rowbase-linux-x64 x64` (needs `dpkg-deb`) | `/usr/bin/rowbase` + apps-menu entry |
| Windows x64 | `python packaging/build.py` on Windows, or the GitHub Actions release | Windows 10 and 11 |
| all + DMG | push a tag `vX.Y.Z` → `.github/workflows/release.yml` | — |

Prerequisites for local builds: Python 3.12 venv with `pip install . nuitka ordered-set zstandard`, a C compiler
(Xcode CLT on macOS, MSVC Build Tools on Windows — Nuitka can download MinGW automatically). Nuitka cannot
cross-compile, so Windows binaries come from a Windows machine or CI; Linux binaries come from Docker or CI.

## Notes
- All Python dependencies are pure Python (PyMySQL, pg8000, keyring) — no native DB client libraries.
- Secrets: macOS Keychain, Windows Credential Manager, Linux Secret Service (GNOME Keyring/KWallet) via `keyring`;
  headless Linux falls back to `~/.config/rowbase/secrets.json` (0600). `rowbase doctor` shows which one is used.
- Unsigned binaries: Windows SmartScreen shows "Windows protected your PC" → *More info* → *Run anyway*;
  macOS: right-click → Open (or `xattr -d com.apple.quarantine rowbase-macos-arm64`). Code-signing certificates
  remove these prompts (optional, paid).
- First start unpacks once per version into the user cache dir (~5 s on macOS); later starts take ~0.1 s
  (`--onefile-tempdir-spec={CACHE_DIR}/rowbase/{VERSION}` — important for MCP clients that spawn the server per session).
- Linux desktop integration: `packaging/rowbase.desktop` (Exec=`rowbase ui`) + `packaging/rowbase-256.png`, shipped by the
  `.deb` and by `packaging/install.sh` (no-root install to `~/.local`). A second launch reuses the running UI (same port).
  `.deb` installs can't self-update (`/usr/bin` is root-owned) — `rowbase update` points to the new `.deb` instead.
