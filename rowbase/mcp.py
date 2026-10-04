"""MCP server (stdio, JSON-RPC 2.0) — lets AI assistants explore and query saved connections safely.

Stdlib only. Settings live in ~/.config/rowbase/settings.json → "mcp" (see store.MCP_DEFAULTS):
  allowWrites  false → every connection is forced read-only for MCP, even if write-enabled in Rowbase
  connections  "*" or a list of connection names/ids exposed to MCP
  maxRows, timeout, format (toon|csv|json|md), toolset (full|minimal)
Results default to TOON (token-efficient tables). `guide` / resource rowbase://guide is the built-in knowledge base.
Never print to stdout except protocol messages; diagnostics go to stderr.
"""
import json
import sys
import time

from . import __version__, edit, engine, export, store, toon
from .guard import QueryError

PROTOCOL_VERSIONS = ("2025-06-18", "2025-03-26", "2024-11-05")

GUIDE = """# Rowbase MCP — guide for AI assistants

Rowbase exposes the user's saved database connections (MySQL/MariaDB, PostgreSQL, SQLite). Credentials stay in the
user's keychain; you never see passwords. Use connection NAMES as shown by `connections`.

## Safety model (important)
- Connections are READ-ONLY unless the user enabled writes both on the connection AND in the MCP settings
  (`connections` shows the effective mode). Read-only accepts one statement starting with SELECT/SHOW/DESCRIBE/
  EXPLAIN/WITH/VALUES/TABLE (+PRAGMA on SQLite); everything runs in a READ ONLY transaction that is rolled back.
- One statement per call. No `;`-chained statements.
- Writes (only when allowed) go through `apply_changes`: structured row changes by primary key, previewed first
  (dry_run=true shows the SQL), applied atomically; any row-not-found rolls everything back.
- Prefer small results: add WHERE/LIMIT, use `sample` and `count` before pulling big tables. Results are capped
  (truncated: true means more rows exist).

## Recommended workflow
1. `connections` → pick a connection (note env: prod means be extra careful).
2. `databases` if the connection has none selected or you need another one (pass `database` to later calls).
3. `search_schema` with a keyword (e.g. "invoice") or `tables` to find relevant tables.
4. `describe` the table: columns, types, primary key, foreign keys (fk = table.column), indexes, referenced_by.
5. `sample` a few rows, `count` with a WHERE, then `query` with precise SQL. Join along foreign keys from `describe`.
6. Use `explain` for slow queries (type=ALL in MySQL / Seq Scan in PostgreSQL means a full scan).

## Output format (default: TOON)
Tables come as `rows[N]{col1,col2}:` followed by one line per row, values comma-separated; strings with commas,
quotes, colons or edge spaces are "quoted" with \\n/\\" escapes; null is `null`. Example:
rows[2]{id,name,total}:
  1,ann,9.50
  2,"Smith, Bob",null
Metadata lines (`truncated`, `ms`, …) follow the table. Pass format=csv|json|md to override.

## Tools
connections · databases · tables · describe · search_schema · sample · count · query · explain · guide
(+ apply_changes when writes are allowed). Every tool takes `connection`; most take optional `database`.

## Dialect notes
- PostgreSQL tables outside `public` are named `schema.table`; quote identifiers with "double quotes".
- MySQL/MariaDB: backticks for identifiers; MariaDB EXPLAIN ANALYZE is translated automatically.
- SQLite: one file = one database.
"""

SETUP_PROMPT = """You are connected to Rowbase, a database MCP server. Please set yourself up:
1. Call the `guide` tool and read it fully.
2. Call `connections`, then for each connection relevant to me call `databases` (if applicable) and `tables`.
3. Create a reusable skill / rules file for this project named "rowbase-db" (in your agent's skills or rules
   location, e.g. .claude/skills/rowbase-db/SKILL.md) containing: when to use Rowbase, the list of connections with
   driver, env and read-only status, the recommended workflow and safety rules from the guide, the TOON format note,
   and 3–5 example tool calls for my data. Keep it concise.
4. Confirm what you created and show me the connection overview."""


def _settings():
    return store.settings()["mcp"]


def _exposed(c, cfg):
    sel = cfg["connections"]
    return sel == "*" or c["id"] in sel or c["name"] in sel


