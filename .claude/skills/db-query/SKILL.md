---
name: db-query
description: Query a configured MySQL/MariaDB database read-only via db.py (list connections, ping, find tables, describe, run SELECT/SHOW/EXPLAIN). Use when you need real data or schema from a DB connection.
---

# db-query — read-only DB access via CLI

Python with `pymysql` is required. System python lacks it → use a venv:
```
[ -x .venv/bin/python ] || (python3 -m venv .venv && .venv/bin/pip -q install pymysql)
PY=.venv/bin/python   # work setup uses ~/.config/awis-db/.venv/bin/python
```

Connections come from `AWIS_CONFIG_PHP` (Config.php) and/or `~/.config/awis-db/connections.json`:
```json
{"local": {"host": "127.0.0.1", "port": 3306, "database": "app", "user": "ro", "password": "…"}}
```
Never print or commit passwords.

## Commands
```
$PY db.py conns                                  # list (no passwords)
$PY db.py ping -c main                           # version, db, user, read_only flag
$PY db.py tables <substr|LIKE%>                  # find tables by name/comment
$PY db.py desc <table> [column] --indexes        # columns (+ indexes)
$PY db.py q "SELECT … " --limit 50 --format json # one statement
$PY db.py q - < query.sql    |   $PY db.py q -f query.sql --out res.json
```
Common flags: `-c/--conn` (default `$AWIS_DB_CONN` or `main`), `--limit` (auto-added to SELECT without LIMIT, default 100),
`--format table|json|tsv|vertical`, `--ref uuid|hex`, `--width`, `--timeout` seconds.

## Rules & tips
- Only `SELECT SHOW DESC DESCRIBE EXPLAIN WITH`; one statement; no `FOR UPDATE`, `SLEEP`, `INTO OUTFILE`… (guard refuses).
- Stderr line `TRUNCATED` → add WHERE/ORDER BY or raise `--limit`.
- Prefer `--format json` for machine parsing, `vertical` for wide single rows.
- Big tables: always filter by indexed columns; check with `q "EXPLAIN …"` first.
