# Rowbase — launch & promotion kit

Everything needed to present Rowbase on GitHub and announce it. Copy-paste ready.

## 1. GitHub repository settings

**About → Description** (≤ 350 chars):
> Fast, safe database client for humans and AI agents — MySQL/MariaDB, PostgreSQL, SQLite. Native macOS app + one-file app for Linux & Windows. Read-only by default, built-in MCP server for Claude, Cursor & Codex.

**About → Website**: `https://github.com/djstreet11/Rowbase/releases/latest` (later: a GitHub Pages site)

**About → Topics** (20, GitHub's maximum):
```
database-client database-gui sql-client mysql mariadb postgresql sqlite mcp mcp-server model-context-protocol
ai-agents claude-code macos swiftui linux windows python cli tableplus-alternative developer-tools
```

**About → checkboxes**: ✅ Releases · ❌ Packages · ❌ Deployments (cleaner sidebar)

**Settings → General**
- Social preview → upload `docs/assets/social-preview.png` (1280×640)
- Features: ✅ Discussions (issue template links to it) · ✅ Issues · ❌ Wiki (docs live in the repo) · ✅ Preserve this repository (optional)
- Pull Requests: ✅ Allow squash merging, ✅ Automatically delete head branches

**Settings → Code security**: ✅ Private vulnerability reporting (SECURITY.md and the issue template point to it) · ✅ Dependabot alerts

**Discussions** → create categories: Announcements, Q&A, Ideas, Show and tell. Pin a "Welcome — what are you using Rowbase for?" post.

**Your profile** → Pin the repository.

## 2. Release notes for v0.2.0 (edit the release, replace the auto-generated text)

```markdown
First public release 🎉

Rowbase is a fast, read-only-by-default database client for MySQL/MariaDB, PostgreSQL and SQLite —
with a native macOS app, a one-file app for macOS/Linux/Windows, and a built-in MCP server for AI assistants.

### Highlights
- **Safe by default** — connections are read-only until you switch them; 4 independent safety layers.
- **MCP server** — let Claude, Cursor, Codex & co. explore and query your databases (read-only unless you allow writes),
  token-efficient TOON output, built-in guide, one copy-paste setup prompt.
- **One file, no installer** — no admin rights, no Python, no drivers.
- **Native macOS app** — foreign-key navigation, inspector, transpose, autocomplete, EXPLAIN, query cancel,
  inline editing with SQL preview, export, SSH tunnels, dark mode.

### Downloads
| | |
|---|---|
| macOS app | `Rowbase-0.2.0.dmg` |
| macOS one-file | `rowbase-macos-arm64` |
| Linux | `rowbase-linux-x64`, `rowbase-linux-arm64` (glibc ≥ 2.28: Ubuntu 20.04+) |
| Windows 10/11 | `rowbase-windows-x64.exe` |

Builds are not code-signed yet — macOS: System Settings → Privacy & Security → Open Anyway; Windows: More info → Run anyway.
```

## 3. Where to list Rowbase

**MCP directories** (biggest audience right now)
- [punkpeye/awesome-mcp-servers](https://github.com/punkpeye/awesome-mcp-servers) — PR under "Databases"
- [Glama](https://glama.ai/mcp/servers) — indexes GitHub; claim the server page
- [Smithery](https://smithery.ai), [mcp.so](https://mcp.so), [PulseMCP](https://www.pulsemcp.com/servers) — submit form
- Official [MCP Registry](https://registry.modelcontextprotocol.io) — needs a package (PyPI/npm/OCI); see §6

**App & tool lists**
- [serhii-londar/open-source-mac-os-apps](https://github.com/serhii-londar/open-source-mac-os-apps) — "Database" section
- [mgramin/awesome-db-tools](https://github.com/mgramin/awesome-db-tools) — "IDE / GUI"
- [AlternativeTo](https://alternativeto.net) — add as an alternative to TablePlus, DBeaver, Sequel Ace, Postico

**Launch platforms** (one per day, answer every comment in the first hours)
- Hacker News — "Show HN" (Tue–Thu, ~15:00–17:00 UTC)
- Reddit — r/macapps, r/opensource, r/ClaudeAI, r/mcp, r/PostgreSQL, r/mysql, r/database (follow each sub's self-promo rules)
- Product Hunt — after ~50 stars and a few early users
- dev.to / Hashnode — technical write-up; Habr — Russian-language article

## 4. Post drafts

**Show HN**
> Show HN: Rowbase – a read-only-by-default database client with a built-in MCP server
>
> I built Rowbase because I wanted my AI agent to query our MySQL safely and couldn't find a client I liked.
> It's a native macOS app plus a one-file app for Linux/Windows (no installer, no admin rights) for MySQL/MariaDB,
> PostgreSQL and SQLite. Connections are read-only unless you switch them; that's enforced at four layers
> (single statement at the driver/protocol level, a SQL guard, READ ONLY transactions, timeouts).
> The MCP server gives Claude/Cursor/Codex tools to explore schema and run queries, returns results as TOON
> (~40% fewer tokens than JSON) and ships a guide the assistant reads first. Apache-2.0. Feedback very welcome.

**Reddit (r/macapps)**
> **Rowbase — free, open-source database client for Mac (MySQL, PostgreSQL, SQLite)**
> Native SwiftUI/AppKit app, read-only by default (prod connections get a red accent), FK navigation, row inspector,
> autocomplete, inline editing with SQL preview, export, SSH tunnels, dark mode. Also has a built-in MCP server if you
> use Claude/Cursor. DMG in releases. Would love feedback on what's missing compared to TablePlus/Sequel Ace.

**Reddit (r/ClaudeAI, r/mcp)**
> **I made an MCP server that lets Claude explore your databases safely (read-only by default)**
> Tools: connections, databases, tables, describe, search_schema, sample, count, query, explain. Output is TOON instead of
> JSON (fewer tokens). There's a `guide` tool the model reads first, and a one-paste prompt that registers the server and
> makes Claude create a skill for your DBs. Writes only when you enable them — always dry-run first, atomic.
> Single binary for macOS/Linux/Windows.

**X / LinkedIn**
> Rowbase 0.2 is out — an open-source database client for humans *and* AI agents 🧵
> • MySQL / PostgreSQL / SQLite • native macOS app + one-file Linux/Windows • read-only by default
> • built-in MCP server for Claude Code, Cursor, Codex — TOON output, built-in guide
> github.com/djstreet11/Rowbase

## 5. JetBrains open-source license
Apply at <https://www.jetbrains.com/community/opensource/> after a few months of regular commits and releases.
Have ready: repository URL, OSI license (Apache-2.0), your role (project lead), a short description (use §1),
release history and how you'll use the IDEs (PyCharm/AppCode-style Swift work, DataGrip comparison).

## 6. Next growth steps
- **PyPI package** (`rowbase` is taken by an unrelated project → publish as `rowbase-db`, command stays `rowbase`):
  enables `uvx --from rowbase-db rowbase mcp` and the official MCP Registry listing.
- **Homebrew tap** (`brew install djstreet11/tap/rowbase`) and **winget** manifest — trusted install paths.
- **Code signing** (Apple Developer ID, Windows certificate) — removes the "unknown developer" warnings.
- **Demo GIF** in the README (30 s: connect → browse → FK jump → ask Claude a question).
- Good-first-issue labels, a public roadmap (GitHub Projects), changelog per release.