def _conn(name, database=None):
    """Resolve a connection for MCP use, applying the exposure list, database override and forced read-only."""
    cfg = _settings()
    c = store.get(name)
    if not _exposed(c, cfg):
        raise QueryError(f"Connection '{name}' is not exposed to MCP (Rowbase settings → AI / MCP).")
    c = dict(c)
    if not cfg["allowWrites"]:
        c["readOnly"] = True
    if database:
        c["database"] = database
    return c


def _fmt(cols, rows, fmt, name="rows"):
    if fmt == "toon":
        return toon.table(name, cols, rows)
    if fmt in ("csv", "json", "md"):
        return export.render(cols, rows, fmt).rstrip("\n")
    raise QueryError("format must be toon, csv, json or md")


def _result(res, fmt, extra=None):
    meta = {"rows": len(res["rows"]), "truncated": res["truncated"], "ms": round(res["elapsed"] * 1000, 1)}
    if res.get("affected") is not None:
        meta = {"affected": res["affected"], "ms": meta["ms"]}
    meta.update(extra or {})
    body = _fmt(res["cols"], res["rows"], fmt) if res["cols"] else ""
    return (body + "\n" if body else "") + toon.encode(meta)


# ---------------------------------------------------------------- tools

def t_guide(a):
    return GUIDE


def t_connections(a):
    cfg = _settings()
    rows = []
    for c in store.load():
        if not _exposed(c, cfg):
            continue
        ro = c.get("readOnly", True) or not cfg["allowWrites"]
        rows.append([c["name"], c["driver"], c.get("env"), "read-only" if ro else "read-write",
                     c.get("database") or c.get("path"), "ssh" if c.get("ssh") else None])
    return toon.table("connections", ["name", "driver", "env", "mode", "database", "tunnel"], rows) + \
        f"\nwrites_enabled_in_mcp: {'true' if cfg['allowWrites'] else 'false'}"


def t_databases(a):
    d = engine.databases(_conn(a["connection"]))
    return toon.encode({"current": d["current"], "databases": d["databases"], "system": d["system"]})


def t_tables(a):
    f = (a.get("filter") or "").lower()
    rows = [[t["name"], t["kind"], t["rows"]] for t in engine.tables(_conn(a["connection"], a.get("database")), pooled=True)
            if f in t["name"].lower()]
    return toon.table("tables", ["name", "kind", "approx_rows"], rows)


def t_describe(a):
    info = engine.table_info(_conn(a["connection"], a.get("database")), a["table"])
    cols = [[c["name"], c["type"], "yes" if c["nullable"] else "no", c["key"] or None, c["default"],
             f"{c['fk']['table']}.{c['fk']['column']}" if c["fk"] else None, c["comment"] or None] for c in info["columns"]]
    out = [toon.table("columns", ["name", "type", "nullable", "key", "default", "fk", "comment"], cols),
           toon.table("indexes", ["name", "unique", "columns"], [[i["name"], i["unique"], i["cols"]] for i in info["indexes"]]),
           toon.table("referenced_by", ["table", "column", "ref_column"], [[r["table"], r["column"], r["refColumn"]] for r in info["referencedBy"]])]
    return f"table: {toon.scalar(info['name'])}\nsql_name: {toon.scalar(info['quoted'])}\n" + "\n".join(out)


def t_search_schema(a):
    c = _conn(a["connection"], a.get("database"))
    drv = engine.dialect(c)
    res = engine.execute(c, drv.search_sql(f"%{a['text']}%"), limit=500, trusted=True, pooled=True)
    return toon.table("matches", ["table", "column", "type"], res["rows"]) + ("\ntruncated: true" if res["truncated"] else "")


def _limit(a, default):
    return max(1, min(int(a.get("limit") or default), _settings()["maxRows"]))


def t_query(a):
    cfg = _settings()
    c = _conn(a["connection"], a.get("database"))
    res = engine.execute(c, a["sql"], limit=_limit(a, 100), timeout=cfg["timeout"], pooled=True)
    return _result(res, a.get("format") or cfg["format"])


