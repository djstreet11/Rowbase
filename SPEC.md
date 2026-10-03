# DB Client — Product & Technical Spec

> Living document. Updated by the agent via the `learn` skill whenever new facts/decisions appear.
> Last update: 2026-10-03 (initial scan).

## 1. Origin & idea

Started at work as a tool for an AI agent (Claude Code / Amp) to read the company's (AWIS, 1C-based) MySQL databases:
1. `db.py` — CLI + skill so the agent can query DBs safely (read-only).
2. `ui.py` + `ui/` — a local web UI on top of it, because the JetBrains DB console was inconvenient.
3. UI/UX polished further because existing tools (Adminer, TablePlus, DbGate, etc.) are either paywalled ("buy premium"), confusing, or look like the 90s.

**Goal now:** turn it into a universal, pleasant DB client that stores connections (TablePlus-like), with:
- **Track A — Python** (current format): CLI for agents + local web UI. Cross-platform by nature.
- **Track B — Native macOS app** for Apple Silicon (M-series), native language & UI, full feature set, perfect performance.
- **Future (far):** Linux (Ubuntu) and Windows.

## 2. Current state (as scanned)

| File | Lines | Role |
|---|---|---|
| `db.py` | 322 | CLI (`conns`, `ping`, `tables`, `desc`, `q`), connection loading, SQL guard, executor, pooling, formatting |
| `ui.py` | 329 | `ThreadingHTTPServer` on 127.0.0.1, JSON API, schema cache, 1C ref resolution, history |
| `ui/index.html` | 90 | Shell: header, sidebar, tabs, drawers, templates for table/console panes |
| `ui/app.js` | 845 | Vanilla JS app (no deps): tabs, table browser, SQL console, autocomplete, highlighting, export, history |
| `ui/app.css` | 144 | Light/dark theme via CSS vars, system fonts |

### 2.1 db.py
- **Connections**: parsed from `awis.loc/solution/config/Config.php` (`DBHost/DBName/DBUser/DBPassword` + `ExternalDatabaseConnections`, incl. aliases), overridable via `~/.config/awis-db/connections.json`. Env: `AWIS_CONFIG_PHP`, `AWIS_DB_CONN`. Passwords never printed.
- **Driver**: `pymysql` only (MySQL/MariaDB). Expected venv: `~/.config/awis-db/.venv`. *Not installed in system python on this Mac.*
- **Read-only guard** (defense in depth):
  1. Strip comments → reject multiple statements (`;` outside literals).
  2. First word ∈ `SELECT SHOW DESC DESCRIBE EXPLAIN WITH`.
  3. Forbidden patterns: `INTO OUTFILE/DUMPFILE`, `FOR UPDATE`, `LOCK IN SHARE MODE`, `GET_LOCK(`, `SLEEP(`, `BENCHMARK(`.
  4. Session `SET SESSION TRANSACTION READ ONLY` + per-statement `START TRANSACTION READ ONLY` + always `rollback`.
  5. Timeout: `max_execution_time` (MySQL) / `max_statement_time` (MariaDB).
- **Auto LIMIT**: SELECT/WITH without trailing LIMIT gets `LIMIT n+1` → `truncated` flag.
- **Pool**: up to 4 idle sessions per conn (VPN connect ≈0.5s vs stmt ≈0.05s); retry once on dropped session.
- **Formatting**: BINARY(16) → UUID or hex; Decimal/dates → str. Output: `table | json | tsv | vertical`, `--out file`.

### 2.2 ui.py (HTTP API)
- Security: binds 127.0.0.1, checks `Host` header (DNS-rebinding), requires `X-AWIS-UI: 1` header on API (blocks CSRF).
- GET `/api/conns`, `/api/tables?conn`, `/api/table?conn&name` (columns+indexes+refs), `/api/history?limit`.
- POST `/api/query {conn,sql,limit≤5000,timeout,source,history}`, `/api/resolve {conn,value,table,column,tref}`, `/api/refresh`.
- History: `~/.config/awis-db/ui-history.jsonl`, trimmed to last 2000 entries when >2MB.
- **AWIS/1C-specific**: `metadata_full.xml` parsing (StoreType → ref target tables), `Catalog*/Document*/ChartOf*` tables with `char(36)` PK `Ref`, ref resolution strategies: `TRef` column → learned → metadata → name heuristic → full scan; labels from `Description/Number/Code`.

