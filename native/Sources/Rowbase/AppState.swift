import SwiftUI
import AppKit
import RowbaseCore

struct PendingRun: Identifiable {
    let id = UUID()
    let tab: WorkTab
    let sql: String
    let source: String
    var isExplain = false
}

/// Persisted tab (UserDefaults JSON). Title is derived from table + WHERE, so it is not stored.
struct SavedTab: Codable {
    var kind: String            // "table" | "query"
    var table: String?
    var conn: String
    var database: String?
    var whereText: String
    var orderText: String
    var limit: Int
    var sql: String
    var transpose: Bool
}

struct SavedTabs: Codable {
    var tabs: [SavedTab]
    var active: Int?
}

@MainActor @Observable
final class AppState {
    static let readOnlyVerbs: Set<String> = ["SELECT", "SHOW", "EXPLAIN", "DESC", "DESCRIBE", "WITH", "VALUES", "TABLE", "PRAGMA"]

    let store = ConnectionStore()
    let engine: Engine
    let history: History

    var connections: [Connection] = []
    var selectedConnectionID: String? {
        didSet { AppDefaults.store.set(selectedConnectionID, forKey: "rowbase.selectedConnection") }
    }
    var tables: [TableEntry] = []
    var databases: [String] = []        // server databases of the selected connection (empty for SQLite)
    var currentDatabase: String?        // what the session actually uses (nil: MySQL connection without a database)
    /// Per-connection database chosen in the sidebar, overriding the connection's configured one (UI state, not saved to connections.json).
    var databaseOverride: [String: String] = AppDefaults.store.dictionary(forKey: "rowbase.databaseOverride") as? [String: String] ?? [:] {
        didSet { AppDefaults.store.set(databaseOverride, forKey: "rowbase.databaseOverride") }
    }
    var tablesLoading = false
    var tableFilter = ""
    var tabs: [WorkTab] = []
    var activeTabID: UUID? { didSet { loadIfNeeded() } }
    /// Sidebar kind filter: "all" | "table" | "view".
    var kindFilter: String = AppDefaults.store.string(forKey: "rowbase.kindFilter") ?? "all" {
        didSet { AppDefaults.store.set(kindFilter, forKey: "rowbase.kindFilter") }
    }
    var status = ""
    var showConnections = false
    var showHistory = false
    var showAIMCP = false
    var showInspector = false
    var showSidebar: Bool = AppDefaults.store.object(forKey: "rowbase.showSidebar") as? Bool ?? true {
        didSet { AppDefaults.store.set(showSidebar, forKey: "rowbase.showSidebar") }
    }
    var filterFocusTick = 0
    var pendingRun: PendingRun?
    var alert: AppAlert?
    var pendingSave: WorkTab?
    var pendingDiscard: PendingDiscard?
    var exportPrompt: ExportPrompt?
    @ObservationIgnored private var infoCache: [String: TableInfo] = [:]
    @ObservationIgnored private var bootstrapped = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var persistTabs = false

    init() {
        engine = Engine(store: store)
        history = History(store: store)
        selectedConnectionID = AppDefaults.store.string(forKey: "rowbase.selectedConnection")
    }

    /// Selected connection with the sidebar's database choice applied — everything opened from the sidebar uses this.
    var selectedConnection: Connection? {
        guard var c = connections.first(where: { $0.id == selectedConnectionID }) else { return nil }
        if let db = databaseOverride[c.id] { c.database = db }
        return c
    }

    /// MySQL connection with no database configured or chosen: tables can't be listed until one is picked.
    var needsDatabase: Bool { selectedConnection.map { $0.dialect == .mysql && ($0.database ?? "").isEmpty } ?? false }

    func selectDatabase(_ db: String?) {
        guard let base = connections.first(where: { $0.id == selectedConnectionID }) else { return }
        databaseOverride[base.id] = (db == nil || db == base.database) ? nil : db
        tables = []
        status = ""
        Task { await loadTables() }
    }
    var activeTab: WorkTab? { tabs.first { $0.id == activeTabID } }
    var filteredTables: [TableEntry] {
        let f = tableFilter.trimmingCharacters(in: .whitespaces)
        return tables.filter {
            (kindFilter == "all" || $0.isView == (kindFilter == "view")) && (f.isEmpty || $0.name.localizedCaseInsensitiveContains(f))
        }
    }

