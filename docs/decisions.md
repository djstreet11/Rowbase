# Decisions (ADR-lite)

Newest on top. Format: Context | Decision | Alternatives | Consequences.

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
