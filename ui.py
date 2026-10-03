#!/usr/bin/env python3
"""Local read-only web UI for AWIS MySQL databases.

Same connections and the same read-only guard as db.py (one statement, READ ONLY transaction, rollback).
Listens on 127.0.0.1 only. The page lives in ./ui/ (index.html, app.css, app.js), no third-party JS/CSS.
Executed queries are appended to ~/.config/awis-db/ui-history.jsonl.

    ~/.config/awis-db/.venv/bin/python .agents/skills/awis-db/scripts/ui.py [--port 8765] [--no-open]
"""
import argparse
import datetime
import json
import os
import re
import sys
import threading
import webbrowser
import xml.etree.ElementTree as ET
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import db  # noqa: E402

UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
METADATA = os.path.join(db.WORKSPACE, "awis.loc", "solution", "config", "metadata_full.xml")
KIND_PREFIX = {"Catalogs": "Catalog", "Documents": "Document", "InfoRegs": "InfoReg",
               "ChartsOfCharacteristicTypes": "ChartOfCharacteristicTypes", "AccRegs": "AccReg"}
REF_KIND = {"CatalogRef": "Справочник", "DocumentRef": "Документ", "ChartOfCharacteristicTypesRef": "ПланВидовХарактеристик"}
LABEL_COLS = ("Description", "Number", "Code")
STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ui")
STATIC_TYPES = {"index.html": "text/html", "app.css": "text/css", "app.js": "application/javascript"}
HISTORY = os.path.expanduser("~/.config/awis-db/ui-history.jsonl")
REF_TABLE_RE = re.compile(r"^(Catalog|Document|ChartOf)[A-Za-z0-9]+$")

_cache, _lock = {}, threading.Lock()


def cached(key, fn):
    with _lock:
        if key in _cache:
            return _cache[key]
    value = fn()
    with _lock:
        _cache[key] = value
    return value


def ident(s):
    if not re.fullmatch(r"\w+", s or ""):
        raise db.QueryError(f"Bad identifier: {s!r}")
    return s


def q(conn, sql, limit=20000):
    return db.execute(conn, sql, limit=limit, pooled=True)["rows"]


# ---------------------------------------------------------------- schema

def tables(conn):
    return cached(("tables", conn), lambda: [
        {"name": r[0], "comment": r[1] or "", "rows": r[2]}
        for r in q(conn, "SELECT TABLE_NAME, TABLE_COMMENT, TABLE_ROWS FROM information_schema.TABLES "
                         "WHERE TABLE_SCHEMA = DATABASE() ORDER BY TABLE_NAME")])


def columns(conn, table):
    t = ident(table)
    return cached(("cols", conn, t), lambda: [
        {"name": r[0], "type": r[1], "nullable": r[2] == "YES", "key": r[3], "default": r[4], "comment": r[5] or ""}
        for r in q(conn, "SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY, COLUMN_DEFAULT, COLUMN_COMMENT "
                         f"FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '{t}' "
                         "ORDER BY ORDINAL_POSITION")])


def indexes(conn, table):
    t = ident(table)
    return [{"name": r[0], "unique": not int(r[1]), "cols": r[2]}
            for r in q(conn, "SELECT INDEX_NAME, NON_UNIQUE, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) "
                             f"FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '{t}' "
                             "GROUP BY INDEX_NAME, NON_UNIQUE ORDER BY INDEX_NAME")]


def ref_tables(conn):
    """{table: set(label columns)} for every object table with a char(36) primary key Ref."""
    def build():
        out = {}
        rows = q(conn, "SELECT TABLE_NAME, COLUMN_NAME, COLUMN_KEY, DATA_TYPE FROM information_schema.COLUMNS "
                       "WHERE TABLE_SCHEMA = DATABASE() AND COLUMN_NAME IN ('Ref', 'Number', 'Description', 'Code')")
        for t, c, k, dt in rows:
            if REF_TABLE_RE.match(t):
                out.setdefault(t, {"ref": False, "labels": set()})
                if c == "Ref" and k == "PRI" and dt == "char":
                    out[t]["ref"] = True
                elif c != "Ref":
                    out[t]["labels"].add(c)
        return {t: v["labels"] for t, v in out.items() if v["ref"]}
    return cached(("reftables", conn), build)


def metadata_refs():
    """{(table, column): [1C ref types]} from metadata_full.xml (StoreType of attributes/dimensions)."""
    def build():
        out = {}
        if not os.path.exists(METADATA):
            return out
        root = ET.parse(METADATA).getroot()

        def walk(row, table):
            for vt in row.findall("ValueTable"):
                for r in vt.findall("Rows/Row"):
                    name = r.findtext("Value[@name='Name']")
                    if not name:
                        continue
                    if vt.get("name") == "TabularSections":
                        walk(r, f"{table}_{name}")
                        continue
                    types = [t.text for t in r.findall("TypeDescription[@name='StoreType']/Types/Type") if t.text]
                    refs = [t for t in types if t.split(".")[0] in REF_KIND]
                    if refs:
                        out[(table, name)] = refs
                        out[(table, f"{name}_Ref")] = refs

        for vt in root.findall("ValueTable"):
            prefix = KIND_PREFIX.get(vt.get("name"))
            if prefix:
                for row in vt.findall("Rows/Row"):
                    walk(row, prefix + (row.findtext("Value[@name='Name']") or ""))
        return out
    return cached("metadata", build)


def tables_for_types(conn, types):
    by_comment = {t["comment"]: t["name"] for t in tables(conn) if t["comment"]}
    out = []
    for ty in types:
        kind, _, name = ty.partition(".")
        table = by_comment.get(f"{REF_KIND.get(kind, '')}.{name}")
        if table and table not in out:
            out.append(table)
    return out


