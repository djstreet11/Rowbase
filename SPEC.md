# Rowbase — Product & Technical Spec

> Living document. Updated by the agent via the `learn` skill whenever new facts/decisions appear.
> Last update: 2026-10-04 (Apache-2.0, MCP server, one-file builds, pg8000).

## 1. Origin & idea

Started at work as a tool for an AI agent (Claude Code / Amp) to read a company MySQL database safely: a CLI + skill,
then a local web UI (JetBrains DB console was inconvenient), then a polished UX because existing tools (Adminer, TablePlus,
DbGate, …) are paywalled, confusing or dated. The work version was tied to that company's stack; **Rowbase** is the clean,
universal re-implementation — nothing company-specific is carried over.

**Name:** Rowbase (CLI `rowbase`, Python package `rowbase`, future app "Rowbase.app").

**Goal:** a fast, beautiful, safe-by-default DB client that stores connections (TablePlus-like), with:
- **Track A — Python**: CLI for agents + local web UI. Cross-platform by nature.
- **Track B — Native macOS app** for Apple Silicon, native language & UI, full feature set.
- **Future (far):** Linux (Ubuntu) and Windows.

## 2. Current state — Track A (Python)

```
rowbase/
  guard.py    dialect-aware read-only guard (length-preserving scanner: comments, quotes, E'' and $$ strings)
  drivers.py  MySQL (PyMySQL), Postgres (pg8000 via prepare(): one statement), SQLite (stdlib): connect, begin, run, catalog SQL
  mcp.py      MCP server (stdio) + toon.py (token-efficient output); edit.py (row editing); export.py; tunnel.py (SSH)
  store.py    connections.json + secrets (keyring / 0600 file / env), URL parsing
  engine.py   execute (guard, auto LIMIT, pool, RO/RW tx), formatting, catalog (tables, table_info with FKs)
  cli.py      `rowbase add|rm|conns|ping|tables|desc|q|ui`
  server.py   stdlib HTTP server (127.0.0.1) + JSON API + history
  static/     vanilla JS/CSS UI (index.html, app.js, app.css)
tests/        unittest: guard, engine+catalog on real SQLite/PG/MySQL, store, HTTP API
pyproject.toml  deps (all pure Python): PyMySQL, pg8000, keyring · packaging/ one-file Nuitka builds
```

### 2.1 Safety model (read-only connections — the default)
1. **Driver**: exactly one statement per call — PyMySQL without MULTI_STATEMENTS, pg8000 `prepare()` (protocol Parse),
   sqlite3 `execute`. Verified by tests even with the guard bypassed.
2. **Guard**: one statement; first keyword allow-list per dialect; forbidden patterns (locks, sleep, file I/O, `set_config`,
   PG `INTO`, sqlite `load_extension`, …).
3. **Transaction**: MySQL `START TRANSACTION READ ONLY`, PG `BEGIN READ ONLY` (+`SET LOCAL statement_timeout`),
   SQLite file opened `mode=ro`. Always rolled back.
4. **Timeouts**: MySQL `max_execution_time`, MariaDB `max_statement_time`, PG `statement_timeout`, SQLite progress-handler deadline.
5. Write-enabled connections (`readOnly: false`) skip the guard and commit; still one statement per call.

### 2.2 Execution
- Auto `LIMIT n+1` for SELECT (and WITH on RO) without a trailing LIMIT → `truncated`. Otherwise fetch cap 50 000 rows.
- Pool: ≤4 idle sessions per connection, keyed by connection config (edits invalidate), retry once on dropped session.
- Values: bytes(16) → UUID (or hex), other bytes → utf-8 or `0x…`, Decimal/dates/UUID/inet → str, json → JSON text.

### 2.3 Connection store (shared contract, see §5)
- `~/.config/rowbase/connections.json` (override dir: `ROWBASE_HOME`), no secrets.
- Passwords: OS keychain via `keyring` (service `rowbase`, account = connection id) → fallback `secrets.json` 0600
  (`ROWBASE_SECRETS=file` forces it) → `ROWBASE_PASSWORD_<NAME>` env overrides.
- URLs: `mysql|mariadb://`, `postgres|postgresql|pg://` (`?sslmode=`, `?socket=`), `sqlite:///abs/path`.

### 2.4 HTTP API (header `X-Rowbase: 1`, Host must be localhost)
GET `/api/conns`, `/api/tables?conn`, `/api/table?conn&name` → `{name, quoted, driver, columns[{…, fk}], indexes, referencedBy}`,
`/api/history?limit&conn`. POST `/api/query`, `/api/conns/save`, `/api/conns/delete`, `/api/conns/test`, `/api/refresh`.
History: `~/.config/rowbase/history.jsonl` (last 2000 entries).

