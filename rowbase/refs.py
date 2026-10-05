"""Implicit references: UUID values in columns without FK constraints (1C-style schemas and similar).

A value is looked up as the primary key of "ref tables" (single-column PK able to hold a UUID). Candidate order:
sibling type column (Owner_Ref -> Owner_TRef = 'Catalog.Counterparties'), learned target, column-name match
(SenderAddress -> CatalogAddresses), then every ref table. Pure heuristics are pinned by tests/ref_vectors.json,
shared with the native app (RowbaseCore/Refs.swift).
"""
import re
import threading

from . import engine
from .guard import QueryError

EMPTY_UUID = "00000000-0000-0000-0000-000000000000"
_UUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
_STOP = {"ref", "tref", "id", "uuid", "guid", "key", "fk", "type"}
LABELS = ["description", "name", "title", "label", "number", "code"]
_WORD = re.compile(r"[A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z0-9]+|[A-Z0-9]+")


def is_uuid(v):
    return isinstance(v, str) and _UUID.fullmatch(v) is not None and v != EMPTY_UUID


def words(s):
    """Lower-cased words of an identifier: snake_case and camelCase ("HTTPRequestID" -> http, request, id)."""
    out = []
    for part in re.split(r"[^0-9A-Za-z]+", s):
        out += [w.lower() for w in _WORD.findall(part)]
    return out


def _norm(s):
    return re.sub(r"[^0-9a-z]", "", s.lower())


def hint_column(column, columns):
    """Sibling column naming the target type of a polymorphic reference (Owner_Ref -> Owner_TRef, parent_id -> parent_type)."""
    base = column
    for suf in ("_Ref", "_ref", "_REF", "_id", "_Id", "_ID", "_uuid"):
        if base.endswith(suf):
            base = base[:-len(suf)]
            break
    lower = {}
    for c in columns:
        lower.setdefault(c.lower(), c)
    for s in ("_TRef", "_Type", "TRef", "Type"):
        c = lower.get((base + s).lower())
        if c and c != column:
            return c
    return None


def candidates(column, hint, tables):
    """Likely target tables, best first. Empty: no idea (the caller scans every ref table)."""
    if hint:
        h = _norm(hint)
        for t in tables:
            if _norm(t) == h:
                return [t]
    w = [x for x in words(column) if x not in _STOP]
    normed = [_norm(t) for t in tables]
    for n in range(len(w), 0, -1):
        for start in range(len(w) - n, -1, -1):
            p = "".join(w[start:start + n])
            if len(p) < 3:
                continue
            forms = [p, p + "s", p + "es"] + ([p[:-1] + "ies"] if p.endswith("y") else [])
            hits = [t for t, nt in zip(tables, normed) if any(nt.endswith(f) for f in forms)]
            if hits:
                return hits
    return []


def _uuid_capable(t, dialect):
    t = (t or "").lower()
    if "uuid" in t or "(36)" in t or t == "binary(16)":
        return True
    return dialect == "sqlite" and (not t or "text" in t or "char" in t)


def catalog_sql(drv):
    labels = ", ".join(f"'{x}'" for x in LABELS)
    if drv.name == "mysql":
        return ("SELECT TABLE_NAME, GROUP_CONCAT(CASE WHEN COLUMN_KEY = 'PRI' THEN COLUMN_NAME END), SUM(COLUMN_KEY = 'PRI'), "
                "MAX(CASE WHEN COLUMN_KEY = 'PRI' THEN COLUMN_TYPE END), "
                f"GROUP_CONCAT(CASE WHEN LOWER(COLUMN_NAME) IN ({labels}) THEN COLUMN_NAME END) "
                "FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() GROUP BY TABLE_NAME")
    if drv.name == "postgres":
        return (f"SELECT {drv._NAME.format(n='n', c='c')}, MAX(a.attname), COUNT(*), MAX(format_type(a.atttypid, a.atttypmod)), "
                "(SELECT string_agg(l.attname, ',') FROM pg_attribute l WHERE l.attrelid = c.oid AND l.attnum > 0 "
                f"AND NOT l.attisdropped AND lower(l.attname) IN ({labels})) "
                "FROM pg_index i JOIN pg_class c ON c.oid = i.indrelid JOIN pg_namespace n ON n.oid = c.relnamespace "
                "JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY (i.indkey) "
                "WHERE i.indisprimary AND n.nspname NOT IN ('pg_catalog', 'information_schema') GROUP BY 1, c.oid")
    return ("SELECT m.name, (SELECT group_concat(name) FROM pragma_table_info(m.name) WHERE pk > 0), "
            "(SELECT count(*) FROM pragma_table_info(m.name) WHERE pk > 0), (SELECT type FROM pragma_table_info(m.name) WHERE pk = 1), "
            f"(SELECT group_concat(name) FROM pragma_table_info(m.name) WHERE lower(name) IN ({labels})) "
            "FROM sqlite_master m WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite\\_%' ESCAPE '\\'")


