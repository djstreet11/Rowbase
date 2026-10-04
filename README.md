<p align="center">
  <img src="https://raw.githubusercontent.com/djstreet11/Rowbase/main/native/Resources/AppIcon-1024.png" width="120" alt="Rowbase icon">
</p>
<h1 align="center">Rowbase</h1>
<!-- mcp-name: io.github.djstreet11/rowbase -->
<p align="center"><b>A fast, good-looking, read-only-by-default database client — for humans and for AI agents.</b><br>
MySQL / MariaDB · PostgreSQL · SQLite · native macOS app · one-file app for macOS, Linux &amp; Windows · built-in MCP server</p>

<p align="center">
  <a href="https://github.com/djstreet11/Rowbase/releases/latest"><img src="https://img.shields.io/github/v/release/djstreet11/Rowbase?label=download" alt="Latest release"></a>
  <a href="https://github.com/djstreet11/Rowbase/actions/workflows/ci.yml"><img src="https://github.com/djstreet11/Rowbase/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/djstreet11/Rowbase/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue.svg" alt="License: Apache-2.0"></a>
  <a href="https://pypi.org/project/rowbase-db/"><img src="https://img.shields.io/pypi/v/rowbase-db?label=PyPI" alt="PyPI"></a>
  <img src="https://img.shields.io/badge/MCP%20Registry-io.github.djstreet11%2Frowbase-8A2BE2" alt="MCP Registry">
</p>

<p align="center"><img src="https://raw.githubusercontent.com/djstreet11/Rowbase/main/docs/assets/table-inspector.png" width="860" alt="Rowbase: table browser with row inspector"></p>

## Why Rowbase?
- **Safe by default.** Every connection is read-only until you say otherwise — enforced at four independent layers
  (driver-level single statement, SQL guard, `READ ONLY` transaction, timeouts). Production connections get a red accent.
- **Made for AI assistants too.** A built-in [MCP](https://modelcontextprotocol.io) server lets Claude, Cursor, Codex & co.
  explore your schema and query data — read-only unless you allow writes, with a token-efficient output format (TOON)
  and a built-in guide so the assistant knows how to use it. One copy-paste prompt sets everything up.
- **One file, no installer.** Download a single binary for macOS, Linux or Windows and run it — no admin rights, no Python,
  no drivers to install. Or use the native macOS app.
- **Nice to use.** Foreign-key navigation, "referenced by", transpose, column picker, schema-aware autocomplete,
  EXPLAIN highlighting, query cancel, inline editing with SQL preview, export to CSV/JSON/Markdown/SQL, SSH tunnels.
- **Open source** under Apache-2.0. Passwords live in your OS keychain, never in config files.

| | |
|---|---|
| <img src="https://raw.githubusercontent.com/djstreet11/Rowbase/main/docs/assets/sql-editor.png" alt="SQL editor with autocomplete and results"> | <img src="https://raw.githubusercontent.com/djstreet11/Rowbase/main/docs/assets/editing.png" alt="Inline editing with pending changes"> |
| SQL editor: autocomplete, ⌘↩ runs the statement under the caret, EXPLAIN, cancel | Edit rows safely: pending changes, SQL preview, one atomic save |

## Download
Grab the latest from **[Releases](https://github.com/djstreet11/Rowbase/releases/latest)**:

| Platform | File | How to run |
|---|---|---|
| macOS (native app) | `Rowbase-x.y.z.dmg` | open, drag to Applications |
| macOS (one file) | `rowbase-macos-arm64` | `chmod +x rowbase-macos-arm64 && ./rowbase-macos-arm64` |
| Linux x64 / arm64 | `rowbase-linux-x64` / `-arm64` | `chmod +x rowbase-linux-* && ./rowbase-linux-x64` (Ubuntu 20.04+, Debian 10+, RHEL 8+) |
| Windows 10 / 11 | `rowbase-windows-x64.exe` | double-click |

Started without arguments, the one-file app opens the web UI in your browser. Builds are not code-signed yet:
macOS → *System Settings → Privacy & Security → Open Anyway*; Windows → *More info → Run anyway*.

## Connect your AI assistant (MCP)
Open **AI / MCP** in the app, click **Copy prompt**, paste it into your assistant — it registers the server, reads the
built-in guide and creates a reusable skill. Or register manually:
```bash
claude mcp add rowbase -- /path/to/rowbase mcp          # one-file binary or app
claude mcp add rowbase -- uvx --from rowbase-db rowbase mcp   # straight from PyPI, nothing to download
```
Listed in the official [MCP Registry](https://registry.modelcontextprotocol.io) as `io.github.djstreet11/rowbase`.

Results come back as compact [TOON](https://toonformat.dev) tables (~40% fewer tokens than JSON):
```
rows[2]{id,customer,total}:
  1,"Smith, Bob",9.50
  2,ann,null
truncated: false
```
Tools: `guide`, `connections`, `databases`, `tables`, `describe`, `search_schema`, `sample`, `count`, `query`, `explain`
(+ `apply_changes` only when you allow writes). Details: [docs/MCP.md](https://github.com/djstreet11/Rowbase/blob/main/docs/MCP.md).

## CLI
Install from PyPI (`pipx install rowbase-db` / `uv tool install rowbase-db`) or use a one-file download.
```bash
rowbase add shop 'postgres://me@db.example.com/shop?ssh=deploy@bastion'   # read-only unless --rw
rowbase tables -c shop
rowbase q "SELECT * FROM orders WHERE status = 'new'" -c shop --format json
rowbase ui        # web UI on http://127.0.0.1:8765
rowbase mcp       # MCP server (stdio)
rowbase doctor    # environment report
```

<details><summary>Dark mode</summary><img src="https://raw.githubusercontent.com/djstreet11/Rowbase/main/docs/assets/dark.png" alt="Dark mode"></details>

## Build from source
- Python track: `python3 -m venv .venv && .venv/bin/pip install -e . && .venv/bin/rowbase ui`
- One-file binaries: [docs/BUILDING.md](https://github.com/djstreet11/Rowbase/blob/main/docs/BUILDING.md) · Native macOS app: `cd native && swift build` · releases: [docs/RELEASING.md](https://github.com/djstreet11/Rowbase/blob/main/docs/RELEASING.md)
- Architecture & roadmap: [SPEC.md](https://github.com/djstreet11/Rowbase/blob/main/SPEC.md)

## Contributing
Issues, ideas and pull requests are welcome — see [CONTRIBUTING.md](https://github.com/djstreet11/Rowbase/blob/main/CONTRIBUTING.md) and the
[Code of Conduct](https://github.com/djstreet11/Rowbase/blob/main/CODE_OF_CONDUCT.md). If Rowbase is useful to you, a ⭐ helps others find it.

## License
[Apache-2.0](https://github.com/djstreet11/Rowbase/blob/main/LICENSE) — see [NOTICE](https://github.com/djstreet11/Rowbase/blob/main/NOTICE) and [THIRD_PARTY_LICENSES.md](https://github.com/djstreet11/Rowbase/blob/main/THIRD_PARTY_LICENSES.md).
