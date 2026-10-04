"""Row editing: structured changes -> SQL, applied atomically (shared contract with the native app, SPEC §5).

changes = [{"op": "update", "key": {pk: value}, "set": {col: value|None}},
           {"op": "insert", "values": {col: value|None}},
           {"op": "delete", "key": {pk: value}}]
Values are strings (or None = NULL) and always sent as quoted literals — every engine coerces '42' / 'true' to the
column type. Rules: write-enabled connection only; the table needs a primary key and `key` must name exactly the PK
columns; unknown columns and binary columns are refused; every UPDATE/DELETE must hit exactly one row, otherwise the
whole batch is rolled back.
"""
import re
import time

from . import drivers, engine
from .guard import QueryError

BINARY = re.compile(r"binary|blob|bytea", re.I)


def build(drv, info, changes):
    """Validate and turn changes into SQL statements (no database access)."""
    cols = {c["name"]: c for c in info["columns"]}
    pk = [c["name"] for c in info["columns"] if c["key"] == "PRI"]
    q, lit = drv.ident, drv.lit
    col = drv.ident if drv.name != "postgres" else (lambda n: '"' + n.replace('"', '""') + '"')  # PG ident() splits schema.table
    table = info["quoted"]

    def value(v):
        return "NULL" if v is None else lit(str(v))

    def check_cols(names, what):
        for n in names:
            if n not in cols:
                raise QueryError(f"Unknown column '{n}' in {what}.")
            if BINARY.search(cols[n]["type"]):
                raise QueryError(f"Column '{n}' ({cols[n]['type']}) is binary and can't be edited here.")

    def where(key):
        if not pk:
            raise QueryError(f"Table {info['name']} has no primary key — rows can't be identified safely.")
        if sorted(key) != sorted(pk) or any(v is None for v in key.values()):
            raise QueryError(f"Row key must be the primary key ({', '.join(pk)}) with non-NULL values.")
        return " AND ".join(f"{col(k)} = {value(key[k])}" for k in pk)

    out = []
    for i, ch in enumerate(changes, 1):
        op = ch.get("op")
        if op == "update":
            s = ch.get("set") or {}
            if not s:
                continue
            check_cols(s, f"change #{i}")
            out.append(("update", f"UPDATE {table} SET " + ", ".join(f"{col(k)} = {value(v)}" for k, v in s.items())
                        + f" WHERE {where(ch.get('key') or {})}", ch))
        elif op == "delete":
            out.append(("delete", f"DELETE FROM {table} WHERE {where(ch.get('key') or {})}", ch))
        elif op == "insert":
            v = {k: x for k, x in (ch.get("values") or {}).items()}
            check_cols(v, f"change #{i}")
            if v:
                sql = f"INSERT INTO {table} (" + ", ".join(col(k) for k in v) + ") VALUES (" + ", ".join(value(x) for x in v.values()) + ")"
            else:
                sql = f"INSERT INTO {table} () VALUES ()" if drv.name == "mysql" else f"INSERT INTO {table} DEFAULT VALUES"
            out.append(("insert", sql, ch))
        else:
            raise QueryError(f"Change #{i}: unknown op '{op}'.")
    return out


def apply(conn, table, changes, dry_run=False, timeout=30):
    """Returns {statements, affected}. Raises QueryError (nothing committed) on any problem."""
    c, pw = engine.resolve(conn)
    drv = drivers.get(c["driver"])
    if c.get("readOnly", True):
        raise QueryError("Read-only connection: enable writes in the connection settings to edit data.")
    info = engine.table_info(conn, table, pooled=False)
    stmts = build(drv, info, changes)
    if dry_run or not stmts:
        return {"statements": [s for _, s, _ in stmts], "affected": []}
    db = engine._open(c, pw, timeout)
    affected, ok = [], False
    try:
        drv.begin(db, False, timeout)
        started = time.monotonic()
        for n, (op, sql, ch) in enumerate(stmts, 1):
            try:
                cur = drv.run(db, sql)
            except Exception as e:
                raise QueryError(f"Statement {n} failed: {e}\n{sql}")
            count = cur.rowcount
            if op == "update" and count == 0:
                # MySQL reports 0 when the new values equal the old ones: confirm the row exists
                cur = drv.run(db, f"SELECT COUNT(*) FROM {info['quoted']} WHERE " + sql.split(" WHERE ", 1)[1])
                count = cur.fetchone()[0]
            if count != 1:
                raise QueryError(f"Statement {n} affected {count} rows (expected exactly 1) — nothing was saved.\n{sql}")
            affected.append(count)
        db.commit()
        ok = True
        return {"statements": [s for _, s, _ in stmts], "affected": affected, "elapsed": time.monotonic() - started}
    finally:
        if not ok:
            try:
                db.rollback()
            except Exception:
                pass
        engine._close(db)
