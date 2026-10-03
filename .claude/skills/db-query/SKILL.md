---
name: db-query
description: Query a saved database connection (MySQL/MariaDB, PostgreSQL, SQLite) via the rowbase CLI — list/add connections, ping, find tables, describe (columns, FKs, indexes, referenced-by), run one statement. Use when you need real data or schema from a DB.
---

# db-query — DB access via the `rowbase` CLI

Setup (once): `[ -x .venv/bin/rowbase ] || (python3 -m venv .venv && .venv/bin/pip -q install -e .)`; `R=.venv/bin/rowbase`.
For experiments that must not touch the user's real store/Keychain: `export ROWBASE_HOME=$PWD/.scratch-home ROWBASE_SECRETS=file`.

## Connections
```
$R conns                                               # name, driver, ro/RW, env, target (never passwords)
$R add NAME 'postgres://user@host:5432/db?sslmode=require' [--rw] [--env prod] [--group g] [--password-stdin]
$R add NAME 'mysql://user@/db?socket=/tmp/mysql.sock'  # local socket auth
$R add NAME sqlite:///abs/path.db
$R rm NAME
```
Read-only is the default; `--rw` only when the user explicitly wants writes. Password: URL, prompt, or `--password-stdin`
(prefer stdin — no shell history). Never echo passwords.

## Querying (`-c NAME`, or `ROWBASE_CONN`, or the only connection)
```
$R ping -c NAME
$R tables [substr] -c NAME                    # Postgres non-public tables appear as schema.table
$R desc TABLE [column] --indexes -c NAME       # columns + references; --indexes adds indexes and referenced-by
$R q "SELECT …" -c NAME --limit 50 --format json
$R q - < query.sql   |   $R q -f query.sql --out res.json
```
Flags: `--limit` (auto LIMIT for SELECT without one, default 100), `--format table|json|tsv|vertical`, `--timeout` s,
`--ref uuid|hex` (16-byte binary), `--width`.

## Rules & tips
- RO connections allow one statement starting with SELECT/SHOW/DESC/EXPLAIN/WITH/VALUES/TABLE (+PRAGMA on SQLite).
- stderr `TRUNCATED` → narrow with WHERE or raise `--limit`. `--format json` for parsing, `vertical` for wide rows.
- Big tables: filter on indexed columns; check `EXPLAIN` first.
