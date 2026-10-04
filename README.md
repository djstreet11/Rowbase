# Rowbase

[![CI](https://github.com/djstreet11/Rowbase/actions/workflows/ci.yml/badge.svg)](https://github.com/djstreet11/Rowbase/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

**A fast, good-looking, read-only-by-default database client — for humans and for AI agents.**

MySQL / MariaDB · PostgreSQL · SQLite — a native macOS app, a one-file web UI + CLI for macOS, Linux and Windows,
and an MCP server so assistants (Claude, Cursor, Codex, …) can explore and query your databases safely.

- **Safe by default** — connections are read-only unless you switch them; 4 independent layers
  (driver single-statement, SQL guard, READ ONLY transaction, timeouts). Writes go through a reviewed, atomic
  "pending changes" flow.
- **Connections like TablePlus** — groups, colors, env tags (prod gets a red accent), SSH tunnels via your `~/.ssh/config`,
  passwords in the OS keychain.
- **Fast navigation** — follow foreign keys, "referenced by", transpose, column picker, schema-aware autocomplete,
  EXPLAIN highlighting, query cancel, history.
- **Edit & export** — inline editing with SQL preview, export to CSV/TSV/JSON/Markdown/SQL.
- **AI-ready** — built-in MCP server with a token-efficient result format (TOON) and a knowledge-base guide.

## Get it
Downloads: [GitHub Releases](https://github.com/djstreet11/Rowbase/releases).

| Platform | Download | Run |
|---|---|---|
| macOS (native app) | `Rowbase-x.y.z.dmg` | drag to Applications |
| macOS / Linux | `rowbase-<os>-<arch>` (one file) | `chmod +x rowbase-*` then `./rowbase-…` |
| Windows 10/11 | `rowbase-windows-x64.exe` (one file) | double-click |

No installer, no admin rights, no Python needed. Running without arguments opens the web UI in your browser.

## CLI
```
rowbase add shop 'postgres://me@db.example.com/shop?ssh=deploy@bastion'   # read-only unless --rw
rowbase tables -c shop
rowbase q "SELECT * FROM orders WHERE status = 'new'" -c shop --format json
rowbase ui            # web UI on http://127.0.0.1:8765
rowbase mcp           # MCP server (stdio) for AI assistants
```

## AI assistants (MCP)
Open the web UI → **AI / MCP** to copy a ready-made setup prompt, or add the server yourself:
```
claude mcp add rowbase -- /path/to/rowbase mcp
```
The server is read-only unless you enable writes in its settings. See [docs/MCP.md](docs/MCP.md).

## Build from source
- Python track: `python3 -m venv .venv && .venv/bin/pip install -e . && .venv/bin/rowbase ui`
- One-file binaries: [docs/BUILDING.md](docs/BUILDING.md)
- Native macOS app: `cd native && swift build` · release: [docs/RELEASING.md](docs/RELEASING.md)

## License
[Apache-2.0](LICENSE) — see [NOTICE](NOTICE) and [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
