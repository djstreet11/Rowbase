# Agent guide — Rowbase

Canonical agent file (read by Claude Code via `CLAUDE.md`, and by Amp/other agents directly).
Self-updating: see **Self-learning** below. Full product/tech spec: [SPEC.md](SPEC.md).

## Project in one paragraph
Rowbase: a fast, beautiful, read-only-by-default DB client with a connection manager (TablePlus-like). Born from a work tool,
re-implemented generically (no company/1C specifics). Two tracks: **A — Python** (`rowbase` CLI for agents + local web UI;
MySQL/MariaDB, PostgreSQL, SQLite) and **B — native macOS app** (Swift 6 + SwiftUI/AppKit, Apple Silicon, `native/`, SwiftPM).
Linux/Windows — far future.

## Layout
- `rowbase/` — `guard.py` (RO guard), `drivers.py` (per-DB classes), `store.py` (connections + secrets), `engine.py`
  (execute, pool, catalog), `cli.py`, `server.py` (HTTP API), `static/` (vanilla JS UI).
- `tests/` — `python -m unittest discover -s tests -t .` (PG/MySQL tests auto-skip if unreachable).
- `SPEC.md` — spec & roadmap (§5 = cross-track contracts). `docs/decisions.md` — ADRs.
- `native/` — Swift app: `RowbaseCore` (store, Keychain, guard, drivers, engine) + `Rowbase` (SwiftUI/AppKit UI). `swift test`.
- `tests/guard_vectors.json` — guard conformance cases shared by Python and Swift suites.
- `.claude/skills/` — `learn` (self-update), `db-query` (use the CLI), `run-ui` (web UI), `add-driver`, `native-app` (build/test/snapshot Mac app).

## Rules
- **Language**: code, comments, docs, commits, UI strings in English. Final user-facing report in Russian.
- **Safety first**: never weaken the RO layers (driver single-statement, guard, READ ONLY tx + rollback, sqlite `mode=ro`)
  without an explicit user request; any guard change needs vectors in `tests/test_guard.py`.
- **Secrets**: never print, log, commit or put passwords in `connections.json`/history. Keychain service `rowbase`, account = conn id.
- **Contracts** (SPEC §5) are shared with the native app — change them only deliberately and update SPEC.
- **Zero-deps frontend**: no frameworks/CDNs in `rowbase/static/`; `esc()` every interpolated value. Python: stdlib-first.
- **Style**: match surrounding code — compact, dense, small helpers, comments only for non-obvious "why".
- **Tests**: run the suite after backend changes; keep it green. Fixture DB `rowbase_test` is dropped/recreated by tests.
- **Git**: branch `main`, no remote. Commit logical units; message body + `Co-Authored-By` trailer. Don't push unless asked.
- **Token economy**: work in English; delegate to a Sonnet subagent only when (subagent + review) is cheaper than inline
  (worked well for: large mechanical frontend rewrite against a fixed API contract).

## Environment facts
- macOS, Apple Silicon. System Python 3.12.5 has no drivers → project venv `.venv` (`pip install -e .`), CLI `.venv/bin/rowbase`.
- Local servers (Homebrew services): MariaDB 11.5 (socket `/tmp/mysql.sock`), PostgreSQL 15.3 (socket dir `/tmp`); user `admin`,
  socket auth without password. Xcode 26.3, Swift 6.2.4, Docker available.
- Scratch config for manual testing: `ROWBASE_HOME=$PWD/.scratch-home ROWBASE_SECRETS=file` (git-ignored) — keeps the real
  `~/.config/rowbase` and Keychain untouched.

## Self-learning (mandatory)
Whenever you learn something durable — a fact about code/env, a user preference or correction, a decision, a pitfall,
a recurring workflow — run the `learn` skill (`.claude/skills/learn/SKILL.md`) before finishing the task. Keep this file
short: facts and rules only, no history.

## Learned notes
<!-- learn skill appends dated one-liners here; prune/merge when they grow stale -->
- 2026-10-03: Project named Rowbase; all AWIS/1C specifics dropped by user request (they belonged to the work project).
- 2026-10-03: psycopg needs `cur.execute(sql.replace('%','%%'), (), prepare=True)` to force one statement per call.
- 2026-10-03: `sqlite3.Connection` takes no attributes → connect with `factory=` subclass. `sqlite:////abs` URLs → collapse leading slashes.
- 2026-10-03: MySQL backslash escapes make `'a\'; DELETE …'` one literal — guard tests must be dialect-correct.
- 2026-10-03: JS `new URL()` rejects `mysql://user@/db?socket=…` (empty host) — parse connection URLs manually; round-trip `options`.
- 2026-10-03: Built-in browser pane resizes/scales unpredictably → verify UI by driving the DOM with `javascript_tool` and reading state; screenshots only for visuals.
- 2026-10-03: Subagent frontend work passed `node --check` but had 2 functional bugs found only in-browser — always browser-test delegated UI.
- 2026-10-03: Safety controls (Read-only toggle) must be visible without scrolling in forms.
- 2026-10-04: Dialect.ident() is for TABLES (PG adds `public.`); quote columns with Dialect.column() — mixing them broke PG ORDER BY.
- 2026-10-04: PG binary NUMERIC must be decoded manually to keep dscale (Decimal/PostgresNumeric drop "7.00" → "7").
- 2026-10-04: RW write-confirmation must also catch data-modifying `WITH … DELETE` and `EXPLAIN ANALYZE <write>`.
- 2026-10-04: macOS has no `timeout` → `perl -e 'alarm 40; exec @ARGV' cmd`. No screen-recording permission → app self-snapshot hook.
- 2026-10-04: User rejected macOS 26 floating glass sidebar + non-closable inspector → flat NSSplitView, every side panel closable.
- 2026-10-04: SSH = system `ssh` subprocess (honours ~/.ssh/config); test via tests/fixtures/fake_ssh.py + ROWBASE_SSH (no sshd here).
- 2026-10-04: MySQL `KILL QUERY` makes SLEEP() return normally → treat success-after-cancel as cancelled.
- 2026-10-04: Safety hook blocks `rm` on `$VAR/...` globs — use literal paths or `"${VAR:?}"`.
