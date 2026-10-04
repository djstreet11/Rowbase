"""rowbase — database client CLI for humans and agents (read-only by default).

    rowbase add NAME URL [--rw] [--env prod]   # mysql://u@host/db, postgres://u@host/db, sqlite:///path.db
    rowbase conns | ping | tables [PATTERN] | desc TABLE [--indexes] | q "SELECT …" | ui
Passwords: from the URL, a prompt, or --password-stdin; stored in the OS keychain, never printed.
"""
import argparse
import getpass
import os
import sys

from . import engine, store
from .guard import QueryError


def _out(args, cols, rows, note=""):
    text = engine.render(cols, rows, args.format, args.width)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(engine.render(cols, rows, "json" if args.out.endswith(".json") else args.format, 10**9))
        text += f"\n(full result written to {args.out})"
    print(text)
    if note:
        print(note, file=sys.stderr)


def run_sql(args, sql):
    res = engine.execute(args.conn, sql, args.limit, args.timeout, args.ref)
    c = store.get(args.conn)
    note = f"-- {len(res['rows'])} row(s), {res['elapsed']:.2f}s, conn={c['name']}"
    if res["affected"] is not None:
        note = f"-- {res['affected']} row(s) affected, {res['elapsed']:.2f}s, conn={c['name']}"
    if res["truncated"]:
        note += f", TRUNCATED at --limit {args.limit} (add WHERE/ORDER BY or raise --limit)"
    if res["cols"]:
        _out(args, res["cols"], res["rows"], note)
    else:
        print(note, file=sys.stderr)  # DDL/DML: no result table


def cmd_conns(args):
    for c in store.load():
        where = c.get("path") or f"{c.get('user') or ''}@{c.get('socket') or c.get('host') or ''}" \
                                 f"{':' + str(c['port']) if c.get('port') else ''}/{c.get('database') or ''}"
        flags = ("ro" if c.get("readOnly", True) else "RW") + (f" {c['env']}" if c.get("env") else "")
        print(f"{c['name']:24} {c['driver']:9} {flags:9} {where}")


def cmd_add(args):
    fields, pw = store.parse_url(args.url)
    if args.password_stdin:
        pw = sys.stdin.readline().rstrip("\n")
    elif pw is None and fields["driver"] != "sqlite" and sys.stdin.isatty():
        pw = getpass.getpass(f"Password for {fields.get('user') or 'user'} (empty = none): ")
    existing = next((c for c in store.load() if c["name"].lower() == args.name.lower()), None)
    if existing and not args.replace:
        sys.exit(f"Connection '{args.name}' exists (use --replace).")
    c = store.upsert({**fields, "id": existing and existing["id"], "name": args.name, "readOnly": not args.rw,
                      "env": args.env, "group": args.group, "color": args.color}, pw if pw is not None else "")
    print(f"Saved '{c['name']}' ({c['driver']}, {'read-only' if c['readOnly'] else 'READ-WRITE'}).")
    if not args.no_test:
        print("ping:", engine.ping(c["id"])["version"])


def cmd_rm(args):
    print(f"Removed '{store.delete(args.name)['name']}'.")


def cmd_ping(args):
    r = engine.ping(args.conn)
    c = store.get(args.conn)
    print(f"{c['name']}: {r['version']} ({r['elapsed'] * 1000:.0f} ms, {'read-only' if c.get('readOnly', True) else 'READ-WRITE'})")


def cmd_tables(args):
    p = (args.pattern or "").lower()
    rows = [[t["name"], t["kind"], t["rows"]] for t in engine.tables(args.conn, pooled=False) if p in t["name"].lower()]
    _out(args, ["table", "kind", "approx_rows"], rows, f"-- {len(rows)} table(s)")


def cmd_desc(args):
    info = engine.table_info(args.conn, args.table, pooled=False)
    rows = [[c["name"], c["type"], "YES" if c["nullable"] else "", c["key"], c["default"],
             f"{c['fk']['table']}.{c['fk']['column']}" if c["fk"] else ""]
            for c in info["columns"] if not args.column or args.column.lower() in c["name"].lower()]
    _out(args, ["column", "type", "null", "key", "default", "references"], rows)
    if args.indexes:
        _out(args, ["index", "unique", "columns"], [[i["name"], "YES" if i["unique"] else "", i["cols"]] for i in info["indexes"]])
        if info["referencedBy"]:
            _out(args, ["referenced_by", "column", "ref_column"], [[r["table"], r["column"], r["refColumn"]] for r in info["referencedBy"]])


def cmd_q(args):
    sql = open(args.file, encoding="utf-8").read() if args.file else (args.sql if args.sql != "-" else sys.stdin.read())
    if not sql:
        sys.exit("Give SQL as an argument, '-' for stdin, or --file path.sql")
    run_sql(args, sql)


