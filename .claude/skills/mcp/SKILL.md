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