def t_sample(a):
    c = _conn(a["connection"], a.get("database"))
    q = engine.dialect(c).ident(a["table"])
    sql = f"SELECT * FROM {q}" + (f" WHERE {a['where']}" if a.get("where") else "")
    res = engine.execute(c, sql, limit=_limit(a, 20), timeout=_settings()["timeout"], pooled=True)
    return _result(res, a.get("format") or _settings()["format"])


def t_count(a):
    c = _conn(a["connection"], a.get("database"))
    q = engine.dialect(c).ident(a["table"])
    res = engine.execute(c, f"SELECT COUNT(*) FROM {q}" + (f" WHERE {a['where']}" if a.get("where") else ""),
                         limit=1, timeout=_settings()["timeout"], pooled=True)
    return f"count: {res['rows'][0][0]}"


def t_explain(a):
    c = _conn(a["connection"], a.get("database"))
    drv = engine.dialect(c)
    prefix = {"sqlite": "EXPLAIN QUERY PLAN "}.get(drv.name, "EXPLAIN ANALYZE " if a.get("analyze") else "EXPLAIN ")
    res = engine.execute(c, prefix + a["sql"], limit=500, timeout=_settings()["timeout"], pooled=True)
    hint = {"mysql": "type=ALL means full table scan", "postgres": "Seq Scan means full table scan"}.get(drv.name, "")
    return _result(res, "toon", {"hint": hint} if hint else None)


def t_apply_changes(a):
    cfg = _settings()
    if not cfg["allowWrites"]:
        raise QueryError("Writes are disabled for MCP (Rowbase settings → AI / MCP → allow writes).")
    c = _conn(a["connection"], a.get("database"))
    dry = a.get("dry_run", True)
    r = edit.apply(c, a["table"], a.get("changes") or [], dry_run=dry)
    return toon.encode({"dry_run": dry, "statements": r["statements"], "affected": r.get("affected") or []}) + \
        ("\nnext: review the SQL with the user, then call again with dry_run=false" if dry else "")


def _p(desc, **extra):
    return {"type": "string", "description": desc, **extra}


CONN = _p("Connection name (from `connections`)")
DB = _p("Database name to use instead of the connection's default (optional)")
FMT = {"type": "string", "enum": ["toon", "csv", "json", "md"], "description": "Result format (default from settings: toon)"}
RO = {"readOnlyHint": True, "destructiveHint": False, "openWorldHint": False}

TOOLS = {
    "guide": (t_guide, "Read this first: Rowbase MCP knowledge base — workflow, safety rules, output format, dialect notes.",
              {}, [], "minimal"),
    "connections": (t_connections, "List the user's database connections (name, driver, env, effective read-only/read-write mode).",
                    {}, [], "minimal"),
    "databases": (t_databases, "List databases on the connection's server and the current one.", {"connection": CONN}, ["connection"], "full"),
    "tables": (t_tables, "List tables and views (with approximate row counts) of a connection/database.",
               {"connection": CONN, "database": DB, "filter": _p("Case-insensitive substring of the table name")}, ["connection"], "minimal"),
    "describe": (t_describe, "Describe a table: columns (type, nullable, key, default, foreign key target, comment), indexes and tables referencing it.",
                 {"connection": CONN, "database": DB, "table": _p("Table name (PostgreSQL: schema.table outside public)")},
                 ["connection", "table"], "minimal"),
    "search_schema": (t_search_schema, "Find tables/columns whose name (or MySQL column comment) contains a keyword.",
                      {"connection": CONN, "database": DB, "text": _p("Keyword, e.g. invoice")}, ["connection", "text"], "full"),
    "sample": (t_sample, "Return the first rows of a table, optionally filtered by a WHERE expression.",
               {"connection": CONN, "database": DB, "table": _p("Table name"), "where": _p("SQL boolean expression without WHERE"),
                "limit": {"type": "integer", "description": "Rows (default 20)"}, "format": FMT}, ["connection", "table"], "full"),
    "count": (t_count, "Count rows of a table, optionally filtered by a WHERE expression.",
              {"connection": CONN, "database": DB, "table": _p("Table name"), "where": _p("SQL boolean expression without WHERE")},
              ["connection", "table"], "full"),
    "query": (t_query, "Run ONE SQL statement (read-only unless writes are enabled). Auto-LIMIT applies; 'truncated: true' means more rows exist.",
              {"connection": CONN, "database": DB, "sql": _p("A single SQL statement"),
               "limit": {"type": "integer", "description": "Max rows (default 100, capped by settings)"}, "format": FMT},
              ["connection", "sql"], "minimal"),
    "explain": (t_explain, "Show the execution plan of a SELECT (analyze=true executes it to get real timings).",
                {"connection": CONN, "database": DB, "sql": _p("SELECT statement"), "analyze": {"type": "boolean"}},
                ["connection", "sql"], "full"),
}
WRITE_TOOL = ("apply_changes", t_apply_changes,
              "Change rows atomically by primary key. ALWAYS call with dry_run=true first and show the SQL to the user. "
              "changes: [{op:'update', key:{pk:value}, set:{col:value|null}}, {op:'insert', values:{...}}, {op:'delete', key:{pk:value}}].",
              {"connection": CONN, "database": DB, "table": _p("Table name"),
               "changes": {"type": "array", "items": {"type": "object"}}, "dry_run": {"type": "boolean", "description": "Default true"}},
              ["connection", "table", "changes"])