    // MARK: connections & tables

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        loadConnections()
        // Snapshot runs neither restore nor save tabs unless ROWBASE_SNAPSHOT_RESTORE is set (=save: save only, =1: restore + save).
        let snapRestore = ProcessInfo.processInfo.environment["ROWBASE_SNAPSHOT_RESTORE"]
        persistTabs = !isSnapshot || snapRestore != nil
        if !isSnapshot || snapRestore == "1" { restoreTabs() }
        if persistTabs { trackTabs() }
        await loadTables()
        await runSnapshotIfRequested()
    }

    // MARK: tab persistence

    private static let tabsKey = "rowbase.tabs"

    private func currentSaved() -> SavedTabs {
        SavedTabs(tabs: tabs.map {
            SavedTab(kind: $0.isQuery ? "query" : "table", table: $0.tableName, conn: $0.connection.id, database: $0.connection.database,
                     whereText: $0.whereText, orderText: $0.orderText, limit: $0.limit, sql: $0.sql, transpose: $0.transpose)
        }, active: tabs.firstIndex { $0.id == activeTabID })
    }

    /// Re-arming observation: any change to the tab list or a persisted tab property schedules a debounced save.
    private func trackTabs() {
        withObservationTracking {
            _ = currentSaved()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduleSave()
                self.trackTabs()
            }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveTabsNow()
        }
    }

    func saveTabsNow() {
        guard persistTabs, let d = try? JSONEncoder().encode(currentSaved()) else { return }
        AppDefaults.store.set(d, forKey: Self.tabsKey)
    }

    private func restoreTabs() {
        guard let d = AppDefaults.store.data(forKey: Self.tabsKey), let saved = try? JSONDecoder().decode(SavedTabs.self, from: d) else { return }
        var restored: [(Int, WorkTab)] = []
        for (i, s) in saved.tabs.enumerated() {
            guard var c = connections.first(where: { $0.id == s.conn }) else { continue }  // connection deleted → drop tab
            if c.dialect != .sqlite { c.database = s.database ?? c.database }
            let t: WorkTab
            if s.kind == "table", let name = s.table {
                t = WorkTab(kind: .table(name), connection: c)
                t.needsLoad = true
            } else { t = WorkTab(kind: .query, connection: c) }
            t.whereText = s.whereText
            t.orderText = s.orderText
            t.limit = s.limit
            t.sql = s.sql
            t.transpose = s.transpose
            restored.append((i, t))
        }
        guard !restored.isEmpty else { return }
        tabs = restored.map(\.1)
        let active = saved.active.flatMap { a in restored.first { $0.0 == a }?.1 } ?? restored.last?.1
        activeTabID = active?.id
    }

    /// Restored table tabs load only when first activated (no burst of queries at launch).
    private func loadIfNeeded() {
        guard let t = activeTab, t.needsLoad else { return }
        t.needsLoad = false
        Task { await loadTable(t) }
    }

    func loadConnections() {
        do { connections = try store.load() } catch { status = error.localizedDescription }
        for t in tabs {  // refresh edited connection settings but keep the database each tab was opened on
            if var c = connections.first(where: { $0.id == t.connection.id }) { c.database = t.connection.database ?? c.database; t.connection = c }
        }
        if selectedConnection == nil { selectedConnectionID = connections.first?.id }
    }

    func selectConnection(_ id: String?) {
        guard id != selectedConnectionID else { return }
        selectedConnectionID = id
        tables = []
        status = ""  // errors belong to the previous connection
        Task { await loadTables() }
    }

    func loadTables() async {
        guard let conn = selectedConnection else { tables = []; databases = []; currentDatabase = nil; return }
        tablesLoading = true
        defer { tablesLoading = false }
        if conn.dialect != .sqlite {
            let dbs = (try? await engine.databases(conn)) ?? []
            let cur = try? await engine.currentDatabase(conn)
            guard selectedConnection == conn else { return }
            databases = dbs.sorted { (Catalog.systemDatabases.contains($0) ? 1 : 0, $0) < (Catalog.systemDatabases.contains($1) ? 1 : 0, $1) }
            currentDatabase = cur ?? nil
        } else { databases = []; currentDatabase = nil }
        if needsDatabase { tables = []; status = ""; return }
        do {
            let t = try await engine.tables(conn)
            if selectedConnection == conn { tables = t; status = "" }
        } catch {
            if selectedConnection == conn { tables = []; status = "Could not load tables: \(error.localizedDescription)" }
        }
    }

    func refresh() {
        infoCache.removeAll()
        Task { await loadTables() }
    }

    func afterSave(_ saved: Connection) async {
        loadConnections()
        selectedConnectionID = saved.id
        await engine.reset(saved.id)
        infoCache = infoCache.filter { !$0.key.hasPrefix(saved.id + "|") }
        await loadTables()
    }

    func afterDelete(_ id: String) async {
        await engine.reset(id)
        let wasSelected = selectedConnectionID == id
        loadConnections()
        if wasSelected { tables = []; await loadTables() }
    }

    func tableInfo(for conn: Connection, table: String) async throws -> TableInfo {
        let key = "\(conn.id)|\(conn.database ?? "")|\(table)"  // same table name can exist in several databases
        if let i = infoCache[key] { return i }
        let i = try await engine.tableInfo(conn, table)
        infoCache[key] = i
        return i
    }

    func clearInfo(for conn: Connection) {
        infoCache = infoCache.filter { !$0.key.hasPrefix(conn.id + "|") }
    }

    // MARK: tabs

    func activate(_ id: UUID) {
        activeTabID = id
    }

    func openTable(_ name: String, where w: String = "", chain: [Crumb] = [], connection: Connection? = nil) {
        guard let conn = connection ?? selectedConnection else { return }
        if let t = tabs.first(where: { $0.connection.id == conn.id && $0.connection.database == conn.database && $0.kind == .table(name) && $0.whereText == w }) {
            activeTabID = t.id
            return
        }
        let t = WorkTab(kind: .table(name), connection: conn)
        t.whereText = w
        t.breadcrumbs = chain
        tabs.append(t)
        activeTabID = t.id
        Task { await reload(t) }
    }

    @discardableResult
    func openQuery(sql: String = "", connection: Connection? = nil) -> WorkTab? {
        guard let conn = connection ?? selectedConnection else { return nil }
        let t = WorkTab(kind: .query, connection: conn)
        t.sql = sql
        tabs.append(t)
        activeTabID = t.id
        return t
    }

    func closeTab(_ id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: i)
        if activeTabID == id { activeTabID = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)].id }
        if tabs.isEmpty { showInspector = false }
    }

    func followFK(from tab: WorkTab, column: String, value: String) {
        guard let fk = tab.info?.columns.first(where: { $0.name == column })?.fk else { return }
        let d = tab.connection.dialect
        let lit = value.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil ? value : d.literal(value)
        openTable(fk.table, where: "\(d.column(fk.column)) = \(lit)", chain: chain(from: tab, via: column), connection: tab.connection)
    }

    func chain(from tab: WorkTab, via: String?) -> [Crumb] {
        tab.breadcrumbs + [Crumb(title: tab.title, tabID: tab.id, table: tab.tableName ?? "", whereText: tab.whereText, via: via)]
    }

    func openCrumb(_ c: Crumb, from tab: WorkTab) {
        if let id = c.tabID, tabs.contains(where: { $0.id == id }) { activeTabID = id }
        else { openTable(c.table, where: c.whereText, connection: tab.connection) }
    }

    func toggleSidebar() { showSidebar.toggle() }
    func toggleInspector() { showInspector.toggle() }

    func inspect(_ tab: WorkTab, row: Int) {
        tab.inspectRow = row
        showInspector = true
    }

    // MARK: running

    func reload(_ tab: WorkTab) async {
        switch tab.kind {
        case .table: await loadTable(tab)
        case .query: run(tab)
        }
    }

    func runActive() {
        guard let t = activeTab else { return }
        run(t)
    }

    func run(_ tab: WorkTab, explain: Bool = false, analyze: Bool = false) {
        if !tab.isQuery { Task { await loadTable(tab) }; return }
        var sql = SQLSplit.statement(in: tab.sql, selection: tab.selection, dialect: tab.connection.dialect)
        guard !sql.isEmpty else { return }
        if explain || analyze {
            // never stack prefixes: EXPLAIN [ANALYZE | QUERY PLAN] <stmt> → <new prefix> <stmt>
            sql = sql.replacingOccurrences(of: #"^\s*EXPLAIN(\s+ANALYZE|\s+QUERY\s+PLAN)?\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
            sql = (analyze ? "EXPLAIN ANALYZE " : tab.explainPrefix) + sql
        }
        let first = SQLGuard.analyze(sql, tab.connection.dialect).first
        let isExplain = explain || analyze || first == "EXPLAIN"
        if !tab.connection.readOnly && Self.mayWrite(sql, first: first, dialect: tab.connection.dialect) {
            pendingRun = PendingRun(tab: tab, sql: sql, source: "console", isExplain: isExplain)
            return
        }
        Task { await execute(tab, sql: sql, isExplain: isExplain) }
    }

    /// Confirmation needed on RW connections: any non-read verb, and WITH/EXPLAIN wrapping a write
    /// (data-modifying CTEs, EXPLAIN ANALYZE DELETE … actually execute).
    static func mayWrite(_ sql: String, first: String, dialect: Dialect) -> Bool {
        if !readOnlyVerbs.contains(first) { return true }
        guard first == "WITH" || first == "EXPLAIN" else { return false }
        let bare = SQLGuard.analyze(sql, dialect).bare
        return bare.range(of: #"\b(INSERT|UPDATE|DELETE|MERGE|TRUNCATE|DROP|ALTER|CREATE|REPLACE|GRANT|REVOKE)\b"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Stop the tab's running statement (KILL QUERY / pg_cancel_backend / sqlite3_interrupt via Engine.cancel).
    func cancel(_ tab: WorkTab) {
        guard tab.running, let id = tab.runID else { return }
        Task { await engine.cancel(id) }
    }

    func confirm(_ p: PendingRun) {
        pendingRun = nil
        Task { await execute(p.tab, sql: p.sql, isExplain: p.isExplain) }
    }

    func record(_ tab: WorkTab, sql: String, source: String, result: QueryResult?, error: String?) {
        history.add(History.Entry(conn: tab.connection.id, connName: tab.connection.name, sql: sql, source: source,
                                  rows: result?.rows.count, elapsed: result?.elapsed, error: error, affected: result?.affected))
    }

    func execute(_ tab: WorkTab, sql: String, isExplain: Bool) async {
        tab.token += 1
        let tok = tab.token
        tab.running = true
        tab.error = nil
        tab.note = nil
        let conn = tab.connection
        do {
            let id = UUID(); tab.runID = id
            let r = try await engine.execute(conn, sql, limit: tab.limit, runID: id)
            guard tab.token == tok else { return }
            tab.isExplain = isExplain
            tab.result = r
            tab.hasMore = r.truncated
            tab.lastSQL = sql
            tab.exportable = !isExplain && !r.columns.isEmpty && r.affected == nil
                && !Self.mayWrite(sql, first: SQLGuard.analyze(sql, conn.dialect).first, dialect: conn.dialect)
            record(tab, sql: sql, source: "console", result: r, error: nil)
            if r.affected != nil { clearInfo(for: conn); if conn.id == selectedConnectionID { await loadTables() } }
        } catch {
            guard tab.token == tok else { return }
            tab.result = nil
            tab.error = error.localizedDescription
            record(tab, sql: sql, source: "console", result: nil, error: error.localizedDescription)
        }
        if tab.token == tok { tab.running = false }
    }

    func loadTable(_ tab: WorkTab) async {
        guard let table = tab.tableName else { return }
        tab.token += 1
        let tok = tab.token
        tab.running = true
        tab.error = nil
        tab.note = nil
        let conn = tab.connection
        if tab.info == nil {
            do { tab.info = try await tableInfo(for: conn, table: table) }
            catch {
                guard tab.token == tok else { return }
                tab.error = error.localizedDescription
                tab.running = false
                return
            }
        }
        let sql = tab.buildSQL(extra: 1)
        do {
            let id = UUID(); tab.runID = id
            var r = try await engine.execute(conn, sql, limit: tab.limit + 1, runID: id)
            guard tab.token == tok else { return }
            if r.rows.count > tab.limit { r.rows.removeLast(r.rows.count - tab.limit); r.truncated = true } else { r.truncated = false }
            tab.isExplain = false
            tab.hasMore = r.truncated
            tab.clearPending()  // row indexes of the old page are gone
            tab.result = r
            record(tab, sql: tab.buildSQL(), source: "table", result: r, error: nil)
        } catch {
            guard tab.token == tok else { return }
            tab.result = nil
            tab.error = error.localizedDescription
            record(tab, sql: tab.buildSQL(), source: "table", result: nil, error: error.localizedDescription)
        }
        if tab.token == tok { tab.running = false }
    }

    func count(_ tab: WorkTab) async {
        let sql = tab.countSQL()
        do {
            let r = try await engine.execute(tab.connection, sql, limit: 1)
            tab.note = "Count: \(r.rows.first?.first.flatMap { $0 } ?? "?") · \(formatElapsed(r.elapsed))"
            record(tab, sql: sql, source: "table", result: r, error: nil)
        } catch {
            tab.note = "Count failed: \(error.localizedDescription)"
            record(tab, sql: sql, source: "table", result: nil, error: error.localizedDescription)
        }
    }

    func page(_ tab: WorkTab, by dir: Int) {
        guardPending(tab) { [self] in
            tab.offset = max(0, tab.offset + dir * tab.limit)
            Task { await loadTable(tab) }
        }
    }

    // MARK: snapshot hook

    func runSnapshotIfRequested() async {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["ROWBASE_SNAPSHOT"], !path.isEmpty else { return }
        if env["ROWBASE_SNAPSHOT_DARK"] == "1" { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if let name = env["ROWBASE_SNAPSHOT_CONN"], let c = connections.first(where: { $0.name.lowercased() == name.lowercased() }) {
            selectedConnectionID = c.id
            tables = []
            await loadTables()
        }
        if let w = NSApp.windows.first(where: { $0.canBecomeMain }) {
            w.setContentSize(NSSize(width: 1280, height: 800))
            w.center()
        }
        if let db = env["ROWBASE_SNAPSHOT_DB"], !db.isEmpty {
            selectDatabase(db)
            try? await Task.sleep(for: .milliseconds(800))
        }
        if let t = env["ROWBASE_SNAPSHOT_TABLE"], !t.isEmpty { openTable(t) }
        if let sql = env["ROWBASE_SNAPSHOT_SQL"], !sql.isEmpty, let tab = openQuery(sql: sql) { run(tab) }
        var completeTab: WorkTab?
        if let text = env["ROWBASE_SNAPSHOT_COMPLETE"], !text.isEmpty, let tab = openQuery(sql: text) { completeTab = tab }
        if let t = activeTab {
            if env["ROWBASE_SNAPSHOT_TRANSPOSE"] == "1" { t.transpose = true }
            if let h = env["ROWBASE_SNAPSHOT_HIDE"], !h.isEmpty { t.hidden = Set(h.split(separator: ",").map(String.init)) }
        }
        if env["ROWBASE_SNAPSHOT_INSPECT"] == "1" {
            try? await Task.sleep(for: .milliseconds(1200))
            if let t = activeTab { inspect(t, row: 0) }
        }
        if let tab = completeTab {
            try? await Task.sleep(for: .milliseconds(600))
            if let tv = tab.editor {
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
                tv.completer?.update(force: true)
            }
        }
        if env["ROWBASE_SNAPSHOT_SHEET"] == "connections" { showConnections = true }
        if env["ROWBASE_SNAPSHOT_SHEET"] == "ai" { showAIMCP = true }
        if env["ROWBASE_SNAPSHOT_SHEET"] == "history" { showHistory = true }
        try? await Task.sleep(for: .milliseconds(2500))
        if env["ROWBASE_SNAPSHOT_COLUMNS"] == "1", let t = activeTab {
            t.columnPickerOpen = true
            try? await Task.sleep(for: .milliseconds(800))
        }
        if let text = env["ROWBASE_SNAPSHOT_WHERE_COMPLETE"], !text.isEmpty, let t = activeTab, let f = t.whereField, let c = t.whereCompleter {
            t.whereText = text
            try? await Task.sleep(for: .milliseconds(300))
            f.window?.makeFirstResponder(f)
            if let ed = f.currentEditor() as? NSTextView {
                ed.setSelectedRange(NSRange(location: (ed.string as NSString).length, length: 0))
                c.tv = ed
                c.update(force: true)
                try? await Task.sleep(for: .milliseconds(800))
            }
        }
        if env["ROWBASE_SNAPSHOT_EDIT"] == "1" || env["ROWBASE_SNAPSHOT_PREVIEW"] == "1" || env["ROWBASE_SNAPSHOT_SAVE"] == "1", let t = activeTab, t.tableName != nil {
            var waited = 0
            while (t.result == nil || t.info == nil) && waited < 40 { try? await Task.sleep(for: .milliseconds(250)); waited += 1 }
            if t.canEdit, let r = t.result {
                let col = r.columns.contains("note") ? "note" : (r.columns.first { t.isEditable($0) && !(t.info?.primaryKey.contains($0) ?? true) } ?? "")
                t.setCell(CellRef(insert: false, row: 0, column: col), to: "edited")
                t.deleteRows(result: [1], inserts: [])
                t.addInsertRow()
                t.setCell(CellRef(insert: true, row: 0, column: col), to: "new")
            }
            try? await Task.sleep(for: .milliseconds(700))
            if env["ROWBASE_SNAPSHOT_SAVE"] == "1" {  // exercises the real save path (scratch databases only)
                await save(t)
                try? await Task.sleep(for: .milliseconds(1200))
            }
            if env["ROWBASE_SNAPSHOT_PREVIEW"] == "1" {
                await previewSQL(t)
                try? await Task.sleep(for: .milliseconds(900))
            }
        }
        func render(_ w: NSWindow, to p: String) {
            // Theme frame (contentView.superview) includes titlebar + toolbar chrome; the content view is drawn
            // on top explicitly because SwiftUI-hosted content is not always part of the theme frame's cache pass.
            guard let content = w.contentView else { return }
            let frameView = content.superview ?? content
            guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            if frameView !== content, let crep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: crep)
                let img = NSImage(size: frameView.bounds.size)
                img.addRepresentation(rep)
                let out = NSImage(size: frameView.bounds.size)
                out.lockFocus()
                img.draw(in: NSRect(origin: .zero, size: frameView.bounds.size))
                let cimg = NSImage(size: content.bounds.size)
                cimg.addRepresentation(crep)
                let f = content.convert(content.bounds, to: frameView)
                cimg.draw(in: f)
                out.unlockFocus()
                if let tiff = out.tiffRepresentation, let r2 = NSBitmapImageRep(data: tiff),
                   let png = r2.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: p)); return }
            }
            if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: p)) }
        }
        let main = NSApp.windows.first(where: { $0.canBecomeMain && $0.sheetParent == nil })
        if let main { render(main, to: path) }
        if let pop = completeTab?.editor?.completer?.popup.window, let v = pop.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            let base = (path as NSString).deletingPathExtension
            if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: base + "-popup.png")) }
        }
        let base0 = (path as NSString).deletingPathExtension
        if activeTab?.columnPickerOpen == true {
            for (i, w) in NSApp.windows.enumerated() where w !== main && w.isVisible && w.sheetParent == nil && w.contentView != nil && w !== completeTab?.editor?.completer?.popup.window {
                render(w, to: base0 + "-popover\(i).png")
            }
        }
        if let pop = activeTab?.whereCompleter?.popup.window {
            render(pop, to: base0 + "-wherepopup.png")
        }
        if let sheet = main?.attachedSheet ?? NSApp.windows.first(where: { $0.sheetParent != nil }) {
            let base = (path as NSString).deletingPathExtension
            render(sheet, to: base + "-sheet.png")
        }
        saveTabsNow()
        exit(0)
    }
}
