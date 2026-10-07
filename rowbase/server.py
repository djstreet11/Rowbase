"""Local web UI server: static files from ./static + JSON API. Listens on 127.0.0.1 only.

Same engine/guard as the CLI. Executed queries are appended to ~/.config/rowbase/history.jsonl.
API requests must carry `X-Rowbase: 1` (blocks cross-site requests) and a localhost Host header (blocks DNS rebinding).
"""
import datetime
import json
import os
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from . import edit, engine, export, query, refs, store, update
from .guard import QueryError

STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")
STATIC_TYPES = {"index.html": "text/html", "app.css": "text/css", "app.js": "application/javascript"}

_cache, _lock = {}, threading.Lock()


def cached(key, fn):
    with _lock:
        if key in _cache:
            return _cache[key]
    value = fn()
    with _lock:
        _cache[key] = value
    return value


def ref(key, db=None):
    """UI connection key '<id>' or '<id>::<database>' (database override) -> (id, db)."""
    cid, _, kdb = str(key).partition("::")
    return cid, (db or kdb or None)


def conn_for(key, db=None):
    cid, db = ref(key, db)
    return engine.with_database(cid, db)


def drop_cache(conn_id=None):
    conn_id = conn_id and ref(conn_id)[0]
    with _lock:
        for k in [k for k in _cache if conn_id is None or k[1] == conn_id]:
            del _cache[k]
    engine.reset_pool(conn_id)
    refs.clear()


# ---------------------------------------------------------------- history

