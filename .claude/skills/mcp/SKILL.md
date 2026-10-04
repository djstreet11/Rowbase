---
name: mcp
description: Work on or use Rowbase's MCP server (rowbase/mcp.py) — add/change tools, the guide (knowledge base), TOON output, MCP settings, client setup snippets and the setup prompt. Use for anything MCP/AI-assistant related.
---

# mcp — Rowbase MCP server

- Code: `rowbase/mcp.py` (stdio JSON-RPC, stdlib only), TOON encoder `rowbase/toon.py`, settings in `store.settings()` /
  `save_settings()` (`~/.config/rowbase/settings.json` → "mcp"). Docs: docs/MCP.md.
- Safety: `_conn()` forces readOnly unless settings.mcp.allowWrites; exposure list via `_exposed()`; `apply_changes` is only
  listed when writes are allowed and defaults to dry_run. Never weaken this; add tests in tests/test_mcp.py.
- Adding a tool: function `t_<name>(args) -> str` returning TOON (use `toon.table`/`toon.encode`, missing values = None → `null`),
  register in `TOOLS` with JSON schema + toolset level ("minimal" or "full"), document it in `GUIDE` and docs/MCP.md.
- TOON rules pinned by tests/toon_vectors.json (native port must match). Canonical-decimal strings are emitted unquoted.
- Client setup: `client_config()` (claude_code, claude_desktop, cursor, vscode, codex, prompt); `rowbase mcp --print-config [--json]`.
  The web UI (AI / MCP panel) and the native sheet (MCPSupport.swift → embedded Resources/rowbase) consume it.
- Manual test: `printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"tables","arguments":{"connection":"NAME"}}}' | rowbase mcp`
  (stdout must contain only protocol lines; diagnostics go to stderr).
- Verifying with a real client: `claude mcp list` shows health; a full assistant run needs a NEW Claude Code session (servers load at
  start). In-session, simulate the client: read command/args from ~/.claude.json → spawn → initialize → tools/call (see git log 2026-10-04).
- Rebuild dist/rowbase-macos-arm64 after Python changes — Claude Code runs that binary, not the venv.
- Dockerfile (repo root) runs `rowbase mcp` as non-root with ROWBASE_SECRETS=file — used by Glama's automated checks; keep it working
  (test: build, pipe initialize + tools/list into `docker run -i --rm <img>`).
- Glama (https://glama.ai/mcp/servers/djstreet11/Rowbase): build spec is configured on Glama's admin page, not from our Dockerfile —
  Build steps `["uv sync"]`, CMD `["mcp-proxy","--","uv","run","rowbase","mcp"]` (without `mcp` rowbase opens the web UI and checks hang),
  no env/placeholders needed. glama.json lists maintainers. Verified locally with their exact Dockerfile + mcp-proxy HTTP (2026-10-05).
- Tool descriptions follow one shape (from Glama TDQS feedback 2026-10-05): what it does → when to use it and which sibling to use
  INSTEAD → exact return shape (no output schema) → limits/errors. Every param has a description; tools have `title`;
  `query` annotations flip to readOnlyHint=false when allowWrites. Guarded by test_tool_definitions_quality.
