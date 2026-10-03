import SwiftUI
import AppKit
import RowbaseCore

struct PendingRun: Identifiable {
    let id = UUID()
    let tab: WorkTab
    let sql: String
    let source: String
}

@MainActor @Observable
final class AppState {
    static let readOnlyVerbs: Set<String> = ["SELECT", "SHOW", "EXPLAIN", "DESC", "DESCRIBE", "WITH", "VALUES", "TABLE", "PRAGMA"]

    let store = ConnectionStore()
    let engine: Engine
    let history: History

    var connections: [Connection] = []
    var selectedConnectionID: String? {
        didSet { UserDefaults.standard.set(selectedConnectionID, forKey: "rowbase.selectedConnection") }
    }
    var tables: [TableEntry] = []
    var tablesLoading = false
    var tableFilter = ""
    var tabs: [WorkTab] = []
    var activeTabID: UUID?
    var status = ""
    var showConnections = false
    var showHistory = false
    var showInspector = false
    var filterFocusTick = 0
    var pendingRun: PendingRun?
    @ObservationIgnored private var infoCache: [String: TableInfo] = [:]
    @ObservationIgnored private var bootstrapped = false

    init() {
        engine = Engine(store: store)
        history = History(store: store)
        selectedConnectionID = UserDefaults.standard.string(forKey: "rowbase.selectedConnection")
    }

    var selectedConnection: Connection? { connections.first { $0.id == selectedConnectionID } }
    var activeTab: WorkTab? { tabs.first { $0.id == activeTabID } }
    var filteredTables: [TableEntry] {
        let f = tableFilter.trimmingCharacters(in: .whitespaces)
        return f.isEmpty ? tables : tables.filter { $0.name.localizedCaseInsensitiveContains(f) }
    }

    // MARK: connections & tables

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        loadConnections()
        await loadTables()
        await runSnapshotIfRequested()
    }

    func loadConnections() {
        do { connections = try store.load() } catch { status = error.localizedDescription }
        for t in tabs { if let c = connections.first(where: { $0.id == t.connection.id }) { t.connection = c } }
        if selectedConnection == nil { selectedConnectionID = connections.first?.id }
    }

    func selectConnection(_ id: String?) {
        guard id != selectedConnectionID else { return }
        selectedConnectionID = id
        tables = []
        Task { await loadTables() }
    }

    func loadTables() async {
        guard let conn = selectedConnection else { tables = []; return }
        tablesLoading = true
        defer { tablesLoading = false }
        do {
            let t = try await engine.tables(conn)
            if selectedConnectionID == conn.id { tables = t; status = "" }
        } catch {
            if selectedConnectionID == conn.id { tables = []; status = "Could not load tables: \(error.localizedDescription)" }
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
        let key = "\(conn.id)|\(table)"
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
        if let t = tabs.first(where: { $0.connection.id == conn.id && $0.kind == .table(name) && $0.whereText == w }) {
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

    func run(_ tab: WorkTab, explain: Bool = false) {
        if !tab.isQuery { Task { await loadTable(tab) }; return }
        var sql = SQLSplit.statement(in: tab.sql, selection: tab.selection, dialect: tab.connection.dialect)
        guard !sql.isEmpty else { return }
        if explain { sql = tab.explainPrefix + sql }
        let first = SQLGuard.analyze(sql, tab.connection.dialect).first
        if !tab.connection.readOnly && Self.mayWrite(sql, first: first, dialect: tab.connection.dialect) {
            pendingRun = PendingRun(tab: tab, sql: sql, source: "console")
            return
        }
        Task { await execute(tab, sql: sql, isExplain: explain || first == "EXPLAIN") }
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

    func confirm(_ p: PendingRun) {
        pendingRun = nil
        Task { await execute(p.tab, sql: p.sql, isExplain: false) }
    }

    private func record(_ tab: WorkTab, sql: String, source: String, result: QueryResult?, error: String?) {
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
            let r = try await engine.execute(conn, sql, limit: tab.limit)
            guard tab.token == tok else { return }
            tab.isExplain = isExplain
            tab.result = r
            tab.hasMore = r.truncated
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
            var r = try await engine.execute(conn, sql, limit: tab.limit + 1)
            guard tab.token == tok else { return }
            if r.rows.count > tab.limit { r.rows.removeLast(r.rows.count - tab.limit); r.truncated = true } else { r.truncated = false }
            tab.isExplain = false
            tab.hasMore = r.truncated
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
        tab.offset = max(0, tab.offset + dir * tab.limit)
        Task { await loadTable(tab) }
    }

    // MARK: snapshot hook

    func runSnapshotIfRequested() async {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["ROWBASE_SNAPSHOT"], !path.isEmpty else { return }
        if let name = env["ROWBASE_SNAPSHOT_CONN"], let c = connections.first(where: { $0.name.lowercased() == name.lowercased() }) {
            selectedConnectionID = c.id
            tables = []
            await loadTables()
        }
        if let w = NSApp.windows.first(where: { $0.canBecomeMain }) {
            w.setContentSize(NSSize(width: 1280, height: 800))
            w.center()
        }
        if let t = env["ROWBASE_SNAPSHOT_TABLE"], !t.isEmpty { openTable(t) }
        if let sql = env["ROWBASE_SNAPSHOT_SQL"], !sql.isEmpty, let tab = openQuery(sql: sql) { run(tab) }
        if env["ROWBASE_SNAPSHOT_SHEET"] == "connections" { showConnections = true }
        try? await Task.sleep(for: .milliseconds(2500))
        func render(_ w: NSWindow, to p: String) {
            guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: p)) }
        }
        let main = NSApp.windows.first(where: { $0.canBecomeMain && $0.sheetParent == nil })
        if let main { render(main, to: path) }
        if let sheet = main?.attachedSheet ?? NSApp.windows.first(where: { $0.sheetParent != nil }) {
            let base = (path as NSString).deletingPathExtension
            render(sheet, to: base + "-sheet.png")
        }
        exit(0)
    }
}
