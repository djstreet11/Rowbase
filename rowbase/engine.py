"""Query execution: sessions + pool, read-only enforcement, auto LIMIT, value formatting, catalog helpers.

Read-only connections (the default): guard() + READ ONLY transaction + rollback, one statement per call.
Write-enabled connections skip the guard and commit, still one statement per call.
"""
import datetime
import decimal
import json
import re
import threading
import time
import uuid as uuidlib

from . import drivers, store, tunnel
from .guard import QueryError, analyze, guard

FETCH_CAP = 50_000  # rows kept for statements that already carry their own LIMIT (or SHOW/EXPLAIN/…)

# Long-running callers (web UI) reuse sessions: a new connection over VPN costs ~0.5 s, a statement ~0.05 s.
_pool, _pool_lock = {}, threading.Lock()


def _key(c):
    return c["id"], json.dumps(c, sort_keys=True)  # edited connection => new key, stale sessions never reused


def _take(key):
    with _pool_lock:
        free = _pool.get(key) or []
        return free.pop() if free else None


def _give(key, db):
    with _pool_lock:
        free = _pool.setdefault(key, [])
        if len(free) < 4:
            free.append(db)
            return
    _close(db)


def _close(db):
    try:
        db.close()
    except Exception:
        pass


def reset_pool(conn_id=None):
    with _pool_lock:
        keys = [k for k in _pool if conn_id is None or k[0] == conn_id]
        dbs = [db for k in keys for db in _pool.pop(k)]
    for db in dbs:
        _close(db)


# ---------------------------------------------------------------- formatting

def fmt_value(v, ref_style="uuid"):
    if v is None or isinstance(v, (bool, int, float, str)):
        return v
    if isinstance(v, memoryview):
        v = v.tobytes()
    if isinstance(v, (bytes, bytearray)):
        b = bytes(v)
        if len(b) == 16 and ref_style == "uuid":
            return str(uuidlib.UUID(bytes=b))
        try:
            return b.decode("utf-8")
        except UnicodeDecodeError:
            return "0x" + b.hex().upper()
    if isinstance(v, decimal.Decimal):
        return str(v)
    if isinstance(v, (dict, list)):
        return json.dumps(v, ensure_ascii=False, default=str)
    return str(v)  # dates, times, intervals, UUID, inet, …


def render(cols, rows, fmt, width=60):
    if fmt == "json":
        return json.dumps([dict(zip(cols, r)) for r in rows], ensure_ascii=False, indent=2)
    if fmt == "tsv":
        out = ["\t".join(cols)]
        out += ["\t".join("" if v is None else str(v).replace("\t", " ").replace("\n", " ") for v in r) for r in rows]
        return "\n".join(out)
    if fmt == "vertical":
        w = max((len(c) for c in cols), default=0)
        return "\n".join(f"*** row {i} ***\n" + "\n".join(f"{c.rjust(w)}: {'NULL' if v is None else v}" for c, v in zip(cols, r))
                         for i, r in enumerate(rows, 1))
    cells = [[("NULL" if v is None else str(v)).replace("\n", "\\n")[:width] for v in r] for r in rows]
    widths = [max([len(c)] + [len(r[i]) for r in cells]) for i, c in enumerate(cols)]
    line = lambda vals: "| " + " | ".join(v.ljust(widths[i]) for i, v in enumerate(vals)) + " |"
    sep = "|-" + "-|-".join("-" * w for w in widths) + "-|"
    return "\n".join([line(cols), sep] + [line(r) for r in cells])


# ---------------------------------------------------------------- execution

def resolve(conn):
    """conn: id/name (looked up in the store) or a dict (unsaved connection, may carry 'password')."""
    if isinstance(conn, dict):
        c = store.normalize(conn)
        c["id"] = conn.get("id") or "unsaved"
        pw = conn.get("password")
        if pw is None and conn.get("id"):
            try:
                pw = store.password(store.get(conn["id"]))
            except QueryError:
                pass
        return c, pw
    c = store.get(conn)
    return c, None


def _open(c, pw, timeout):
    drv = drivers.get(c["driver"])
    if c.get("ssh") and drv.name != "sqlite":
        # connect through a local forward; the driver sees plain 127.0.0.1:<port>
        port = tunnel.open_tunnel(c["ssh"], tunnel.target_of(c, drv.port))
        c = {**{k: v for k, v in c.items() if k not in ("socket", "ssh")}, "host": "127.0.0.1", "port": port}
    try:
        return drv.connect(c, pw if pw is not None else store.password(c), timeout)
    except Exception as e:
        raise QueryError(f"Connection error: {e}")


