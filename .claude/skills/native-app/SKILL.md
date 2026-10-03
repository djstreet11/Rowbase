---
name: native-app
description: Build, test, run and visually check the native macOS app (Swift, native/). Use for any change in native/, when asked to run/screenshot the Mac app, or to build Rowbase.app.
---

# native-app — Swift track (native/)

Layout: `native/Package.swift` (SwiftPM, macOS 14+, Swift 6 strict concurrency). `Sources/RowbaseCore` = models, store +
Keychain, guard port, drivers (SQLite system lib, PostgresNIO, MySQLNIO), engine actor, history. `Sources/Rowbase` =
SwiftUI app + AppKit grid/editor. `Tests/RowbaseCoreTests` = Swift Testing. Xcode can open `native/Package.swift` directly.

## Commands (cwd native/)
```
swift build                         # debug; first build ~2-3 min (NIO, BoringSSL)
swift test                          # guard conformance (../tests/guard_vectors.json) + store + engine on SQLite/PG/MariaDB
bash scripts/bundle.sh              # release build → dist/Rowbase.app (ad-hoc signed)
```
Filter build noise: `swift build 2>&1 | grep -E "error|warning: " | sort -u`.

## Visual check (no screen-recording permission here → app renders itself)
```
ROWBASE_HOME=$PWD/../.scratch-home ROWBASE_SECRETS=file ROWBASE_SNAPSHOT=$TMP/rb.png \
  ROWBASE_SNAPSHOT_CONN=lite ROWBASE_SNAPSHOT_TABLE=orders [ROWBASE_SNAPSHOT_SQL='select …'] \
  [ROWBASE_SNAPSHOT_SHEET=connections] perl -e 'alarm 40; exec @ARGV' .build/debug/Rowbase   # macOS has no `timeout`
```
Then view the PNG with Read (sheet → `…-sheet.png`). Use scratch home so the real store/Keychain stay untouched.

## Rules & pitfalls
- Safety layers must match Python: driver single statement (MySQLNIO never sets CLIENT_MULTI_STATEMENTS; PostgresNIO
  `query(String, [])` = extended protocol; sqlite tail check), guard (`SQLGuard`, vectors shared), READ ONLY tx + rollback.
- Any guard change → add vectors to `tests/guard_vectors.json` (both suites read it).
- Sessions must be closed: MySQLNIO asserts if a connection deinits open (sessions close in `deinit`; call `engine.reset()`).
- PostgresNIO: annotate `let rows: PostgresRowSequence = try await conn.query(PostgresQuery(unsafeSQL:), logger:)` — otherwise
  the EventLoopFuture overload is picked. Results are binary → `PGFormat.cell` decodes common types.
- `String(validating:as:)` is macOS 15+ → use `String(bytes:encoding:)`.
- Empty result sets have no column names (MySQL/PG text paths) — known gap.
- Snapshots: `cacheDisplay` can't capture vibrancy / the macOS 26 glass sidebar → in snapshot mode (`isSnapshot`) the app uses a
  plain HStack layout and opaque backgrounds. Keep that when changing MainView/SidebarView.
- Quote tables with `Dialect.ident`, columns with `Dialect.column` (PG ident adds `public.`).
- Review checklist for delegated UI work: build, `swift test`, snapshots of table tab (PG + MySQL + SQLite), SQL tab, EXPLAIN,
  connections sheet; read AppState.run/confirm for safety.
