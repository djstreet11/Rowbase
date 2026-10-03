#!/usr/bin/env python3
"""Read-only access to AWIS MySQL databases for agents (Claude Code, Amp) and humans.

Credentials are parsed from awis.loc/solution/config/Config.php (main DB + ExternalDatabaseConnections),
so the tool always follows whatever DB the local AWIS is configured for. Passwords are never printed.

Run with the dedicated venv:  ~/.config/awis-db/.venv/bin/python .agents/skills/awis-db/scripts/db.py <command>
"""
import argparse
import datetime
import decimal
import json
import os
import re
import sys
import threading
import uuid as uuidlib

WORKSPACE = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", ".."))
CONFIG_PHP = os.environ.get("AWIS_CONFIG_PHP", os.path.join(WORKSPACE, "awis.loc", "solution", "config", "Config.php"))
OVERRIDES = os.path.expanduser("~/.config/awis-db/connections.json")

ALLOWED_FIRST_WORDS = {"SELECT", "SHOW", "DESC", "DESCRIBE", "EXPLAIN", "WITH"}
FORBIDDEN_PATTERNS = [r"\bINTO\s+(OUT|DUMP)FILE\b", r"\bFOR\s+UPDATE\b", r"\bLOCK\s+IN\s+SHARE\s+MODE\b",
                      r"\bGET_LOCK\s*\(", r"\bSLEEP\s*\(", r"\bBENCHMARK\s*\("]


# ---------------------------------------------------------------- config

def _strip_php_comments(src):
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    return re.sub(r"(?m)^\s*//.*$|(?<=[,\[\]'\"])\s*//[^\n]*", "", src)


def load_connections():
    """Return {name: {host, port, database, user, password}}; 'main' is the primary AWIS DB."""
    conns = {}
    if os.path.exists(CONFIG_PHP):
        src = _strip_php_comments(open(CONFIG_PHP, encoding="utf-8").read())

        def opt(key):
            m = re.search(r"'%s'\s*=>\s*'([^']*)'" % re.escape(key), src)
            return m.group(1) if m else None

        if opt("DBHost"):
            conns["main"] = {"host": opt("DBHost"), "database": opt("DBName"),
                             "user": opt("DBUser"), "password": opt("DBPassword")}
        ext = re.search(r"'ExternalDatabaseConnections'\s*=>\s*\[(.*?)\n\s{8}\],", src, flags=re.S)
        if ext:
            body = ext.group(1)
            for m in re.finditer(r"'(\w+)'\s*=>\s*\[(.*?)\]", body, flags=re.S):
                kv = dict(re.findall(r"'(\w+)'\s*=>\s*'([^']*)'", m.group(2)))
                if "Host" in kv:
                    conns[m.group(1)] = {"host": kv["Host"], "database": kv.get("Database"),
                                         "user": kv.get("User"), "password": kv.get("Password")}
            for alias, target in re.findall(r"'(\w+)'\s*=>\s*'(\w+)'\s*,?", body):
                if alias not in conns and target in conns:
                    conns[alias] = dict(conns[target], alias_of=target)
    if os.path.exists(OVERRIDES):  # optional: extra/overridden connections kept outside the repo
        for name, c in json.load(open(OVERRIDES)).items():
            conns[name] = {**conns.get(name, {}), **c}
    for c in conns.values():
        h = c.get("host", "")
        if ":" in h and "port" not in c:
            c["host"], c["port"] = h.rsplit(":", 1)
        c["port"] = int(c.get("port", 3306))
    return conns


def connect(conns, name, timeout_s):
    """Open a session that is read-only by default; each statement still runs in START TRANSACTION READ ONLY."""
    import pymysql
    if name not in conns:
        raise QueryError(f"Unknown connection '{name}'. Known: {', '.join(sorted(conns))}")
    c = conns[name]
    db = pymysql.connect(host=c["host"], port=c["port"], user=c["user"], password=c["password"],
                         database=c.get("database"), charset="utf8mb4", connect_timeout=10,
                         read_timeout=max(timeout_s, 60) + 5, autocommit=False)
    db.cursor().execute("SET SESSION TRANSACTION READ ONLY")
    db.awis_timeout = None
    return db


def set_timeout(db, timeout_s):
    if getattr(db, "awis_timeout", None) == timeout_s:
        return
    cur = db.cursor()
    for stmt in (f"SET SESSION max_execution_time={timeout_s * 1000}",   # MySQL
                 f"SET SESSION max_statement_time={timeout_s}"):        # MariaDB
        try:
            cur.execute(stmt)
        except Exception:
            pass
    db.awis_timeout = timeout_s


# Long-running callers (ui.py) reuse sessions: a new connection over VPN costs ~0.5 s, a statement ~0.05 s.
_pool, _pool_lock = {}, threading.Lock()