def parse_catalog(rows, dialect):
    out = []
    for r in rows:
        if len(r) < 5 or not r[0] or not r[1] or str(r[2]) != "1" or not _uuid_capable(r[3], dialect):
            continue
        have = [x for x in (r[4] or "").split(",") if x]
        labels = [next(h for h in have if h.lower() == lab) for lab in LABELS if any(h.lower() == lab for h in have)]
        out.append({"name": r[0], "pk": r[1], "pkType": r[3] or "", "labels": labels})
    return sorted(out, key=lambda t: t["name"])


def _col(drv, n):
    return drv.ident(n) if drv.name != "postgres" else '"' + n.replace('"', '""') + '"'


def lookup_sql(drv, tables, value):
    """SELECT 'table', label for every table holding `value` as its primary key."""
    v = value.lower()
    cast = "CHAR" if drv.name == "mysql" else "TEXT"
    parts = []
    for t in tables:
        label = ("COALESCE(" + ", ".join(f"NULLIF(CAST({_col(drv, x)} AS {cast}), '')" for x in t["labels"]) + ", '')"
                 if t["labels"] else "''")
        key = f"UNHEX('{v.replace('-', '')}')" if drv.name == "mysql" and t["pkType"].lower() == "binary(16)" else drv.lit(v)
        parts.append(f"SELECT {drv.lit(t['name'])} AS t, {label} AS label FROM {drv.ident(t['name'])} WHERE {_col(drv, t['pk'])} = {key}")
    return " UNION ALL ".join(parts)


# ---------------------------------------------------------------- engine side (cached per connection + database)

_cache, _learned, _lock = {}, {}, threading.Lock()


def _ckey(conn):
    c, _ = engine.resolve(conn)
    return f"{c.get('id')}|{c.get('database') or ''}"


def ref_tables(conn, refresh=False):
    k = _ckey(conn)
    with _lock:
        if not refresh and k in _cache:
            return _cache[k]
    drv = engine.dialect(conn)
    rows = engine.execute(conn, catalog_sql(drv), limit=100000, timeout=60, pooled=True, trusted=True, fetch_cap=100000)["rows"]
    out = parse_catalog(rows, drv.name)
    with _lock:
        _cache[k] = out
    return out


def clear():
    with _lock:
        _cache.clear()


def resolve(conn, value, table=None, column=None, hint=None):
    """{matches: [{table, pk, label}], how} — `value` found as the primary key of these tables."""
    if not is_uuid(value):
        raise QueryError("Not a UUID.")
    drv = engine.dialect(conn)
    allt = ref_tables(conn)
    by = {t["name"]: t for t in allt}
    names = [t["name"] for t in allt]
    lk = (_ckey(conn), table or "", column or "")
    by_hint = (candidates("", hint, names) or [None])[0] if hint else None
    order, how = [], {}
    for n, h in [(by_hint, "hint"), (_learned.get(lk), "learned")] + [(x, "name") for x in candidates(column or "", None, names)]:
        if n and n in by and n not in order:
            order.append(n)
            how.setdefault(n, h)
    cands = [by[n] for n in order]
    rest = [t for t in allt if t["name"] not in order]
    for group, label in ((cands, None), (rest, "scan")):
        found = []
        for i in range(0, len(group), 40):
            rows = engine.execute(conn, lookup_sql(drv, group[i:i + 40], value), limit=50, timeout=30, pooled=True, trusted=True)["rows"]
            found += [{"table": r[0], "pk": by[r[0]]["pk"], "label": r[1] or ""} for r in rows]
        if found:
            via = label or how.get(found[0]["table"], "name")
            if len(found) == 1 and via != "hint" and column:
                _learned[lk] = found[0]["table"]
            return {"matches": found, "how": via}
    return {"matches": [], "how": "scan", "searched": len(allt)}