def history_add(entry):
    entry = {"ts": datetime.datetime.now().isoformat(timespec="seconds"), **entry}
    with _lock:
        os.makedirs(store.HOME, mode=0o700, exist_ok=True)
        with open(store.HISTORY, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
        if os.path.getsize(store.HISTORY) > 2_000_000:  # keep the file small: last 2000 entries
            with open(store.HISTORY, encoding="utf-8") as f:
                lines = f.readlines()[-2000:]
            with open(store.HISTORY, "w", encoding="utf-8") as f:
                f.writelines(lines)


def history_read(limit, conn=None):
    if not os.path.exists(store.HISTORY):
        return []
    out = []
    with open(store.HISTORY, encoding="utf-8") as f:
        lines = f.readlines()
    for line in reversed(lines):
        try:
            h = json.loads(line)
        except ValueError:
            continue
        if not conn or h.get("conn") == conn:
            out.append(h)
            if len(out) >= limit:
                break
    return out


# ---------------------------------------------------------------- API

def conns_list():
    return [store.public(c) for c in store.load()]


def conn_save(body):
    c = store.upsert(body.get("conn") or {}, body.get("password"))
    drop_cache(c["id"])
    return store.public(c)


def conn_delete(body):
    c = store.delete(body["id"])
    drop_cache(c["id"])
    return {"ok": True}


def conn_test(body):
    """Test a saved connection ({id}) or unsaved form data ({conn, password}); password=None reuses the stored one."""
    if body.get("conn"):
        data = dict(body["conn"])
        if body.get("password") is not None:
            data["password"] = body["password"]
        return engine.ping(data)
    return engine.ping(body["id"])


def run_query(body):
    cid, db = ref(body["conn"], body.get("db"))
    c = store.get(cid)
    limit = max(1, min(int(body.get("limit") or 100), 5000))
    entry = {"conn": c["id"], "connName": c["name"], "sql": body["sql"], "source": body.get("source", ""),
             **({"db": db} if db else {})}
    try:
        res = engine.execute(engine.with_database(c["id"], db), body["sql"], limit=limit,
                             timeout=int(body.get("timeout") or 30), pooled=True)
    except QueryError as e:
        if body.get("history", True):
            history_add({**entry, "error": str(e)})
        raise
    if body.get("history", True):
        history_add({**entry, "rows": len(res["rows"]), "elapsed": round(res["elapsed"], 3),
                     **({"affected": res["affected"]} if res["affected"] is not None else {})})
    if not c.get("readOnly", True) and res["affected"] is not None:
        drop_cache(c["id"])  # DDL/DML may have changed the schema or row counts
    return res


EXPORT_MAX = 1_000_000


def run_export(body):
    """Re-runs the statement with a high row cap and returns (filename, mime, bytes)."""
    cid, db = ref(body["conn"], body.get("db"))
    c = store.get(cid)
    fmt = body.get("format", "csv")
    if fmt not in export.FORMATS:
        raise QueryError(f"Unknown export format '{fmt}'")
    limit = max(1, min(int(body.get("limit") or 100_000), EXPORT_MAX))
    conn = engine.with_database(c["id"], db)
    res = engine.execute(conn, body["sql"], limit=limit, timeout=int(body.get("timeout") or 120), pooled=True, fetch_cap=limit)
    text = export.render(res["cols"], res["rows"], fmt, body.get("table"), engine.dialect(conn))
    history_add({"conn": c["id"], "connName": c["name"], "sql": body["sql"], "source": f"export:{fmt}", "rows": len(res["rows"]),
                 "elapsed": round(res["elapsed"], 3), **({"db": db} if db else {})})
    name = "".join(ch if ch.isalnum() or ch in "-_." else "_" for ch in (body.get("table") or "export"))
    return f"{name}.{fmt}", export.FORMATS[fmt], text.encode(), res["truncated"]


def run_edit(body):
    cid, db = ref(body["conn"], body.get("db"))
    c = store.get(cid)
    res = edit.apply(engine.with_database(c["id"], db), body["table"], body.get("changes") or [], dry_run=bool(body.get("dryRun")))
    if not body.get("dryRun") and res["statements"]:
        for sql in res["statements"]:
            history_add({"conn": c["id"], "connName": c["name"], "sql": sql, "source": "edit", "affected": 1, **({"db": db} if db else {})})
        drop_cache(c["id"])
    return res


def _types(key, db, table):
    info = cached(("table", *ref(key, db), table), lambda: engine.table_info(conn_for(key, db), table))
    return {c["name"]: c["type"] for c in info["columns"]}


def run_build(body):
    """Column filters → WHERE text ({table, filters}) or a visual query spec → SELECT ({query}); see rowbase/query.py."""
    conn, db = body["conn"], body.get("db")
    drv = engine.dialect(conn_for(conn, db))
    if "query" in body:
        spec = body["query"]
        sources = [spec.get("from") or {}] + list(spec.get("joins") or [])
        types = {s.get("as") or s["table"]: _types(conn, db, s["table"]) for s in sources if s.get("table")}
        return {"sql": query.select_sql(drv, spec, types)}
    return {"where": query.filter_where(drv, body.get("filters"), _types(conn, db, body["table"]) if body.get("table") else {})}


def run_values(body):
    """Distinct values + counts of one column for the filter popover (other filters applied via `where`)."""
    conn, db, table, col = body["conn"], body.get("db"), body["table"], body["column"]
    c = conn_for(conn, db)
    limit = max(1, min(int(body.get("limit") or 200), 1000))
    sql = query.values_sql(engine.dialect(c), table, col, body.get("where") or "", body.get("search") or "",
                           _types(conn, db, table).get(col, ""), limit + 1)
    res = engine.execute(c, sql, limit=limit + 1, timeout=int(body.get("timeout") or 15), pooled=True)
    return {"values": res["rows"][:limit], "truncated": len(res["rows"]) > limit, "elapsed": res["elapsed"], "sql": sql}


def version_info(force=False):
    if update.disabled() and not force:
        return {"current": update.__version__, "latest": None, "available": False, "disabled": True}
    return update.check(force)


def run_update(port):
    """Swap the one-file binary, then re-exec it on the same port (the page polls /api/version and reloads)."""
    v = update.self_update()
    exe = update.executable()
    threading.Timer(0.3, lambda: os.execv(exe, [exe, "ui", "--port", str(port), "--no-open"])).start()
    return {"ok": True, "version": v}


class Handler(BaseHTTPRequestHandler):
    server_version = "rowbase"

    def log_message(self, fmt, *args):
        pass

    def send(self, code, body, ctype="application/json; charset=utf-8"):
        data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False, default=str).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def allowed(self, api):
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0]
        if host not in ("127.0.0.1", "localhost", "[::1]"):
            return False
        return not api or self.headers.get("X-Rowbase") == "1"

    def handle_api(self, fn):
        try:
            return self.send(200, fn())
        except (QueryError, ValueError, KeyError, RuntimeError) as e:
            return self.send(400, {"error": str(e) if not isinstance(e, KeyError) else f"Missing field {e}"})
        except Exception as e:
            return self.send(500, {"error": f"{type(e).__name__}: {e}"})

    def do_GET(self):
        url = urlparse(self.path)
        p = {k: v[0] for k, v in parse_qs(url.query).items()}
        if not self.allowed(url.path.startswith("/api/")):
            return self.send(403, {"error": "forbidden"})
        name = "index.html" if url.path == "/" else url.path.lstrip("/")
        if name in STATIC_TYPES:
            with open(os.path.join(STATIC_DIR, name), "rb") as f:
                return self.send(200, f.read(), STATIC_TYPES[name] + "; charset=utf-8")
        routes = {
            "/api/conns": conns_list,
            "/api/databases": lambda: engine.databases(conn_for(p["conn"], p.get("db"))),
            "/api/tables": lambda: cached(("tables", *ref(p["conn"], p.get("db"))), lambda: engine.tables(conn_for(p["conn"], p.get("db")))),
            "/api/table": lambda: cached(("table", *ref(p["conn"], p.get("db")), p["name"]),
                                         lambda: engine.table_info(conn_for(p["conn"], p.get("db")), p["name"])),
            "/api/settings": store.settings,
            "/api/mcp/config": lambda: __import__("rowbase.mcp", fromlist=["mcp"]).client_config(),
            "/api/history": lambda: history_read(int(p.get("limit") or 500), p.get("conn") and ref(p["conn"])[0]),
            "/api/version": lambda: version_info(p.get("force") == "1"),
            "/api/reftables": lambda: {"count": len(refs.ref_tables(conn_for(p["conn"], p.get("db"))))},
        }
        if url.path in routes:
            return self.handle_api(routes[url.path])
        return self.send(404, {"error": "not found"})

    def do_POST(self):
        url = urlparse(self.path)
        if not self.allowed(True):
            return self.send(403, {"error": "forbidden"})
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        except ValueError:
            return self.send(400, {"error": "bad JSON"})
        if url.path == "/api/export":
            try:
                name, mime, data, truncated = run_export(body)
            except (QueryError, ValueError, KeyError) as e:
                return self.send(400, {"error": str(e)})
            self.send_response(200)
            self.send_header("Content-Type", mime + "; charset=utf-8")
            self.send_header("Content-Disposition", f'attachment; filename="{name}"')
            self.send_header("X-Rowbase-Rows-Truncated", "1" if truncated else "0")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        routes = {
            "/api/query": lambda: run_query(body),
            "/api/conns/save": lambda: conn_save(body),
            "/api/conns/delete": lambda: conn_delete(body),
            "/api/conns/test": lambda: conn_test(body),
            "/api/edit": lambda: run_edit(body),
            "/api/build": lambda: run_build(body),
            "/api/values": lambda: run_values(body),
            "/api/settings": lambda: store.save_settings(body),
            "/api/update": lambda: run_update(self.server.server_address[1]),
            "/api/refresh": lambda: drop_cache(body.get("conn")) or {"ok": True},
            "/api/resolve": lambda: refs.resolve(conn_for(body["conn"], body.get("db")), body.get("value") or "",
                                                 body.get("table"), body.get("column"), body.get("hint")),
        }
        if url.path in routes:
            return self.handle_api(routes[url.path])
        return self.send(404, {"error": "not found"})


def make_server(port=8765):
    return ThreadingHTTPServer(("127.0.0.1", port), Handler)


def serve(port=8765, open_browser=True):
    srv = make_server(port)
    url = f"http://127.0.0.1:{srv.server_address[1]}/"
    print(f"Rowbase UI: {url}  (Ctrl+C to stop)")
    if open_browser:
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
