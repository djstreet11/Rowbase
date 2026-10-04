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

from . import edit, engine, store
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


def run_edit(body):
    cid, db = ref(body["conn"], body.get("db"))
    c = store.get(cid)
    res = edit.apply(engine.with_database(c["id"], db), body["table"], body.get("changes") or [], dry_run=bool(body.get("dryRun")))
    if not body.get("dryRun") and res["statements"]:
        for sql in res["statements"]:
            history_add({"conn": c["id"], "connName": c["name"], "sql": sql, "source": "edit", "affected": 1, **({"db": db} if db else {})})
        drop_cache(c["id"])
    return res


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
        except (QueryError, ValueError, KeyError) as e:
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
            "/api/history": lambda: history_read(int(p.get("limit") or 500), p.get("conn") and ref(p["conn"])[0]),
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
        routes = {
            "/api/query": lambda: run_query(body),
            "/api/conns/save": lambda: conn_save(body),
            "/api/conns/delete": lambda: conn_delete(body),
            "/api/conns/test": lambda: conn_test(body),
            "/api/edit": lambda: run_edit(body),
            "/api/refresh": lambda: drop_cache(body.get("conn")) or {"ok": True},
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
