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

from . import __version__, edit, engine, export, refs, store, toon
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

## References without foreign keys (UUIDs)
Some schemas (e.g. 1C-style: `Ref char(36)` primary keys, columns like `SenderAddress`, `Owner_Ref` + `Owner_TRef`)
store references as UUIDs with no FK constraints. When a value is a UUID and `describe` shows no fk, call `find_ref`
with the value (plus table/column, and the sibling *_TRef/*_Type value as hint if present) to learn which table holds
it, then `sample` that table with `where` on its key.

## Output format (default: TOON)
Tables come as `rows[N]{col1,col2}:` followed by one line per row, values comma-separated; strings with commas,
quotes, colons or edge spaces are "quoted" with \\n/\\" escapes; null is `null`. Example:
rows[2]{id,name,total}:
  1,ann,9.50
  2,"Smith, Bob",null
Metadata lines (`truncated`, `ms`, …) follow the table. Pass format=csv|json|md to override.

## Tools
connections · databases · tables · describe · search_schema · sample · count · query · explain · find_ref · guide
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


def t_find_ref(a):
    c = _conn(a["connection"], a.get("database"))
    r = refs.resolve(c, (a.get("value") or "").strip(), a.get("table"), a.get("column"), a.get("hint"))
    out = toon.table("matches", ["table", "pk", "label"], [[m["table"], m["pk"], m["label"] or None] for m in r["matches"]])
    meta = {"found_by": r["how"]} if r["matches"] else {"searched_tables": r.get("searched", 0)}
    return out + "\n" + toon.encode(meta)


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


CONN = _p("Connection name exactly as returned by `connections` (e.g. \"shop\"). Unknown or unexposed names return an error.")
DB = _p("Optional database to use instead of the connection's default (names from `databases`). Omit to use the default.")
TABLE = _p("Table or view name as returned by `tables`. PostgreSQL tables outside `public` are written schema.table.")
WHERE = _p("Optional SQL boolean expression WITHOUT the WHERE keyword, e.g. status = 'paid' AND total > 100.")
FMT = {"type": "string", "enum": ["toon", "csv", "json", "md"],
       "description": "Result format. Default from settings: toon (compact table: rows[N]{cols}: then one line per row)."}
RO = {"readOnlyHint": True, "destructiveHint": False, "idempotentHint": True, "openWorldHint": False}
ERRORS = " On failure returns isError with 'error: <reason>' (e.g. refused statement, unknown table, SQL error)."

# Descriptions follow one shape: what it does → when to use it (and what to use instead) → what it returns → limits.
TOOLS = {
    "guide": (t_guide, "Guide",
              "Read this first, once per session: the Rowbase knowledge base — recommended workflow, safety rules (read-only "
              "model, one statement per call), the TOON output format and SQL dialect notes. Use it before any other tool; "
              "it needs no connection. Returns a markdown document.",
              {}, [], "minimal"),
    "connections": (t_connections, "List connections",
                    "List the user's saved database connections exposed to MCP. Call this first to get the exact connection "
                    "names every other tool requires. Returns a table connections[N]{name,driver,env,mode,database,tunnel} — "
                    "mode is the EFFECTIVE read-only/read-write mode for MCP; env 'prod' means be extra careful — plus "
                    "writes_enabled_in_mcp. No pagination: all exposed connections are returned.",
                    {}, [], "minimal"),
    "databases": (t_databases, "List databases",
                  "List the databases on a connection's server and which one is current. Use it when a connection has no "
                  "database selected, or to work in another database (pass `database` to later calls); to list tables inside "
                  "a database use `tables` instead. Returns current, databases[N] (user databases first) and system[N]. "
                  "SQLite returns an empty list (one file = one database)." + ERRORS,
                  {"connection": CONN}, ["connection"], "full"),
    "tables": (t_tables, "List tables",
               "List all tables and views of a connection/database with approximate row counts — the entry point for browsing. "
               "Use `search_schema` instead when you look for a concept (e.g. 'invoice') across table AND column names, and "
               "`describe` once you know the table. Returns tables[N]{name,kind,approx_rows} (kind = table|view; approx_rows "
               "is an estimate, may be null; use `count` for exact numbers). Returns every match, no pagination." + ERRORS,
               {"connection": CONN, "database": DB, "filter": _p("Optional case-insensitive substring of the table name, e.g. order.")},
               ["connection"], "minimal"),
    "describe": (t_describe, "Describe table",
                 "Show the structure of one known table: columns with type, nullability, key, default, foreign-key target "
                 "(fk = table.column — use it to write JOINs) and comment, plus indexes and the tables that reference it. "
                 "Use it before writing SQL against a table; use `search_schema` if you don't know the table name yet. "
                 "Returns table, sql_name (properly quoted name for SQL), columns[N]{name,type,nullable,key,default,fk,comment}, "
                 "indexes[N]{name,unique,columns} and referenced_by[N]{table,column,ref_column}." + ERRORS,
                 {"connection": CONN, "database": DB, "table": TABLE}, ["connection", "table"], "minimal"),
    "search_schema": (t_search_schema, "Search schema",
                      "Find tables and columns whose name contains a keyword (case-insensitive substring; on MySQL also column "
                      "comments). Use it when you know WHAT you are looking for but not WHERE it is stored; use `tables` instead to "
                      "browse everything and `describe` for one known table. Returns matches[N]{table,column,type}, one row "
                      "per matching column (a table-name match lists all its columns), capped at 500 rows (truncated: true "
                      "when cut)." + ERRORS,
                      {"connection": CONN, "database": DB, "text": _p("Keyword to look for, e.g. invoice, email, price.")},
                      ["connection", "text"], "full"),
    "sample": (t_sample, "Sample rows",
               "Peek at a few real rows of one table (SELECT * … LIMIT n, in storage order, no sorting) to see what the data "
               "looks like before writing a query. Use `query` instead for specific columns, joins, sorting or aggregates, "
               "and `count` when you only need a number. Returns rows[N]{all columns} plus rows, truncated (true = more rows "
               "exist) and ms. Default 20 rows, capped by the server's max rows setting." + ERRORS,
               {"connection": CONN, "database": DB, "table": TABLE, "where": WHERE,
                "limit": {"type": "integer", "minimum": 1, "description": "Rows to return (default 20; capped by settings, usually 200)."},
                "format": FMT}, ["connection", "table"], "full"),
    "count": (t_count, "Count rows",
              "Return the exact number of rows in a table, optionally filtered — use it to size a result before fetching it "
              "or to answer 'how many' questions. Use `query` instead for grouped counts (GROUP BY) or counts over joins. "
              "Returns a single line: count: N. May be slow on very large unindexed filters (timeout from settings)." + ERRORS,
              {"connection": CONN, "database": DB, "table": TABLE, "where": WHERE}, ["connection", "table"], "full"),
    "query": (t_query, "Run SQL",
              "Run exactly ONE SQL statement — the general tool for answering questions: specific columns, JOINs (follow fk "
              "from `describe`), filters, sorting, GROUP BY. Read-only connections accept only SELECT/SHOW/DESCRIBE/EXPLAIN/"
              "WITH/VALUES/TABLE (+PRAGMA on SQLite); multiple statements are refused. Prefer `sample`/`count` for simple "
              "peeks and totals, `explain` for performance. A LIMIT is added automatically when missing. Returns "
              "rows[N]{columns} plus rows, truncated (true = more rows exist — narrow with WHERE or raise limit) and ms; "
              "write statements (only if writes are enabled) return affected instead." + ERRORS,
              {"connection": CONN, "database": DB, "sql": _p("A single SQL statement in the connection's dialect, without a trailing ';' chain."),
               "limit": {"type": "integer", "minimum": 1, "description": "Max rows (default 100; capped by settings, usually 200)."},
               "format": FMT},
              ["connection", "sql"], "minimal"),
    "explain": (t_explain, "Explain query plan",
                "Show how the database will execute a SELECT (its query plan) to diagnose slow queries or check index use — "
                "use it instead of `query` when the question is about performance, not data. With analyze=true the statement "
                "is actually executed to report real timings (can be slow on big tables). Returns the plan as rows plus a "
                "hint: MySQL type=ALL or PostgreSQL 'Seq Scan' means a full table scan (consider an index or a narrower WHERE). "
                "SQLite uses EXPLAIN QUERY PLAN." + ERRORS,
                {"connection": CONN, "database": DB, "sql": _p("The SELECT statement to analyze (without EXPLAIN)."),
                 "analyze": {"type": "boolean", "description": "true = execute the statement to measure real timings and row counts "
                                                               "(EXPLAIN ANALYZE); default false = estimate only, nothing is executed."}},
                ["connection", "sql"], "full"),
    "find_ref": (t_find_ref, "Find referenced object",
                 "Find which table holds a UUID value as its primary key — for schemas that store references as UUIDs without "
                 "foreign keys (1C-style `Ref` keys, columns like SenderAddress or Owner_Ref). Use it when `describe` shows no fk "
                 "for a column whose values are UUIDs; use `describe` fk + `query` instead when real foreign keys exist. Searches "
                 "tables whose single-column primary key can hold a UUID: the hint table first, then tables named like the "
                 "column (SenderAddress → …Addresses), then all of them. Returns matches[N]{table,pk,label} (label = "
                 "Description/Name/Number/Code of the row) and found_by, or searched_tables when nothing matched." + ERRORS,
                 {"connection": CONN, "database": DB,
                  "value": _p("The UUID to look up, e.g. 7e6056b9-9582-11f1-a74c-005056bd6036."),
                  "table": _p("Optional: table the value was read from (improves the guess and is remembered)."),
                  "column": _p("Optional: column the value was read from, e.g. SenderAddress."),
                  "hint": _p("Optional: value of a sibling type column such as Owner_TRef = 'Catalog.Counterparties'.")},
                 ["connection", "value"], "full"),
}
WRITE_TOOL = ("apply_changes", t_apply_changes, "Apply row changes",
              "Insert, update or delete rows by primary key in ONE atomic transaction — only available when the user enabled "
              "writes for MCP, and only on write-enabled connections. ALWAYS call with dry_run=true first, show the generated "
              "SQL to the user and get confirmation, then call again with dry_run=false. Every update/delete must hit exactly "
              "one row, otherwise nothing is saved. Returns dry_run, statements[N] (the SQL) and affected[N]." + ERRORS,
              {"connection": CONN, "database": DB, "table": TABLE,
               "changes": {"type": "array", "description": "Row changes: {op:'update', key:{pk_col:value}, set:{col:value|null}}, "
                                                           "{op:'insert', values:{col:value}}, {op:'delete', key:{pk_col:value}}. "
                                                           "key must contain exactly the primary-key columns.",
                           "items": {"type": "object"}},
               "dry_run": {"type": "boolean", "description": "Default true: only return the SQL. Set false to apply after the user confirmed."}},
              ["connection", "table", "changes"])


def tool_list():
    cfg = _settings()
    out = []
    for name, (fn, title, desc, props, req, level) in TOOLS.items():
        if cfg["toolset"] == "minimal" and level != "minimal":
            continue
        ann = RO
        if name == "query" and cfg["allowWrites"]:  # can run writes on write-enabled connections → be truthful
            ann = {**RO, "readOnlyHint": False, "destructiveHint": True, "idempotentHint": False}
        out.append({"name": name, "title": title, "description": desc, "annotations": {"title": title, **ann},
                    "inputSchema": {"type": "object", "properties": props, "required": req}})
    if cfg["allowWrites"]:
        name, fn, title, desc, props, req = WRITE_TOOL
        out.append({"name": name, "title": title, "description": desc,
                    "annotations": {"title": title, "readOnlyHint": False, "destructiveHint": True, "idempotentHint": False, "openWorldHint": False},
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
