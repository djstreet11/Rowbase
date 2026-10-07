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
- Filters/builder snapshot envs: `ROWBASE_SNAPSHOT_FILTERS='<FilterGroup JSON>'` (set before first load), `ROWBASE_SNAPSHOT_FILTER_POP=col`
  (real header-button path → `-filterpop.png`, content view only: popover material renders as garbage), `ROWBASE_SNAPSHOT_CELLMENU=col:row:prefix`
  (builds the real cell context menu, runs the item whose title starts with prefix), `ROWBASE_SNAPSHOT_BUILDER=1` (builder from the table tab,
  `ROWBASE_SNAPSHOT_RUN=1` runs it) / `=demo` (orders ⟕ customers via FK suggestion + aggregates, runs). Every snapshot prints
  `ROWBASE_SQL` / `ROWBASE_COUNT_SQL` / `ROWBASE_EXPORT_SQL` / `ROWBASE_ROWS` / `ROWBASE_ERROR` to stdout — compare with psql/mysql/sqlite3.
- Column filters: `WorkTab.filters` (FilterGroup) → `effectiveWhere()`; a filter that can't become SQL must error (loadTable) or block
  (`AppState.filtersOK` for count/export/open-in-editor), never be dropped. Builder: `QBModel` (source ids) → `.spec` (QuerySpec) →
  `QueryBuilder.selectSQL`; `WorkTab.isQuery` = not a table tab (SQL or builder), `isBuilder` for the builder.
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
- Design system (2026-10-04 pass): window title = active tab, subtitle = connection · database; connection/db/RO-RW live ONLY in the
  window toolbar (AppToolbar.swift, connection = Button+popover because toolbar Menus drop styled labels); one 34pt tab toolbar with
  icon-only buttons + "…" overflow; pagination/metrics in the status bar; grid headers show types, numeric right-aligned, no striping
  in empty area, NULL capsule; editor gutter with line numbers. Keep new UI consistent with this.
- Snapshots render the window frame (titlebar/toolbar included) + content view; toolbar/sidebar look greyed because the snapshot
  window is inactive — not a bug. `ROWBASE_SNAPSHOT_DARK=1` for dark mode (titlebar may render light: artifact, verify live).
- Grid performance (wide tables, 70+ columns): NSTableView creates cell views for ALL columns of every visible row (prepared
  rect = full width; prepareContent override and responsive-scrolling opt-out don't change it). So GridCell must stay cheap:
  frame layout in `layout()` (NO Auto Layout constraints — they made CoreAutoLayout eat ~100% CPU), NULL pill / FK arrow created
  lazily, layer only when tinted, display text = short prefix (Refs/ResultGrid `display`), O(1) `utf8.count` checks.
  Measure with `ROWBASE_SNAPSHOT_SCROLL=N` (prints ms per scroll step; `.scratch-home/wide.db` style fixture) + `sample <pid>`.
- NEVER give a Swift `NSCell` subclass (header/data cells) stored object properties (String, class refs): AppKit copies cells
  with NSCopyObject (bitwise, no retain) — e.g. NSTableHeaderView's filler cell — → double release, heap corruption, crash
  (v0.2.2 on macOS 15). Put the data in `representedObject` (see GridHeaderInfo in ResultGrid.swift).
- SwiftUI row Bindings (`ForEach($model.items) { $x in … }`): a button action must NOT read `$x`/`x` while mutating the same array
  (`items.removeAll { $0.id == x.id }` → "Simultaneous accesses … Fatal access conflict", user crash 2026-10-07). Capture
  `let id = x.id` while rendering and use it in the action. Repro hook: `ROWBASE_SNAPSHOT_BUILDER=demo ROWBASE_SNAPSHOT_PRESS_REMOVE=6`.
- NEVER use SwiftUI `.textSelection(.enabled)` — use `SelectableText` (Util.swift, AppKit NSTextField). A user crash on macOS 15.0.1
  (pointer-auth trap in CoreText while SwiftUI released selectable text whose content changed, 2026-10-05) led to this rule.
  We develop on macOS 26 — test-sensitive UI paths may behave differently on macOS 14/15; ask the user for crash reports there.
- Auto-update = Sparkle 2 (Updater.swift, docs/UPDATES.md). `AppUpdater` is inert without `SUPublicEDKey` in Info.plist (so
  `.build/debug/Rowbase` and snapshots never check). bundle.sh copies Sparkle.framework to Contents/Frameworks, adds the rpath,
  signs Sparkle's XPC services/Autoupdate/Updater.app → framework → app (never `--deep`). Sparkle types are `@MainActor` in Swift.
  Verify an update end-to-end (done 2026-10-05, recipe in docs/UPDATES.md "Verified on a Mac"): old bundle copied to /tmp (keep the
  user's /Applications app untouched), new = throwaway commit (CFBundleVersion = commit count must grow) + VERSION bump, zip with
  `ditto -c -k --sequesterRsrc --keepParent`, `sign_update` (key in login Keychain), packaging/appcast.py, `python3 -m http.server`,
  `defaults write dev.rowbase.Rowbase SUFeedURL http://127.0.0.1:<port>/appcast.xml` (plain-http loopback works). Cleanup: delete
  ALL SU* defaults keys + ~/Library/Caches/dev.rowbase.Rowbase/org.sparkle-project.Sparkle, drop the commit, rebuild dist.