### 2.5 Web UI features
Connection manager (modal: URL paste, test, RO toggle, env/color/group), connection switcher with RO/RW badge and prod
accent, table sidebar with filter (`/`), tabs persisted in localStorage, Data/Structure views, WHERE/ORDER BY with
autocomplete, paging, COUNT, grid/transpose, column picker, row inspector with "Referenced by", **FK navigation** with
breadcrumbs, SQL console (highlighting, ⌘/Ctrl+Enter statement under caret, dialect EXPLAIN buttons, schema-aware
autocomplete), confirmation for writes on RW connections, history drawer, copy JSON/TSV. English UI, no deps.

### 2.6 Known gaps
- No query cancel; no SSH tunnel; no TLS options for MySQL; no editing grid (only SQL on RW connections).
- Client-side sort sorts only the current page; grid not virtualized (slow >5k rows).
- No i18n yet (English only). Layout not adapted to very narrow windows (<700px): fixed 270px sidebar.

## 3. Product vision

**Positioning:** fast, beautiful, free(-core) DB client. TablePlus-level polish, agent-friendly, safe by default.

### 3.1 Principles
1. **Safe by default** — read-only unless switched per connection; env color tags (prod = red); writes reviewed before commit.
2. **Fast** — instant open, virtualized grids, pooled sessions, cancelable queries.
3. **Keyboard-first** — shortcuts everywhere; command palette (⌘K).
4. **Agent-friendly** — CLI with stable JSON output, same guard and connection store; MCP server later.
5. **Native look** — OS conventions, light/dark.

### 3.2 Target feature set
- **Connections**: CRUD, groups, color/env, RO flag, SSH tunnel (key/password/agent), TLS, socket, import (TablePlus/DBeaver/URL), export w/o secrets, test.
- **Drivers**: MySQL/MariaDB, PostgreSQL, SQLite (done in Track A); later ClickHouse, MS SQL, Redis.
- **Browser**: schemas → tables/views/routines; favorites; recents.
- **Grid**: virtualized, server-side sort, filter builder + raw WHERE, column picker, transpose, row inspector, FK navigation, copy as JSON/TSV/CSV/SQL INSERT/Markdown, export to file.
- **Editing** (RW only): inline edit, add/delete rows, pending-changes panel with SQL preview, commit/discard.
- **Structure**: columns, indexes, FKs, DDL; later structure editing.
- **SQL editor**: highlighting, autocomplete, statement/selection run, multiple results, EXPLAIN visualizer, formatter, saved queries, cancel.
- **History**, **session restore**.
- **Later**: ER diagram, data compare, dump/restore, AI assistant (NL→SQL), MCP server.

## 4. Architecture

### 4.1 Track A — Python
See §2. Principles: stdlib-first, zero frontend deps, minimal Python deps. New drivers = one class in `drivers.py`
(connect/begin/run/alive/ident/lit + catalog SQL) + guard rules in `guard.py` + tests in `tests/test_engine.py`.

### 4.2 Track B — Native macOS (Apple Silicon) — MVP done
- **Stack**: Swift 6 (strict concurrency), SwiftPM package `native/` (macOS 14+), SwiftUI shell + AppKit `NSTableView` grid
  (virtualized) and `NSTextView` SQL editor. Drivers: PostgresNIO (extended protocol), MySQLNIO (text protocol, no
  MULTI_STATEMENTS), system sqlite3. `scripts/bundle.sh` → ad-hoc signed `dist/Rowbase.app`.
- **Layout**:
  ```
  native/
    Package.swift
    Sources/RowbaseCore   Models (Connection, Dialect, QueryResult, TableInfo), Store (+Keychain, URL parsing), Guard (port),
                          Driver (DBSession protocol + Catalog SQL), SQLite/Postgres/MySQL sessions, Engine actor (+History)
    Sources/Rowbase       App, AppState, WorkTab, Sidebar, TabBar, TableTab, Structure, QueryTab, ResultGrid, SQLEditor,
                          RowInspector, ConnectionsSheet, HistorySheet
    Tests/RowbaseCoreTests  guard conformance (shared JSON), store/URL, engine on real SQLite/PG/MariaDB
  ```
- **Features (MVP)**: shared connection store + Keychain, connection manager sheet (URL paste, test, RO toggle, env/color/group),
  table browser with filter, tabs, data/structure views, WHERE/ORDER BY, paging, count, FK navigation + breadcrumbs, row inspector
  with referenced-by, SQL console (highlighting, ⌘↩ statement under caret, EXPLAIN, PG Seq Scan highlight), RW confirmation
  (incl. data-modifying WITH / EXPLAIN ANALYZE), prod accent bar, history (same JSONL as Python), copy TSV/JSON.
  Since 2026-10-04: flat NSSplitView layout (closable sidebar ⌥⌘S / inspector ⌘I / Esc), schema-aware autocomplete popup,
  query cancel (Stop / ⌘.), SSH tunnels, psql-like date/time formatting.
  Database switcher in the sidebar (lists server databases; required for MySQL connections without a database;
  choice remembered per connection as UI state, not written to connections.json).
