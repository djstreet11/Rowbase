# Decisions (ADR-lite)

Newest on top. Format: Context | Decision | Alternatives | Consequences.

## 2026-10-05 — Auto-update: Sparkle 2 for the app, `rowbase update` for one-file binaries (design, docs/UPDATES.md)
Context: user wants the Claude/PhpStorm flow — Check for Updates → Install → relaunch. Decision: native app uses Sparkle 2
(MIT) with an EdDSA-signed appcast published as a GitHub release asset (`releases/latest/download/appcast.xml`), update
payload = zipped app; one-file binaries self-replace via `rowbase update` (SHA-256 from `SHA256SUMS`); pip installs only get
the upgrade command. GitHub Releases is the single source of truth, no own server, opt-out `ROWBASE_NO_UPDATE_CHECK`.
Alternatives: home-grown updater (re-implements atomic replace, admin auth, relaunch — rejected), Homebrew cask only (not
one-click), Mac App Store (sandbox breaks ssh/Keychain sharing). Consequences: EdDSA private key = critical secret (GitHub
secret + offline backup); ad-hoc builds re-prompt Keychain access after each update until Developer ID signing.

## 2026-10-04 — Native project = pure SwiftPM, app bundle by script
Context: no XcodeGen/Tuist installed; agents must build/test from CLI. Decision: `native/Package.swift` with RowbaseCore library +
Rowbase executable; `scripts/bundle.sh` assembles an ad-hoc signed `Rowbase.app`; Xcode opens Package.swift directly.
Alternatives: .xcodeproj (binary-ish, merge-hostile), XcodeGen (extra tool). Consequences: AppDelegate must set activation policy;
signing/notarization handled in the script later (Phase 4).

## 2026-10-04 — Shared guard conformance vectors
Decision: `tests/guard_vectors.json` is the single source of guard test cases for Python and Swift. Consequences: guards cannot drift silently.

## 2026-10-03 — Name "Rowbase", drop work-specific code
Context: prototype was tied to the work project (AWIS, 1C metadata, Config.php). User: not needed here.
Decision: product/CLI/package name **Rowbase**; 1C ref resolution replaced by generic FK navigation (catalog `fk`, `referencedBy`).
Alternatives: keep a plugin for 1C (rejected — out of scope). Consequences: no company specifics in repo.

## 2026-10-03 — Read-only safety = 4 layers, driver first
Decision: (1) driver executes one statement per call (pymysql default, psycopg prepare=True, sqlite3), (2) dialect-aware guard,
(3) READ ONLY tx / sqlite mode=ro + rollback, (4) statement timeouts. RW connections skip (2) and commit.
Consequences: guard bugs alone cannot cause writes; tests verify (1) with the guard bypassed.

## 2026-10-03 — Connection store & secrets
Decision: `~/.config/rowbase/connections.json` (no secrets) + Keychain (`keyring`, service `rowbase`, account = id), 0600 file fallback,
env override. Same location and Keychain items for the native app (non-sandboxed). Alternatives: per-track stores (rejected — agents and app must share).

## 2026-10-03 — Native macOS stack
Context: Track B must feel perfectly native and fast on Apple Silicon.
Decision: Swift 6 + SwiftUI shell, AppKit `NSTableView` grid and `NSTextView` (TextKit 2) editor; SwiftNIO drivers (MySQLNIO, PostgresNIO), system sqlite3; Keychain for secrets; macOS 14+.
Alternatives: pure SwiftUI `Table` (too slow for large result sets), Electron/Tauri (not native), Catalyst.
Consequences: some AppKit bridging code; best perf and native feel.

## 2026-10-03 — Agent knowledge files
Context: user wants a self-updating agent.
Decision: canonical `AGENTS.md` (Claude imports via `CLAUDE.md` → `@AGENTS.md`; Amp reads AGENTS.md natively), `SPEC.md`, skills in `.claude/skills/`, `learn` skill as the update loop.
Alternatives: CLAUDE.md only (not shared with Amp).
Consequences: one source of truth for all agents.

## 2026-10-03 — Shared contracts between tracks
Decision: same `connections.json` schema (no secrets), history JSONL, guard rules in Python and Swift tracks.
Consequences: agents (CLI) and the native app see the same connections.
