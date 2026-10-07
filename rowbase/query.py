"""Column filters and the visual query builder → SQL. Shared contract (SPEC §5.5) with native/RowbaseCore/QueryBuilder.swift;
pinned by tests/query_vectors.json — change the output deliberately and regenerate both suites.

Condition:  {"col": "name", "src": "o"?, "op": "contains", "value": "x", "value2": "y"?, "values": ["a", null]?}
Group:      {"match": "all"|"any", "conds": [condition | group, …]}
Query spec: {"from": {"table": "orders", "as": "o"}, "joins": [{"type": "left", "table": "customers", "as": "c",
             "on": [{"left": {"src": "c", "col": "id"}, "right": {"src": "o", "col": "customer_id"}}]}],
             "columns": [{"src": "o", "col": "id", "agg": "count"?, "as": "n"?}], "distinct": false,
             "where": group, "orderBy": [{"src": "o", "col": "id", "agg"?, "dir": "desc"}], "limit": 100}
types: {source key (alias or table): {column: declared type}} — picks literal style (numbers, MySQL BINARY(16) UUIDs, hex).
Incomplete conditions (no value, empty list) are skipped, so a half-filled builder still produces valid SQL.
"""
import re

# op -> (label, arity) — arity: 0 none, 1 value, 2 value + value2, "n" values list
OPS = {
    "eq": ("=", 1), "ne": ("≠", 1), "gt": (">", 1), "ge": ("≥", 1), "lt": ("<", 1), "le": ("≤", 1),
    "contains": ("contains", 1), "not_contains": ("doesn't contain", 1), "starts": ("starts with", 1), "ends": ("ends with", 1),
    "like": ("LIKE", 1), "not_like": ("NOT LIKE", 1), "regex": ("matches regex", 1),
    "between": ("between", 2), "in": ("is one of", "n"), "not_in": ("is not one of", "n"),
    "null": ("is NULL", 0), "not_null": ("is not NULL", 0), "empty": ("is empty", 0), "not_empty": ("is not empty", 0),
}
AGGS = {"count": "COUNT({})", "count_distinct": "COUNT(DISTINCT {})", "sum": "SUM({})", "avg": "AVG({})", "min": "MIN({})", "max": "MAX({})"}
JOINS = {"inner": "INNER JOIN", "left": "LEFT JOIN", "right": "RIGHT JOIN"}
NUMERIC = re.compile(r"^(?:(?:tiny|small|medium|big)?int|integer|dec|decimal|numeric|real|double|float|"
                     r"serial|bigserial|smallserial)\b", re.I)
PG_TEXT = re.compile(r"char|text|^name$", re.I)
BINARY = re.compile(r"binary|blob|bytea", re.I)
NUMBER = re.compile(r"-?\d+(?:\.\d+)?")
UUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
HEX = re.compile(r"0x([0-9a-fA-F]+)")
SIMPLE = re.compile(r"[a-z_][a-z0-9_]{0,62}")
RESERVED = set("ALL AND ANY AS ASC BETWEEN BY CASE CROSS DESC DISTINCT DO ELSE END EXISTS FOR FROM FULL GROUP HAVING IF IN INNER INTO "
               "IS JOIN KEY LEFT LIKE LIMIT NATURAL NOT NULL OFFSET ON OR ORDER OUTER RIGHT SELECT SET TABLE THEN TO UNION USING "
               "VALUES WHEN WHERE WITH".split())


def _q(drv, name):
    return drv.q + str(name).replace(drv.q, drv.q * 2) + drv.q


def alias(drv, name):
    """Table/column alias: bare when it is a plain lowercase word, quoted otherwise."""
    name = str(name)
    return name if SIMPLE.fullmatch(name) and name.upper() not in RESERVED else _q(drv, name)


def literal(drv, v, typ=""):
    if v is None:
        return "NULL"
    v, typ = str(v), typ or ""
    if drv.name == "mysql" and typ.lower() == "binary(16)" and UUID.fullmatch(v):
        return f"UNHEX('{v.replace('-', '').upper()}')"
    if BINARY.search(typ) and HEX.fullmatch(v):
        h = HEX.fullmatch(v).group(1).upper()
        return f"'\\x{h.lower()}'::bytea" if drv.name == "postgres" else f"X'{h}'"
    if NUMBER.fullmatch(v) and (NUMERIC.search(typ) or (drv.name == "sqlite" and not typ)):
        return v
    return drv.lit(v)


