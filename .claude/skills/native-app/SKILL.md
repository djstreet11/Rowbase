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
- Layout is a flat AppKit NSSplitView (SplitLayout.swift): sidebar | detail | inspector, opaque panes, no materials.
  Don't reintroduce NavigationSplitView/.inspector (macOS 26 renders them as floating glass with shadows — user rejected it;
  also invisible to cacheDisplay snapshots). The window toolbar is NOT captured by snapshots — ask the user to check it.
- Extra snapshot envs: `ROWBASE_SNAPSHOT_DB=name` (switch database first), `ROWBASE_SNAPSHOT_INSPECT=1` (inspector on row 0), `ROWBASE_SNAPSHOT_COMPLETE="sql…"` (autocomplete,
  writes `-popup.png`).
- Cancel: `Engine.execute(…, runID:)` + `Engine.cancel(runID)`; WorkTab.runID; ⌘. / Stop button.
- SSH: `Connection.ssh` → TunnelManager (system ssh, ROWBASE_SSH override, tests use tests/fixtures/fake_ssh.py);
  `TunnelManager.shutdown()` on app terminate.
- Quote tables with `Dialect.ident`, columns with `Dialect.column` (PG ident adds `public.`).
- Review checklist for delegated UI work: build, `swift test`, snapshots of table tab (PG + MySQL + SQLite), SQL tab, EXPLAIN,
  connections sheet; read AppState.run/confirm for safety.
- Database override: `AppState.databaseOverride[connId]` (UserDefaults) applied in `selectedConnection`; table-info cache key
  includes the database; tabs keep the database they were opened on.
- Clear `state.status` on connection/database switch — otherwise errors from the previous connection linger.
- Editing: WorkTab pending model (EditModel.swift: edits by ORIGINAL result row index, deleted, inserts) → buildChanges → Engine.apply.
  Grid rows map through resultRow/orig (client-side sort). Snapshot hooks: ROWBASE_SNAPSHOT_EDIT=1, _PREVIEW=1, _SAVE=1 (really saves —
  scratch DBs only; verify with psql/mysql afterwards).
- Export: AppState+Edit.swift → Exporter (Core); table tabs export the whole filtered table, query tabs re-run the last statement.