def execute(conn, sql, limit=100, timeout=30, ref_style="uuid", pooled=False, trusted=False):
    """Run one statement; returns {cols, rows, truncated, elapsed, affected}. Raises QueryError."""
    c, pw = resolve(conn)
    drv = drivers.get(c["driver"])
    ro = c.get("readOnly", True)
    clean, first, bare = guard(sql, drv.dialect) if ro and not trusted else analyze(sql, drv.dialect)
    if not clean:
        raise QueryError("Empty query.")
    limited = (first == "SELECT" or (first == "WITH" and ro)) and \
        not re.search(r"\bLIMIT\s+\d+(\s*,\s*\d+)?(\s+OFFSET\s+\d+)?\s*$", bare, re.I)
    if limited:
        clean = f"{clean}\nLIMIT {int(limit) + 1}"
    key = _key(c)
    db = _take(key) if pooled else None
    for attempt in (0, 1):
        try:
            if db is None:
                db = _open(c, pw, timeout)
            drv.begin(db, ro, timeout)
            break
        except QueryError:
            raise
        except Exception as e:  # a pooled session may have been dropped by the server: retry once with a new one
            if db is not None:
                _close(db)
            db = None
            if attempt:
                raise QueryError(f"Connection error: {e}")
    healthy, ok = True, False
    try:
        started = time.monotonic()
        try:
            cur = drv.run(db, clean)
            desc = cur.description
            rows = cur.fetchmany(int(limit) + 1 if limited else FETCH_CAP + 1) if desc else []
            affected = None if desc else cur.rowcount
        except Exception as e:  # SQL errors are expected while exploring; report them plainly
            healthy = drv.alive(db)
            msg = str(e).strip()
            if "interrupted" in msg.lower() or "timeout" in msg.lower() or "max_execution_time" in msg.lower():
                msg += f" (timeout {timeout}s)"
            raise QueryError(f"SQL error: {msg}")
        elapsed = time.monotonic() - started
        cols = [d[0] for d in desc] if desc else []
        ok = True
    finally:
        try:
            if ok and not ro:
                db.commit()
            else:
                db.rollback()
        except Exception:
            healthy = False
        if pooled and healthy and drv.alive(db):
            _give(key, db)
        else:
            _close(db)
    cap = int(limit) if limited else FETCH_CAP
    truncated = len(rows) > cap
    rows = [[fmt_value(v, ref_style) for v in r] for r in rows[:cap]]
    return {"cols": cols, "rows": rows, "truncated": truncated, "elapsed": elapsed, "affected": affected}


def _meta(conn, sql, pooled=True):
    return execute(conn, sql, limit=FETCH_CAP, timeout=60, pooled=pooled, trusted=True)["rows"]


# ---------------------------------------------------------------- catalog

def dialect(conn):
    return drivers.get(resolve(conn)[0]["driver"])


def ping(conn):
    drv = dialect(conn)
    r = execute(conn, drv.version_sql(), limit=1, timeout=10, trusted=True)
    return {"version": r["rows"][0][0], "elapsed": r["elapsed"]}


def tables(conn, pooled=True):
    return [{"name": r[0], "rows": int(r[1]) if r[1] is not None else None, "kind": r[2]} for r in _meta(conn, dialect(conn).tables_sql(), pooled)]


def table_info(conn, table, pooled=True):
    drv = dialect(conn)
    fks = {r[0]: {"table": r[1], "column": r[2]} for r in _meta(conn, drv.fks_sql(table), pooled)}
    cols = [{"name": r[0], "type": r[1], "nullable": bool(r[2]), "key": r[3] or "", "default": fmt_value(r[4]),
             "comment": r[5] or "", "fk": fks.get(r[0])} for r in _meta(conn, drv.columns_sql(table), pooled)]
    if not cols:
        raise QueryError(f"Table '{table}' not found.")
    return {"name": table, "quoted": drv.ident(table), "driver": drv.name, "columns": cols,
            "indexes": [{"name": r[0], "unique": bool(r[1]), "cols": r[2]} for r in _meta(conn, drv.indexes_sql(table), pooled)],
            "referencedBy": [{"table": r[0], "column": r[1], "refColumn": r[2]} for r in _meta(conn, drv.refby_sql(table), pooled)]}
