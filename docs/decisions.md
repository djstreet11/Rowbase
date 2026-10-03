# Decisions (ADR-lite)

Newest on top. Format: Context | Decision | Alternatives | Consequences.

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