def _like_escape(s):
    return s.replace("!", "!!").replace("%", "!%").replace("_", "!_")


def cond_sql(drv, c, ref, typ=""):
    """One condition on an already-quoted column reference; None when incomplete."""
    op, v, v2 = c.get("op") or "eq", c.get("value"), c.get("value2")
    if op not in OPS:
        raise ValueError(f"Unknown filter operator '{op}'")
    lit = lambda x: literal(drv, x, typ)
    pg = drv.name == "postgres"
    text = f"CAST({ref} AS TEXT)" if pg and not PG_TEXT.search(typ or "") else ref  # LIKE/regex on any type
    like = "ILIKE" if pg else "LIKE"
    with_nulls = lambda s: f"({s} OR {ref} IS NULL)"  # "everything except X" keeps NULL rows
    if op in ("null", "not_null"):
        return f"{ref} IS {'NOT ' if op == 'not_null' else ''}NULL"
    if op == "empty":
        return f"{text} = ''"
    if op == "not_empty":
        return f"{text} <> ''"
    if op in ("in", "not_in"):
        vals = c.get("values") or []
        nn = [x for x in vals if x is not None]
        has_null = len(nn) < len(vals)
        if not vals:
            return None
        lst = f" = {lit(nn[0])}" if len(nn) == 1 else f" IN ({', '.join(lit(x) for x in nn)})"
        if op == "in":
            parts = ([ref + lst] if nn else []) + ([f"{ref} IS NULL"] if has_null else [])
            return parts[0] if len(parts) == 1 else f"({parts[0]} OR {parts[1]})"
        if not nn:
            return f"{ref} IS NOT NULL"
        neg = f"{ref} <> {lit(nn[0])}" if len(nn) == 1 else f"{ref} NOT IN ({', '.join(lit(x) for x in nn)})"
        return neg if has_null else with_nulls(neg)
    if op == "between":
        if v in (None, "") and v2 in (None, ""):
            return None
        if v2 in (None, ""):
            return f"{ref} >= {lit(v)}"
        if v in (None, ""):
            return f"{ref} <= {lit(v2)}"
        return f"{ref} BETWEEN {lit(v)} AND {lit(v2)}"
    if v is None:
        return f"{ref} IS {'NOT ' if op == 'ne' else ''}NULL" if op in ("eq", "ne") else None
    v = str(v)
    if op in ("eq", "ne", "gt", "ge", "lt", "le"):
        s = f"{ref} {({'eq': '=', 'ne': '<>', 'gt': '>', 'ge': '>=', 'lt': '<', 'le': '<='})[op]} {lit(v)}"
        return with_nulls(s) if op == "ne" else s
    if not v:
        return None  # contains "" etc. — nothing to filter yet
    if op in ("contains", "not_contains", "starts", "ends"):
        e = _like_escape(v)
        pat = {"contains": f"%{e}%", "not_contains": f"%{e}%", "starts": f"{e}%", "ends": f"%{e}"}[op]
        s = f"{text} {'NOT ' if op == 'not_contains' else ''}{like} {drv.lit(pat)} ESCAPE '!'"
        return with_nulls(s) if op == "not_contains" else s
    if op in ("like", "not_like"):
        s = f"{text} {'NOT ' if op == 'not_like' else ''}{like} {drv.lit(v)}"
        return with_nulls(s) if op == "not_like" else s
    if drv.name == "sqlite":
        raise ValueError("Regular expressions are not available on SQLite — use contains / LIKE")
    return f"{text} ~* {drv.lit(v)}" if pg else f"{ref} REGEXP {drv.lit(v)}"