def cmd_doctor(args):
    """Environment report for bug reports and support (never prints secrets)."""
    import platform
    from . import __version__
    kr = store._keyring()
    backend = type(kr.get_keyring()).__module__ + "." + type(kr.get_keyring()).__name__ if kr else "file (secrets.json, 0600)"
    print(f"rowbase {__version__} · Python {platform.python_version()} · {platform.system()} {platform.release()} {platform.machine()}")
    print(f"config dir: {store.HOME}")
    print(f"secrets:    {backend}")
    print(f"connections: {len(store.load())}")
    for mod in ("pymysql", "pg8000", "sqlite3"):
        try:
            m = __import__(mod)
            print(f"driver {mod}: {getattr(m, '__version__', getattr(m, 'sqlite_version', 'ok'))}")
        except ImportError as e:
            print(f"driver {mod}: MISSING ({e})")
    import shutil
    print(f"ssh client: {shutil.which('ssh') or 'not found (SSH tunnels unavailable)'}")


def cmd_mcp(args):
    from . import mcp
    if args.print_config:
        cfg = mcp.client_config()
        if args.json:  # consumed by the native app (single source of truth for snippets + prompt)
            import json
            print(json.dumps(cfg, ensure_ascii=False))
            return
        for k in ("claude_code", "claude_desktop", "cursor", "codex", "vscode"):
            print(f"# {k}\n{cfg[k]}\n")
        print("# prompt to paste into your assistant\n" + cfg["prompt"])
        return
    mcp.serve()


def cmd_ui(args):
    from . import server
    server.serve(args.port, not args.no_open)


def _utf8_stdio():
    """Always speak UTF-8 (one-file builds, Windows consoles and pipes may default to ASCII/cp1252)."""
    for stream in (sys.stdin, sys.stdout, sys.stderr):
        try:
            if stream and (stream.encoding or "").lower().replace("-", "") != "utf8":
                stream.reconfigure(encoding="utf-8", errors="replace" if stream is not sys.stdin else "strict")
        except (AttributeError, ValueError):
            pass


def main(argv=None):
    _utf8_stdio()
    p = argparse.ArgumentParser(prog="rowbase", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("-c", "--conn", default=os.environ.get("ROWBASE_CONN"), help="connection name or id (see `conns`)")
    common.add_argument("--limit", type=int, default=100, help="max rows for SELECT without LIMIT (default 100)")
    common.add_argument("--format", choices=["table", "json", "tsv", "vertical"], default="table")
    common.add_argument("--ref", choices=["hex", "uuid"], default="uuid", help="how to print BINARY(16) values")
    common.add_argument("--width", type=int, default=60, help="max cell width in table format")
    common.add_argument("--timeout", type=int, default=30, help="statement timeout, seconds")
    common.add_argument("--out", help="write the full result to a file (.json -> JSON)")
    sub = p.add_subparsers(dest="cmd")
    sub.add_parser("conns", help="list saved connections").set_defaults(fn=cmd_conns)
    s = sub.add_parser("add", help="save a connection from a URL")
    s.add_argument("name"); s.add_argument("url")
    s.add_argument("--rw", action="store_true", help="allow writes (default: read-only)")
    s.add_argument("--env", choices=store.ENVS); s.add_argument("--group"); s.add_argument("--color")
    s.add_argument("--password-stdin", action="store_true"); s.add_argument("--replace", action="store_true")
    s.add_argument("--no-test", action="store_true", help="do not ping after saving")
    s.set_defaults(fn=cmd_add)
    s = sub.add_parser("rm", help="remove a connection"); s.add_argument("name"); s.set_defaults(fn=cmd_rm)
    sub.add_parser("ping", parents=[common], help="check connectivity").set_defaults(fn=cmd_ping)
    s = sub.add_parser("tables", parents=[common], help="list tables (optional name substring)")
    s.add_argument("pattern", nargs="?"); s.set_defaults(fn=cmd_tables)
    s = sub.add_parser("desc", parents=[common], help="columns (and --indexes, references) of a table")
    s.add_argument("table"); s.add_argument("column", nargs="?"); s.add_argument("--indexes", action="store_true")
    s.set_defaults(fn=cmd_desc)
    s = sub.add_parser("q", parents=[common], help="run one statement")
    s.add_argument("sql", nargs="?"); s.add_argument("-f", "--file"); s.set_defaults(fn=cmd_q)
    sub.add_parser("doctor", help="show environment info (config dir, secrets backend, drivers)").set_defaults(fn=cmd_doctor)
    s = sub.add_parser("mcp", help="run the MCP server on stdio (for AI assistants)")
    s.add_argument("--print-config", action="store_true", help="print client setup snippets and the setup prompt")
    s.add_argument("--json", action="store_true", help="with --print-config: machine-readable output")
    s.set_defaults(fn=cmd_mcp)
    s = sub.add_parser("ui", help="start the local web UI")
    s.add_argument("--port", type=int, default=8765); s.add_argument("--no-open", action="store_true"); s.set_defaults(fn=cmd_ui)
    argv = sys.argv[1:] if argv is None else argv
    # C/POSIX locale (servers, containers): non-ASCII arguments arrive as surrogate escapes — decode them as UTF-8
    argv = [x.encode("utf-8", "surrogateescape").decode("utf-8", "replace") if any("\udc80" <= ch <= "\udcff" for ch in x) else x
            for x in argv]
    if not argv:  # double-clicked one-file binary: open the web UI
        argv = ["ui"]
    args = p.parse_args(argv)
    try:
        args.fn(args)
    except (QueryError, ValueError) as e:
        sys.exit(str(e))


if __name__ == "__main__":
    main()
