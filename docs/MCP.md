# Rowbase MCP server

Rowbase ships an MCP server (stdio) so AI assistants can explore and query your saved connections.

## Quick start (the easy way)
1. Start Rowbase (double-click the one-file app, or `rowbase ui`) and add a connection.
2. Click **AI / MCP** → **Copy prompt** and paste it into your assistant (Claude Code, Claude Desktop, Cursor, Codex, …).
   The assistant registers the server, reads the built-in guide and creates a `rowbase-db` skill for itself.

Manual registration (the panel shows these with the correct path; `rowbase mcp --print-config` prints them too):
```
claude mcp add rowbase -- /path/to/rowbase mcp                       # Claude Code
{"mcpServers": {"rowbase": {"command": "/path/to/rowbase", "args": ["mcp"]}}}   # Claude Desktop / Cursor
```

## Safety
- **Read-only by default.** Unless *Allow writes* is enabled in AI / MCP settings, every connection is forced read-only
  for MCP — even connections you made write-enabled in Rowbase. Read-only = one statement, allow-listed keywords,
  READ ONLY transaction + rollback, driver-level single statement.
- **Writes** (when allowed, and only on write-enabled connections) go through `apply_changes`: structured row changes by
  primary key, `dry_run=true` first (shows SQL), then one atomic transaction.
- **Exposure**: choose which connections MCP can see. Passwords never leave the OS keychain.

## Tools
| Tool | Purpose |
|---|---|
| `guide` | Knowledge base: workflow, safety rules, output format, dialect notes (read first) |
| `connections` | Name, driver, env, effective read-only/read-write mode |
| `databases` | Databases on the server + current one |
| `tables` | Tables/views with approximate row counts (optional name filter) |
| `describe` | Columns (type, null, key, default, FK target, comment), indexes, referenced-by |
| `search_schema` | Find tables/columns by keyword |
| `sample` / `count` | First rows / row count with optional WHERE |
| `query` | One SQL statement, auto-LIMIT, `truncated` flag |
| `explain` | Execution plan (`analyze` optional) |
| `find_ref` | Which table holds a UUID as its primary key (references without FKs, e.g. 1C-style schemas) |
| `apply_changes` | Only when writes are allowed |

Tool sets: **full** (all above) or **minimal** (`guide`, `connections`, `tables`, `describe`, `query`) for small contexts.
Resources: `rowbase://guide`, `rowbase://connections`, `rowbase://schema/<connection>`. Prompts: `setup`, `explore`.

## Output format: TOON
Results default to [TOON](https://toonformat.dev) — a token-oriented notation; tables cost roughly 40% fewer tokens than JSON:
```
rows[2]{id,name,total}:
  1,ann,9.50
  2,"Smith, Bob",null
truncated: false
ms: 1.8
```
Pass `format: csv|json|md` per call or change the default in settings.

## Settings (`~/.config/rowbase/settings.json`)
```json
{"mcp": {"allowWrites": false, "connections": "*", "maxRows": 200, "timeout": 30, "format": "toon", "toolset": "full"}}
```