def where_sql(drv, group, ref=None, types=None):
    """Group → condition text ('' when empty). ref(cond) -> quoted column reference; types(cond) -> declared type."""
    ref = ref or (lambda c: _q(drv, c["col"]))
    types = types or (lambda c: "")

    def parts(g):
        out = []
        for c in (g or {}).get("conds") or []:
            if "conds" in c:
                sub = parts(c)
                s = (" OR " if _any(c) else " AND ").join(sub)
                if len(sub) > 1 and _any(c) != _any(g):
                    s = f"({s})"  # nested group with the other connective
            else:
                s = cond_sql(drv, c, ref(c), types(c)) if c.get("col") else None
            if s:
                out.append(s)
        return out

    return (" OR " if _any(group) else " AND ").join(parts(group))


def _any(group):
    return (group or {}).get("match") == "any"


def filter_where(drv, group, types=None):
    """Column filters of one table: unqualified columns; types = {column: declared type}."""
    types = types or {}
    return where_sql(drv, group, types=lambda c: types.get(c["col"], ""))


def select_sql(drv, spec, types=None):
    types = types or {}
    src = spec.get("from") or {}
    if not src.get("table"):
        raise ValueError("Choose a table")
    joins = [j for j in spec.get("joins") or [] if j.get("table")]
    sources = [src] + joins
    keys = {s.get("as") or s["table"]: s for s in sources}
    qualify = bool(joins)
    default = src.get("as") or src["table"]

    def key(c):
        return c.get("src") or default

    def ref(c):
        col = "*" if c["col"] == "*" else _q(drv, c["col"])
        if not qualify:
            return col
        s = keys.get(key(c))
        if s is None:
            raise ValueError(f"Unknown table '{key(c)}' in column {c['col']}")
        return f"{alias(drv, s['as']) if s.get('as') else drv.ident(s['table'])}.{col}"

    def expr(c):
        if c.get("agg"):
            if c["agg"] not in AGGS:
                raise ValueError(f"Unknown aggregate '{c['agg']}'")
            if c["col"] == "*":
                if c["agg"] != "count":
                    raise ValueError(f"{c['agg'].upper()} needs a column, not *")
                return "COUNT(*)"
            return AGGS[c["agg"]].format(ref(c))
        return ref(c)

    def typ(c):
        s = keys.get(key(c))
        return (types.get(key(c)) or (types.get(s["table"]) if s else None) or {}).get(c["col"], "")

    def source(s):
        return drv.ident(s["table"]) + (f" AS {alias(drv, s['as'])}" if s.get("as") else "")

    cols = [c for c in spec.get("columns") or [] if c.get("col")]
    out = ["SELECT " + ("DISTINCT " if spec.get("distinct") else "")
           + (", ".join(expr(c) + (f" AS {alias(drv, c['as'])}" if c.get("as") else "") for c in cols) or "*"),
           "FROM " + source(src)]
    for j in joins:
        on = [f"{ref(p['left'])} = {ref(p['right'])}" for p in j.get("on") or [] if p.get("left", {}).get("col") and p.get("right", {}).get("col")]
        if not on:
            raise ValueError(f"Join with {j['table']} needs at least one column pair")
        out.append(f"{JOINS.get(j.get('type') or 'inner', 'INNER JOIN')} {source(j)} ON {' AND '.join(on)}")
    w = where_sql(drv, spec.get("where"), ref, typ)
    if w:
        out.append("WHERE " + w)
    if any(c.get("agg") for c in cols):
        g = [ref(c) for c in cols if not c.get("agg")]
        if g:
            out.append("GROUP BY " + ", ".join(g))
    order = [o for o in spec.get("orderBy") or [] if o.get("col")]
    if order:
        out.append("ORDER BY " + ", ".join(expr(o) + (" DESC" if (o.get("dir") or "").lower() == "desc" else "") for o in order))
    if spec.get("limit"):
        out.append(f"LIMIT {int(spec['limit'])}")
    return "\n".join(out)


def values_sql(drv, table, col, where="", search="", typ="", limit=200):
    """Distinct values of a column with their counts (column filter popover), most frequent first."""
    ref = _q(drv, col)
    conds = [f"({where})"] if where else []
    if search:
        conds.append(cond_sql(drv, {"op": "contains", "value": search}, ref, typ))
    return (f"SELECT {ref}, COUNT(*) FROM {drv.ident(table)}" + (" WHERE " + " AND ".join(conds) if conds else "")
            + f" GROUP BY {ref} ORDER BY 2 DESC, 1 LIMIT {int(limit)}")