def _take(name):
    with _pool_lock:
        free = _pool.get(name) or []
        return free.pop() if free else None


def _give(name, db):
    with _pool_lock:
        free = _pool.setdefault(name, [])
        if len(free) < 4:
            free.append(db)
            return
    db.close()


# ---------------------------------------------------------------- SQL guard

def _strip_sql_comments(sql):
    sql = re.sub(r"/\*.*?\*/", " ", sql, flags=re.S)
    return re.sub(r"(--|#)[^\n]*", " ", sql)


def _without_literals(sql):
    return re.sub(r"'(?:[^'\\]|\\.|'')*'|\"(?:[^\"\\]|\\.)*\"|`[^`]*`", "''", sql)


class QueryError(Exception):
    pass


def guard(sql):
    clean = _strip_sql_comments(sql).strip().rstrip(";").strip()
    bare = _without_literals(clean)
    if ";" in bare:
        raise QueryError("Refused: only one statement per call.")
    first = (bare.split(None, 1) or [""])[0].upper()
    if first not in ALLOWED_FIRST_WORDS:
        raise QueryError(f"Refused: read-only tool, '{first}' is not allowed (allowed: {', '.join(sorted(ALLOWED_FIRST_WORDS))}).")
    for p in FORBIDDEN_PATTERNS:
        if re.search(p, bare, flags=re.I):
            raise QueryError(f"Refused: pattern {p} is not allowed.")
    return clean, first, bare



# ---------------------------------------------------------------- formatting

def fmt_value(v, ref_style):
    if v is None:
        return None
    if isinstance(v, (bytes, bytearray)):
        b = bytes(v)
        if len(b) == 16:
            return str(uuidlib.UUID(bytes=b)) if ref_style == "uuid" else b.hex().upper()
        try:
            return b.decode("utf-8")
        except UnicodeDecodeError:
            return "0x" + b.hex().upper()
    if isinstance(v, decimal.Decimal):
        return str(v)
    if isinstance(v, (datetime.datetime, datetime.date, datetime.time, datetime.timedelta)):
        return str(v)
    return v


def render(cols, rows, fmt, width):
    if fmt == "json":
        return json.dumps([dict(zip(cols, r)) for r in rows], ensure_ascii=False, indent=2)
    if fmt == "tsv":
        out = ["\t".join(cols)]
        out += ["\t".join("" if v is None else str(v).replace("\t", " ").replace("\n", " ") for v in r) for r in rows]
        return "\n".join(out)
    if fmt == "vertical":
        w = max((len(c) for c in cols), default=0)
        blocks = []
        for i, r in enumerate(rows, 1):
            blocks.append(f"*** row {i} ***\n" + "\n".join(f"{c.rjust(w)}: {'NULL' if v is None else v}" for c, v in zip(cols, r)))
        return "\n".join(blocks)
    cells = [[("NULL" if v is None else str(v)).replace("\n", "\\n")[:width] for v in r] for r in rows]
    widths = [max([len(c)] + [len(r[i]) for r in cells]) for i, c in enumerate(cols)]
    line = lambda vals: "| " + " | ".join(v.ljust(widths[i]) for i, v in enumerate(vals)) + " |"
    sep = "|-" + "-|-".join("-" * w for w in widths) + "-|"
    return "\n".join([line(cols), sep] + [line(r) for r in cells])


# ---------------------------------------------------------------- commands

def execute(conn, sql, limit=100, timeout=30, ref_style="uuid", pooled=False):
    """Run one guarded read-only statement; returns {cols, rows, truncated, elapsed}. Raises QueryError."""
    clean, first, bare = guard(sql)
    limited = False
    if first in ("SELECT", "WITH") and not re.search(r"\bLIMIT\s+\d+(\s*,\s*\d+)?(\s+OFFSET\s+\d+)?\s*$", bare, re.I):
        clean = f"{clean}\nLIMIT {limit + 1}"
        limited = True
    db = _take(conn) if pooled else None
    for attempt in (0, 1):
        try:
            if db is None:
                db = connect(load_connections(), conn, timeout)
            set_timeout(db, timeout)
            db.cursor().execute("START TRANSACTION READ ONLY")
            break
        except QueryError:
            raise
        except Exception as e:  # a pooled session may have been dropped by the server: retry once with a new one
            if db is not None:
                try:
                    db.close()
                except Exception:
                    pass
            db = None
            if attempt:
                raise QueryError(f"Connection error: {e}")
    healthy = True
    try:
        cur = db.cursor()
        started = datetime.datetime.now()
        try:
            cur.execute(clean)
        except Exception as e:  # SQL errors are expected while exploring; report them plainly
            healthy = db.open
            raise QueryError(f"SQL error: {e}")
        rows = cur.fetchall() if cur.description else []
        elapsed = (datetime.datetime.now() - started).total_seconds()
        cols = [d[0] for d in cur.description] if cur.description else []
    finally:
        try:
            db.rollback()
        except Exception:
            healthy = False
        if pooled and healthy and db.open:
            _give(conn, db)
        else:
            db.close()
    truncated = limited and len(rows) > limit
    rows = [[fmt_value(v, ref_style) for v in r] for r in (rows[:limit] if limited else rows)]
    return {"cols": cols, "rows": rows, "truncated": truncated, "elapsed": elapsed}