def tool_list():
    cfg = _settings()
    out = []
    for name, (fn, desc, props, req, level) in TOOLS.items():
        if cfg["toolset"] == "minimal" and level != "minimal":
            continue
        out.append({"name": name, "description": desc, "annotations": RO,
                    "inputSchema": {"type": "object", "properties": props, "required": req}})
    if cfg["allowWrites"]:
        name, fn, desc, props, req = WRITE_TOOL
        out.append({"name": name, "description": desc, "annotations": {"readOnlyHint": False, "destructiveHint": True},
                    "inputSchema": {"type": "object", "properties": props, "required": req}})
    return out


def call_tool(name, args):
    if name == WRITE_TOOL[0]:
        fn = WRITE_TOOL[1]
    elif name in TOOLS:
        fn = TOOLS[name][0]
    else:
        raise QueryError(f"Unknown tool '{name}'")
    return fn(args or {})


# ---------------------------------------------------------------- resources & prompts

def resources():
    out = [{"uri": "rowbase://guide", "name": "Rowbase guide", "mimeType": "text/markdown",
            "description": "Knowledge base: workflow, safety, output format, tools."},
           {"uri": "rowbase://connections", "name": "Connections", "mimeType": "text/plain"}]
    cfg = _settings()
    for c in store.load():
        if _exposed(c, cfg):
            out.append({"uri": f"rowbase://schema/{c['name']}", "name": f"Schema of {c['name']}", "mimeType": "text/plain",
                        "description": "All tables with their columns (compact)."})
    return out


def read_resource(uri):
    if uri == "rowbase://guide":
        return GUIDE, "text/markdown"
    if uri == "rowbase://connections":
        return t_connections({}), "text/plain"
    if uri.startswith("rowbase://schema/"):
        c = _conn(uri.split("/", 3)[3])
        drv = engine.dialect(c)
        res = engine.execute(c, drv.search_sql("%"), limit=20000, trusted=True, pooled=True)
        return toon.table("columns", ["table", "column", "type"], res["rows"]), "text/plain"
    raise QueryError(f"Unknown resource {uri}")


PROMPTS = {
    "setup": ("Set up this assistant to work with Rowbase: read the guide, list connections and create a reusable skill.", SETUP_PROMPT),
    "explore": ("Explore a connection and summarize its data model.",
                "Call `guide`, then `tables` and `describe` the most important tables of connection {connection}. "
                "Summarize the data model: main entities, how they relate (foreign keys), and useful example queries."),
}


# ---------------------------------------------------------------- JSON-RPC loop