### 2.3 Web UI features
- Connection selector, table sidebar (filter `/`, hide service tables `DEL_ _ tmp`, approx row counts).
- Tabs (persisted in localStorage), table tabs dedup by conn+table+where; middle-click close.
- Table pane: Data/Structure views, WHERE + ORDER BY inputs with autocomplete (columns, keywords, functions, enum values, 0/1 for tinyint(1), empty-ref for char(36)), limit, paging, COUNT, "to console", default order by `DateTime`/`LastModificationDate` DESC.
- Grid / Transpose modes, client-side sort, column picker (hidden cols persisted per table), row drawer (filter, copy JSON), copy result as JSON/TSV.
- Ref navigation: click UUID → resolve → open target row in new tab, breadcrumbs chain.
- SQL console: overlay syntax highlighting (textarea + pre), ⌘/Ctrl+Enter runs selection or statement under caret, Tab indent, EXPLAIN / EXPLAIN ANALYZE, EXPLAIN highlighting (`type=ALL`, rows>100k).
- Context-aware autocomplete: FROM/JOIN → tables; `alias.` → columns; aliases; values.
- History drawer: filter, errors only, click → open in new console.
- Status bar: rows, elapsed, truncation warning, connection.
- UI language: Ukrainian. No external deps.

### 2.4 Gaps / tech debt (to fix in generalization)
- Hard-wired to AWIS (paths, Config.php, 1C metadata, `X-AWIS-UI`, brand). → move into an **AWIS plugin**.
- MySQL only. Read-only only (no editing). No connection manager UI, no SSH tunnel/TLS options.
- Passwords in plain config files. → Keychain (macOS) / `keyring` (Python).
- Credentials reloaded (`load_connections()`) on every new connection; regex PHP parsing is fragile.
- No tests. No packaging (`pyproject`), no i18n (UK strings inline in JS).
- Client-side sort only sorts current page; grid renders full HTML (no virtualization) — slow for >5k rows.

## 3. Product vision

**Positioning:** fast, beautiful, free(-core) DB client. TablePlus-level polish, agent-friendly, safe by default.

### 3.1 Core principles
1. **Safe by default** — connections are read-only unless explicitly switched to write mode (per connection, with color tag e.g. red = prod). Writes go through a review/commit step (TablePlus-style "pending changes").
2. **Fast** — instant open, virtualized grids, pooled sessions, cancelable queries.
3. **Keyboard-first** — every action has a shortcut; command palette (⌘K / ⌘P).
4. **Agent-friendly** — CLI with stable JSON output, same guard, same connection store; an MCP server later.
5. **Native look** — follows OS conventions, light/dark, no "90s" UI.

### 3.2 Feature set (target, both tracks unless noted)
- **Connections manager**: CRUD, groups/folders, color tags, env label (local/dev/stage/prod), read-only flag, SSH tunnel (key/password/agent), TLS, socket, import (from TablePlus/DBeaver/URL `mysql://…`), export without secrets. Test connection.
- **Drivers**: MySQL/MariaDB (P0), PostgreSQL (P0), SQLite (P1), then ClickHouse, MS SQL, Redis (later).
- **Browser**: databases/schemas → tables/views/routines; filter; row estimates; favorites; recently opened.
- **Data grid**: virtualized, sort (server-side), filter builder + raw WHERE, column picker, transpose, row inspector, FK/ref navigation (generic via FK constraints; AWIS ref resolution as plugin), copy as JSON/TSV/CSV/SQL INSERT/Markdown, export to file.
- **Editing** (write mode only): inline edit, add/delete rows, pending-changes panel with generated SQL preview, commit/discard.
- **Structure**: columns, indexes, FKs, DDL view; later: structure editing.
- **SQL editor**: highlighting, schema-aware autocomplete, run statement/selection, multiple result tabs, EXPLAIN visualizer, format SQL, snippets/saved queries, cancel running query.
- **History**: per connection, searchable, errors filter, re-run.
- **Tabs & sessions** restored on relaunch.
- **Plugins**: domain plugins (AWIS/1C refs) hook into: connection discovery, cell renderers, ref resolution, table labels.
- **Later**: ER diagram, data compare, dump/restore, AI assistant (NL→SQL using schema), MCP server.

## 4. Architecture