def run_sql(args, sql):
    try:
        res = execute(args.conn, sql, args.limit, args.timeout, args.ref)
    except QueryError as e:
        sys.exit(str(e))
    cols, rows = res["cols"], res["rows"]
    text = render(cols, rows, args.format, args.width)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(render(cols, rows, "json" if args.out.endswith(".json") else args.format, 10**9))
        text += f"\n(full result written to {args.out})"
    print(text)
    note = f"-- {len(rows)} row(s), {res['elapsed']:.2f}s, conn={args.conn}"
    if res["truncated"]:
        note += f", TRUNCATED at --limit {args.limit} (add ORDER BY/WHERE or raise --limit)"
    print(note, file=sys.stderr)


def cmd_conns(args):
    for name, c in sorted(load_connections().items()):
        alias = f"  (alias of {c['alias_of']})" if c.get("alias_of") else ""
        print(f"{name:28} {c['user']}@{c['host']}:{c['port']}/{c.get('database') or ''}{alias}")


def cmd_ping(args):
    args.format, args.out = "vertical", None
    run_sql(args, "SELECT VERSION() AS version, DATABASE() AS db, CURRENT_USER() AS user, "
                  "@@transaction_read_only AS read_only, NOW() AS server_time")


def cmd_tables(args):
    like = args.pattern if any(ch in args.pattern for ch in "%_") else f"%{args.pattern}%"
    safe = like.replace("'", "").replace("\\", "")
    run_sql(args, "SELECT TABLE_NAME, TABLE_ROWS AS approx_rows, ENGINE, TABLE_COMMENT FROM information_schema.TABLES "
                  f"WHERE TABLE_SCHEMA = DATABASE() AND (TABLE_NAME LIKE '{safe}' OR TABLE_COMMENT LIKE '{safe}') ORDER BY TABLE_NAME")


def cmd_desc(args):
    t = re.sub(r"[^\w]", "", args.table)
    col_filter = f" AND COLUMN_NAME LIKE '%{re.sub(r'[^\w]', '', args.column)}%'" if args.column else ""
    run_sql(args, "SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE AS nul, COLUMN_KEY AS k, COLUMN_DEFAULT AS def, COLUMN_COMMENT "
                  f"FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '{t}'{col_filter} "
                  "ORDER BY ORDINAL_POSITION")
    if args.indexes:
        run_sql(args, "SELECT INDEX_NAME, NON_UNIQUE, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) AS cols "
                      f"FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '{t}' "
                      "GROUP BY INDEX_NAME, NON_UNIQUE ORDER BY INDEX_NAME")


def cmd_q(args):
    sql = open(args.file, encoding="utf-8").read() if args.file else (args.sql if args.sql != "-" else sys.stdin.read())
    if not sql:
        sys.exit("Give SQL as an argument, '-' for stdin, or --file path.sql")
    run_sql(args, sql)



def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("-c", "--conn", default=os.environ.get("AWIS_DB_CONN", "main"), help="connection name (see `conns`)")
    common.add_argument("--limit", type=int, default=100, help="max rows for SELECT without LIMIT (default 100)")
    common.add_argument("--format", choices=["table", "json", "tsv", "vertical"], default="table")
    common.add_argument("--ref", choices=["hex", "uuid"], default="uuid", help="how to print BINARY(16) refs")
    common.add_argument("--width", type=int, default=60, help="max cell width in table format")
    common.add_argument("--timeout", type=int, default=30, help="statement timeout, seconds")
    common.add_argument("--out", help="write the full result to a file (.json -> JSON)")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("conns", help="list connections parsed from Config.php").set_defaults(fn=cmd_conns)
    sub.add_parser("ping", parents=[common], help="check connectivity and read-only mode").set_defaults(fn=cmd_ping)
    s = sub.add_parser("tables", parents=[common], help="find tables by name/1C-comment substring or LIKE pattern")
    s.add_argument("pattern"); s.set_defaults(fn=cmd_tables)
    s = sub.add_parser("desc", parents=[common], help="columns (and --indexes) of a table")
    s.add_argument("table"); s.add_argument("column", nargs="?"); s.add_argument("--indexes", action="store_true")
    s.set_defaults(fn=cmd_desc)
    s = sub.add_parser("q", parents=[common], help="run one read-only statement")
    s.add_argument("sql", nargs="?"); s.add_argument("-f", "--file"); s.set_defaults(fn=cmd_q)
    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