def handle(msg):
    """Return the response dict for a request, or None for notifications."""
    mid, method, params = msg.get("id"), msg.get("method"), msg.get("params") or {}
    if mid is None:
        return None  # notification (e.g. notifications/initialized)
    try:
        if method == "initialize":
            want = params.get("protocolVersion")
            result = {"protocolVersion": want if want in PROTOCOL_VERSIONS else PROTOCOL_VERSIONS[0],
                      "capabilities": {"tools": {}, "resources": {}, "prompts": {}},
                      "serverInfo": {"name": "rowbase", "title": "Rowbase", "version": __version__},
                      "instructions": "Database access to the user's saved connections. Call the `guide` tool first; "
                                      "results are TOON tables; connections are read-only unless the user allowed writes."}
        elif method == "ping":
            result = {}
        elif method == "tools/list":
            result = {"tools": tool_list()}
        elif method == "tools/call":
            started = time.monotonic()
            try:
                text = call_tool(params.get("name"), params.get("arguments"))
                result = {"content": [{"type": "text", "text": text}], "isError": False}
            except (QueryError, ValueError, KeyError) as e:
                msg_ = f"Missing argument {e}" if isinstance(e, KeyError) else str(e)
                result = {"content": [{"type": "text", "text": f"error: {msg_}"}], "isError": True}
            print(f"rowbase mcp: {params.get('name')} {time.monotonic() - started:.3f}s", file=sys.stderr)
        elif method == "resources/list":
            result = {"resources": resources()}
        elif method == "resources/read":
            text, mime = read_resource(params["uri"])
            result = {"contents": [{"uri": params["uri"], "mimeType": mime, "text": text}]}
        elif method == "prompts/list":
            result = {"prompts": [{"name": n, "description": d, "arguments": [{"name": "connection", "required": False}] if n == "explore" else []}
                                  for n, (d, _) in PROMPTS.items()]}
        elif method == "prompts/get":
            desc, text = PROMPTS[params["name"]]
            text = text.replace("{connection}", (params.get("arguments") or {}).get("connection", "the main connection"))
            result = {"description": desc, "messages": [{"role": "user", "content": {"type": "text", "text": text}}]}
        else:
            return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"Method not found: {method}"}}
        return {"jsonrpc": "2.0", "id": mid, "result": result}
    except Exception as e:  # never crash the stdio loop
        return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32603, "message": str(e)}}


def serve(stdin=None, stdout=None):
    stdin, stdout = stdin or sys.stdin, stdout or sys.stdout
    for line in stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            stdout.write(json.dumps({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}}) + "\n")
            stdout.flush()
            continue
        for m in msg if isinstance(msg, list) else [msg]:
            resp = handle(m)
            if resp is not None:
                stdout.write(json.dumps(resp, ensure_ascii=False) + "\n")
                stdout.flush()
    engine.reset_pool()


# ---------------------------------------------------------------- client setup helpers (CLI / web UI)

def launcher():
    """argv that starts this MCP server: the one-file binary, or the installed `rowbase` script / python -m."""
    import os
    exe = sys.argv[0]
    if getattr(sys, "frozen", False) or "__compiled__" in globals():
        return [os.path.abspath(sys.executable if getattr(sys, "frozen", False) else exe), "mcp"]
    import shutil
    sibling = os.path.join(os.path.dirname(sys.executable), "rowbase" + (".exe" if os.name == "nt" else ""))
    found = sibling if os.path.exists(sibling) else shutil.which("rowbase")
    if found:
        return [found, "mcp"]
    return [sys.executable, "-m", "rowbase", "mcp"]


def client_config():
    argv = launcher()
    quoted = " ".join(f'"{a}"' if " " in a else a for a in argv)
    server = {"command": argv[0], "args": argv[1:]}
    return {
        "claude_code": f"claude mcp add rowbase -- {quoted}",
        "claude_desktop": json.dumps({"mcpServers": {"rowbase": server}}, indent=2),
        "cursor": json.dumps({"mcpServers": {"rowbase": server}}, indent=2),
        "codex": f'[mcp_servers.rowbase]\ncommand = "{argv[0]}"\nargs = {json.dumps(argv[1:])}',
        "vscode": json.dumps({"servers": {"rowbase": {"type": "stdio", **server}}}, indent=2),
        "prompt": user_prompt(argv),
    }


def user_prompt(argv=None):
    argv = argv or launcher()
    quoted = " ".join(f'"{a}"' if " " in a else a for a in argv)
    return f"""Connect yourself to my databases through the Rowbase MCP server and set up a skill for it.

1. Register the MCP server (stdio). Claude Code: run `claude mcp add rowbase -- {quoted}`.
   Other clients: add a stdio server named "rowbase" with command `{argv[0]}` and args {json.dumps(argv[1:])}.
   If you cannot change your own MCP config, tell me exactly what to paste and where.
2. Once connected:
{SETUP_PROMPT}"""