### 4.1 Track A — Python (cross-platform, agent-first)
```
dbclient/            (package; current db.py/ui.py become modules)
  core/              connection store, guard, executor, pool, formatting
  drivers/           mysql.py (pymysql), postgres.py (psycopg 3), sqlite.py (stdlib)
  plugins/awis/      Config.php discovery, 1C metadata, ref resolver
  cli.py             `dbc conns|ping|tables|desc|q` (current db.py CLI, stable JSON)
  web/               server (stdlib http.server) + static ui/ (vanilla JS, no deps)
```
- Connection store: `~/.config/dbclient/connections.json` (no secrets) + secrets in OS keychain via `keyring` (fallback: env/file with 0600).
- Keep zero-frontend-deps policy (vanilla JS/CSS). Python deps minimal: `pymysql`, `psycopg[binary]`, `keyring`.
- Guard becomes per-dialect; read-only stays default.

### 4.2 Track B — Native macOS (Apple Silicon)
- **Language/UI**: Swift 6 (strict concurrency), SwiftUI for app shell/settings/sidebars + **AppKit `NSTableView`** (wrapped via `NSViewRepresentable`) for the data grid (virtualized, fast for 100k+ rows); SQL editor on `NSTextView` with TextKit 2 highlighting.
- **Targets**: macOS 14+ (Sonoma), arm64 primary (universal optional). Xcode 26 / Swift 6.2 available locally.
- **Project layout**: Xcode app target + local Swift Package(s):
  ```
  native/
    DBClient.xcodeproj (or Tuist/XcodeGen spec)
    Packages/DBCore     connection model, store, guard, query engine protocols
    Packages/DBDrivers  MySQL (MySQLNIO), Postgres (PostgresNIO), SQLite (system sqlite3)
    Packages/DBPlugins  AWIS plugin
    App/                SwiftUI views, AppKit grid & editor
  ```
- **Secrets**: Keychain (`kSecClassGenericPassword`, per connection id). Connection metadata in `~/Library/Application Support/<App>/connections.json`.
- **Networking**: SwiftNIO-based drivers (async/await), SSH tunnels via `swift-nio-ssh`, TLS via NIOSSL.
- **Concurrency**: one actor per connection pool; queries cancelable (`KILL QUERY` / `pg_cancel_backend`).
- **Distribution**: Developer ID signed + notarized DMG; later Sparkle for updates; App Store optional (sandbox limits SSH/socket — evaluate).
- **Shared contract with Track A**: same `connections.json` schema (minus secrets), same history format (JSONL), same guard rules → both tracks + agents interoperate.

### 4.3 Future: Linux / Windows
Options to evaluate when time comes: (a) Python track packaged (PyInstaller) with web UI in a native webview (`pywebview`); (b) Tauri shell around the web UI; (c) Kotlin Compose Desktop / .NET Avalonia. Decision deferred — keep core logic and UI contracts portable (JSON API, shared schemas).

## 5. Shared data formats (contracts)

`connections.json` (no secrets):
```json
{"version": 1, "connections": [{
  "id": "uuid", "name": "awis main", "driver": "mysql", "host": "…", "port": 3306,
  "database": "…", "user": "…", "readOnly": true, "env": "prod", "color": "#d33",
  "group": "work", "ssh": null, "tls": {"mode": "preferred"}, "plugin": "awis"
}]}
```
History JSONL line: `{"ts","conn","sql","source","rows"|"error","elapsed"}` (already used by ui.py).

## 6. Roadmap

| Phase | Scope |
|---|---|
| **0 — Foundation** (now) | git, spec, agent file, skills. |
| **1 — Python generalization** | package layout, connection store + keyring, driver abstraction, Postgres + SQLite, AWIS → plugin, English UI + i18n (uk/en/ru), tests for guard. |
| **2 — Native MVP** | Swift app: connection manager (Keychain), MySQL+Postgres, sidebar, virtualized grid, SQL editor w/ highlighting, history, read-only guard. |
| **3 — Native parity+** | autocomplete, ref/FK navigation, transpose, row inspector, export, editing w/ pending changes, SSH tunnels, command palette. |
| **4 — Polish & ship** | signing/notarization, DMG, auto-update, onboarding, import from TablePlus. |
| **5 — Beyond** | ER diagrams, AI assistant, MCP server, Linux/Windows. |

## 7. Open questions
- Product name (current working name: "DB Client"; brand in code: "AWIS DB").
- License / monetization (free core? open source?).
- Python track: keep stdlib HTTP server or move to a small framework? (current: stdlib, zero deps — preferred).
- Native: XcodeGen/Tuist vs plain .xcodeproj.
- UI language default (current UI is Ukrainian; user writes Russian; docs in English).