# ---------------------------------------------------------------- ref resolution

def lookup(conn, candidates, value):
    known = ref_tables(conn)
    parts = []
    for t in candidates:
        if t in known:
            labels = [c for c in LABEL_COLS if c in known[t]]
            label = "COALESCE(" + ", ".join(f"NULLIF(CAST(`{c}` AS CHAR), '')" for c in labels) + ", '')" if labels else "''"
            parts.append(f"SELECT '{t}' AS t, {label} AS label FROM `{t}` WHERE Ref = '{value}'")
    if not parts:
        return []
    rows = db.execute(conn, " UNION ALL ".join(parts), limit=50, timeout=60, pooled=True)["rows"]
    return [{"table": r[0], "label": r[1] or ""} for r in rows]


def resolve(conn, table, column, value, tref):
    if not UUID_RE.match(value or ""):
        raise db.QueryError("Not a UUID")
    value = value.lower()
    learned = _cache.setdefault(("learned", conn), {})
    key = (table, column)
    if tref:
        cands, how = [tref.replace(".", "")], "TRef"
    elif key in learned:
        cands, how = [learned[key]], "learned"
    else:
        cands = tables_for_types(conn, metadata_refs().get(key, [])) if conn_db(conn) == conn_db("main") else []
        how = "metadata"
        if not cands and column:
            base = re.sub(r"_Ref$", "", column)
            existing = ref_tables(conn)
            cands = [f"{p}{base}{s}" for p in ("Catalog", "Document", "ChartOfCharacteristicTypes")
                     for s in ("", "s", "es") if f"{p}{base}{s}" in existing]
            how = "name"
    matches = lookup(conn, cands, value) if cands else []
    if not matches:
        matches, how = lookup(conn, sorted(ref_tables(conn)), value), "scan"
    if table and column and len(matches) == 1 and how in ("scan", "name"):
        learned[key] = matches[0]["table"]
    return {"matches": matches, "how": how}


def conn_db(conn):
    c = db.load_connections().get(conn, {})
    return (c.get("host"), c.get("database"))


# ---------------------------------------------------------------- history

def history_add(entry):
    entry = {"ts": datetime.datetime.now().isoformat(timespec="seconds"), **entry}
    with _lock:
        with open(HISTORY, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
        if os.path.getsize(HISTORY) > 2_000_000:  # keep the file small: last 2000 entries
            lines = open(HISTORY, encoding="utf-8").readlines()[-2000:]
            open(HISTORY, "w", encoding="utf-8").writelines(lines)


def history_read(limit):
    if not os.path.exists(HISTORY):
        return []
    out = []
    for line in open(HISTORY, encoding="utf-8").readlines()[-limit:]:
        try:
            out.append(json.loads(line))
        except ValueError:
            pass
    return out[::-1]


# ---------------------------------------------------------------- HTTP

class Handler(BaseHTTPRequestHandler):
    server_version = "awis-db-ui"

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
        host = (self.headers.get("Host") or "").split(":")[0]
        if host not in ("127.0.0.1", "localhost"):
            return False
        return not api or self.headers.get("X-AWIS-UI") == "1"  # custom header blocks cross-site requests

    def handle_api(self, fn):
        try:
            return self.send(200, fn())
        except db.QueryError as e:
            return self.send(400, {"error": str(e)})
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
            "/api/conns": lambda: [{"name": n, "db": c.get("database"), "host": c["host"], "alias_of": c.get("alias_of")}
                                   for n, c in sorted(db.load_connections().items(),
                                                      key=lambda kv: (kv[0] != "main", bool(kv[1].get("alias_of")), kv[0]))],
            "/api/tables": lambda: [{"name": t["name"], "rows": t["rows"]} for t in tables(p["conn"])],
            "/api/table": lambda: table_info(p["conn"], p["name"]),
            "/api/history": lambda: history_read(int(p.get("limit") or 500)),
        }
        if url.path in routes:
            return self.handle_api(routes[url.path])
        return self.send(404, {"error": "not found"})

    def do_POST(self):
        url = urlparse(self.path)
        if not self.allowed(True):
            return self.send(403, {"error": "forbidden"})
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        routes = {
            "/api/query": lambda: run_query(body),
            "/api/resolve": lambda: resolve(body["conn"], body.get("table"), body.get("column"), body.get("value"), body.get("tref")),
            "/api/refresh": refresh,
        }
        if url.path in routes:
            return self.handle_api(routes[url.path])
        return self.send(404, {"error": "not found"})


def table_info(conn, name):
    meta = metadata_refs() if conn_db(conn) == conn_db("main") else {}
    cols = [{k: v for k, v in c.items() if k != "comment"} for c in columns(conn, name)]
    for c in cols:
        c["refs"] = tables_for_types(conn, meta.get((name, c["name"]), []))
    return {"columns": cols, "indexes": indexes(conn, name)}


def run_query(body):
    limit = max(1, min(int(body.get("limit") or 100), 5000))
    entry = {"conn": body["conn"], "sql": body["sql"], "source": body.get("source", "")}
    try:
        res = db.execute(body["conn"], body["sql"], limit=limit, timeout=int(body.get("timeout") or 30), pooled=True)
    except db.QueryError as e:
        if body.get("history", True):
            history_add({**entry, "error": str(e)})
        raise
    if body.get("history", True):
        history_add({**entry, "rows": len(res["rows"]), "elapsed": round(res["elapsed"], 3)})
    return res


def refresh():
    with _lock:
        _cache.clear()
    return {"ok": True}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--no-open", action="store_true", help="do not open the browser")
    args = ap.parse_args()
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    url = f"http://127.0.0.1:{args.port}/"
    print(f"AWIS DB UI: {url}  (Ctrl+C to stop)")
    if not args.no_open:
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
