---
name: run-ui
description: Launch and verify the Rowbase local web UI (rowbase/server.py + rowbase/static/). Use when asked to run/open/screenshot the web UI or to verify a frontend or API change.
---

# run-ui — start the Python web UI

1. Deps: `[ -x .venv/bin/rowbase ] || (python3 -m venv .venv && .venv/bin/pip -q install -e .)`
2. Use the scratch store unless the user wants their real connections:
   `ROWBASE_HOME=$PWD/.scratch-home ROWBASE_SECRETS=file .venv/bin/rowbase ui --port 8765 --no-open` (run_in_background).
   Scratch store may need connections: see `db-query` (`rowbase add`); local MariaDB/Postgres DB `rowbase_test` is created by tests.
3. Open `http://127.0.0.1:8765/` in the built-in browser (`preview_start` with url). Only `127.0.0.1`/`localhost` Host is
   accepted; API needs header `X-Rowbase: 1` (`curl -H 'X-Rowbase: 1' 127.0.0.1:8765/api/conns`).
4. Static files are read per request → `static/*` edits need only a reload; Python edits need a restart.
5. Verify: `get_page_text`/`read_page`, `read_console_messages` (onlyErrors), click through: connection manager, table tab,
   FK link, row drawer, console run, history. Check dark mode via `resize_window colorScheme`.
6. Stop the server when done (`kill $(lsof -ti :8765)`).

Browser state: localStorage `tabs`, `activeTab`, `conn` (id), `hide:<connId>:<table>`. History: `$ROWBASE_HOME/history.jsonl`.
