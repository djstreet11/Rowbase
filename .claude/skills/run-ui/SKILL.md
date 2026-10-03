---
name: run-ui
description: Launch and check the local web UI (ui.py + ui/) to see or verify frontend/API changes. Use when asked to run/open/screenshot the web UI or to verify a ui/ or ui.py change.
---

# run-ui — start the Python web UI

1. Ensure deps: `[ -x .venv/bin/python ] || (python3 -m venv .venv && .venv/bin/pip -q install pymysql)`
2. Start in background (no auto browser): `.venv/bin/python ui.py --port 8765 --no-open` (run_in_background).
3. Open `http://127.0.0.1:8765/` in the built-in browser pane (`preview_start` with url). Must be `127.0.0.1`/`localhost` —
   other Host headers get 403. API calls need header `X-AWIS-UI: 1` (e.g. `curl -H 'X-AWIS-UI: 1' 127.0.0.1:8765/api/conns`).
4. Without configured connections the UI loads but `/api/tables` errors — that's expected; see `db-query` skill for config.
5. Static files are read on every request → edits to `ui/*` need only a page reload; `ui.py`/`db.py` edits need a restart.
6. Verify with `read_page`/`get_page_text` + console errors (`read_console_messages`). Stop the server when done.

State in browser: `localStorage` keys `tabs`, `activeTab`, `conn`, `hide:<conn>:<table>`. History: `~/.config/awis-db/ui-history.jsonl`.
