# Agent guide — DB Client project

Canonical agent file (read by Claude Code via `CLAUDE.md`, and by Amp/other agents directly).
Self-updating: see **Self-learning** below. Full product/tech spec: [SPEC.md](SPEC.md).

## Project in one paragraph
A pet project generalizing a work tool (read-only MySQL access for agents + web UI for AWIS/1C DBs) into a universal,
beautiful DB client with a connection manager (TablePlus-like). Two tracks: **A — Python** (CLI for agents + local web UI,
current code) and **B — native macOS app** (Swift 6 + SwiftUI/AppKit, Apple Silicon). Linux/Windows — far future.

## Layout
- `db.py` — CLI + core (connections, read-only guard, executor, pool, formatting). MySQL via `pymysql`.
- `ui.py` — local HTTP server (127.0.0.1) + JSON API + AWIS/1C ref resolution + history.
- `ui/` — vanilla JS/CSS frontend (no deps): `index.html`, `app.js`, `app.css`.
- `SPEC.md` — spec & roadmap. `docs/` — ADRs and notes (`docs/decisions.md`).
- `.claude/skills/` — `learn` (self-update), `db-query` (use the CLI), `run-ui` (launch web UI).
- `native/` — (planned) Swift app.

## Rules
- **Language**: code, comments, docs, commits in English. Final user-facing report in Russian (user preference).
  Existing UI strings are Ukrainian — keep until i18n is introduced (Phase 1).
- **Safety first**: never weaken the read-only guard (`db.guard`, READ ONLY tx, rollback) without explicit user request.
  Never print/commit passwords. Secrets → Keychain/keyring, never into `connections.json` or git.
- **Zero-deps frontend**: no frameworks/CDNs in `ui/`. Python deps minimal.
- **Style**: match surrounding code — compact, dense, short helpers, comments only for non-obvious "why".
  JS: `'use strict'`, `$`/`$$` helpers, `esc()` for every HTML interpolation. Python: stdlib-first, small functions.
- **Shared contracts** (`connections.json`, history JSONL, guard rules) must stay identical across tracks — see SPEC §5.
- **Git**: repo initialized on `main`. Commit logical units with clear messages; don't push (no remote) unless asked.
- **Token economy**: work in English; delegate to a Sonnet subagent only when (subagent + review) is cheaper than doing it inline.

## Environment facts
- macOS on Apple Silicon, Python 3.12.5 (system, **no pymysql** — use a venv: `python3 -m venv .venv && .venv/bin/pip install pymysql`),
  Xcode 26.3, Swift 6.2.4.
- Work-origin paths in code: `~/.config/awis-db/{.venv,connections.json,ui-history.jsonl}`, `AWIS_CONFIG_PHP`, `AWIS_DB_CONN`.
  `db.WORKSPACE` assumes the skill lived at `<ws>/.agents/skills/awis-db/scripts/` — here it resolves wrongly; set `AWIS_CONFIG_PHP`
  or use `~/.config/awis-db/connections.json` until the connection store (Phase 1) lands.

## Self-learning (mandatory)
Whenever you learn something durable — a new fact about the code/env, a user preference or correction, a decision, a pitfall,
a new recurring workflow — run the `learn` skill (`.claude/skills/learn/SKILL.md`) before finishing the task. It updates this file,
`SPEC.md`, `docs/decisions.md`, or creates/edits skills. Keep this file short: facts and rules only, no history.

## Learned notes
<!-- learn skill appends dated one-liners here; prune/merge when they grow stale -->
- 2026-10-03: Initial scan; spec + skills created. Git initialized.