- **Debug**: `ROWBASE_SNAPSHOT=…png` renders the window to PNG and exits (see `native-app` skill).
- **Parity with web UI**: reached 2026-10-04 (transpose, column picker, WHERE/ORDER BY autocomplete, EXPLAIN ANALYZE, tab restore,
  tables/views filter, history errors filter, MySQL EXPLAIN highlight). Editing + export in both tracks.
- **Gaps (both)**: no structure (DDL) editing, empty result sets show no column names (MySQL/PG), Postgres values decoded from binary
  (unknown types → text/hex fallback), SSH password auth (key/agent only), web UI has no query cancel, not notarized.
- **Distribution**: `native/scripts/release.sh` → DMG (app + Applications link + volume icon), generated app icon, version in
  `native/VERSION`; Developer ID signing + notarization opt-in via env (docs/RELEASING.md). Sparkle later. No App Store (sandbox).

### 4.3 Future: Linux / Windows
Options: (a) Python track + `pywebview` native window, (b) Tauri shell around the web UI, (c) Compose Desktop / Avalonia.
Deferred; keep contracts (§5) portable.

## 5. Shared contracts (must stay identical across tracks)

`~/.config/rowbase/connections.json`:
```json
{"version": 1, "connections": [{
  "id": "uuid", "name": "shop prod", "driver": "mysql|postgres|sqlite", "host": "…", "port": 3306, "socket": "/tmp/mysql.sock",
  "database": "…", "path": "/abs/file.db", "user": "…", "readOnly": true, "env": "local|dev|stage|prod",
  "color": "#d33", "group": "work", "options": {"sslmode": "require"},
  "ssh": {"host": "bastion", "port": 22, "user": "deploy", "identityFile": "~/.ssh/id_ed25519"}
}]}
```
- Secrets: keychain service `rowbase`, account = `id`.
- SSH: tunnels through the system `ssh` (`-N -L 127.0.0.1:<free>:<target>`, BatchMode, key/agent); URL form `?ssh=user@host:port`.
- History JSONL: `{"ts","conn"(id),"connName","sql","source","rows"|"error","elapsed","affected"?}`.
- Guard: same allow-lists/forbidden patterns; `tests/test_guard.py` vectors are the conformance suite.
- Row editing (`rowbase/edit.py`, `Edit.swift`): changes `[{op: update, key: {pk: v}, set: {col: v|null}} | {op: insert, values} | {op: delete, key}]`;
  write-enabled connection + primary key required, binary/unknown columns refused, values sent as quoted literals,
  one transaction, every UPDATE/DELETE must hit exactly 1 row (MySQL unchanged-value case verified by COUNT) else rollback.
  Web: `POST /api/edit {conn, table, changes, dryRun}`.
- Export: csv (RFC 4180, CRLF), tsv, json, md, sql (INSERT per row) — byte-identical across tracks via `tests/export_vectors.json`.
  Web: `POST /api/export` re-runs the statement with up to 1M rows.
- Database switch: web connection key `<id>::<db>`; native per-connection override in UI state. Not stored in connections.json.

## 6. Roadmap

| Phase | Scope | Status |
|---|---|---|
| 0 — Foundation | git, spec, agent file, skills | ✅ 2026-10-03 |
| 1 — Python generalization | package, store + keychain, MySQL/PG/SQLite, FK navigation, connection manager UI, English UI, tests | ✅ core 2026-10-03 |
| 1b — Python polish | query cancel, SSH tunnel, CSV/SQL export, server-side sort, virtualized grid, i18n (en/ru/uk) | next |
| 2 — Native MVP | Swift app: connection manager (Keychain), MySQL+PG+SQLite, sidebar, virtualized grid, SQL editor, history, guard | ✅ 2026-10-04 |
| 3 — Native parity+ | autocomplete, FK navigation, transpose, inspector, export, editing w/ pending changes, SSH, command palette | |
| 4 — Ship | signing/notarization, DMG, auto-update, onboarding, import from TablePlus | 🟡 DMG + pipeline 2026-10-04; needs Developer ID |
| 5 — Beyond | ER diagrams, AI assistant, MCP server, Linux/Windows | |

## 7. Open questions
- License / monetization (open source? free core?).
- UI languages beyond English (user speaks Russian/Ukrainian).


## 8. Open source, distribution, AI
- License: **Apache-2.0** (LICENSE, NOTICE, THIRD_PARTY_LICENSES.md — all deps permissive). README/CONTRIBUTING/SECURITY.
- One-file binaries (CLI + web UI + MCP): macOS arm64, Linux arm64/x64 (glibc ≥ 2.28), Windows x64 (10/11) — docs/BUILDING.md,
  GitHub Actions release on tag. No installer, no admin, no Python on the target. No-arg start opens the web UI.
- Native app embeds the macOS one-file binary (Contents/Resources/rowbase) → identical MCP server; AI / MCP sheet.
- MCP server: tools guide/connections/databases/tables/describe/search_schema/sample/count/query/explain (+apply_changes when
  allowed), TOON output, knowledge-base guide + resources + prompts, settings shared by CLI/web/native — docs/MCP.md.
