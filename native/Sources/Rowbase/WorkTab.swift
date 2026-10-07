import SwiftUI
import AppKit
import RowbaseCore

struct Crumb: Hashable, Identifiable {
    var id = UUID()
    var title: String
    var tabID: UUID?
    var table: String
    var whereText: String
    var via: String?
}

@MainActor @Observable
final class WorkTab: Identifiable {
    enum Kind: Equatable { case table(String), query, builder }

    let id = UUID()
    let kind: Kind
    var connection: Connection
    var whereText = ""
    /// Column filters (table tabs): AND-ed with the raw WHERE text. Contract: QueryBuilder.filterWhere.
    var filters = FilterGroup(match: "all", conds: [])
    /// Visual query builder model (builder tabs).
    var builder = QBModel()
    var orderText = ""
    var limit = 100
    var offset = 0
    var sql = ""
    var result: QueryResult? { didSet { resultVersion += 1 } }
    var resultVersion = 0
    var error: String?
    var runID: UUID?  // identifies the in-flight statement for Engine.cancel
    var running = false { didSet { if running && !oldValue { runStart = Date() } } }
    var info: TableInfo?
    var showStructure = false
    var breadcrumbs: [Crumb] = []
    var inspectRow: Int?
    var isExplain = false
    var hasMore = false
    var note: String?
    var runStart: Date?
    var transpose = false
    var columnPickerOpen = false
    // Pending edits (table tabs). Row indexes refer to the loaded page (result.rows); `inserts[0]` is the top row of the grid.
    var edits: [Int: [String: NewValue]] = [:] { didSet { pendingVersion += 1 } }
    var deleted: Set<Int> = [] { didSet { pendingVersion += 1 } }
    var inserts: [[String: NewValue]] = [] { didSet { pendingVersion += 1 } }
    var pendingVersion = 0
    var selectedRows: Set<Int> = []
    var selectedInserts: Set<Int> = []
    var editSheet: CellRef?
    var previewStatements: [String]?
    var saving = false
    var exporting = false
    var hint: String?
    /// Display label of the referenced object (implicit-reference navigation), shown in the title.
    var label: String?
    @ObservationIgnored var labelWhere = ""   // label applies only while the filter is unchanged
    /// Query tabs: last successfully executed statement and whether re-running it for export is safe (read-only verb).
    var lastSQL = ""
    var exportable = false
    @ObservationIgnored var hintToken = 0
    /// Columns hidden in grid / transpose / copy. Table tabs persist this per connection+database+table.
    var hidden: Set<String> = [] { didSet { if oldValue != hidden { saveHidden() } } }
    /// Restored from the previous session: load the data when the tab is first activated.
    @ObservationIgnored var needsLoad = false
    @ObservationIgnored weak var whereField: NSTextField?
    @ObservationIgnored weak var whereCompleter: Completer?
    @ObservationIgnored var selection = NSRange(location: 0, length: 0)
    @ObservationIgnored var token = 0
    @ObservationIgnored weak var editor: SQLTextView?

    init(kind: Kind, connection: Connection) {
        self.kind = kind
        self.connection = connection
        if tableName == nil { limit = 500 }
        if let k = hiddenKey { hidden = Set(AppDefaults.store.stringArray(forKey: k) ?? []) }
    }

    private var hiddenKey: String? {
        guard let t = tableName else { return nil }
        return "rowbase.hidden.\(connection.id).\(connection.database ?? "").\(t)"
    }

    private func saveHidden() {
        guard let k = hiddenKey else { return }
        if hidden.isEmpty { AppDefaults.store.removeObject(forKey: k) } else { AppDefaults.store.set(hidden.sorted(), forKey: k) }
    }

    /// Every column the picker can offer: result columns, else the table's columns.
    var allColumns: [String] { result?.columns ?? info?.columns.map(\.name) ?? [] }

    /// Result restricted to the visible columns (what Copy JSON / TSV export).
    var visibleExport: (columns: [String], rows: [[String?]])? {
        guard let r = result else { return nil }
        let idx = r.columns.indices.filter { !hidden.contains(r.columns[$0]) }
        return (idx.map { r.columns[$0] }, r.rows.map { row in idx.map { $0 < row.count ? row[$0] : nil } })
    }

    var tableName: String? { if case .table(let t) = kind { t } else { nil } }
    /// Not a table tab: SQL console or query builder (results come from a statement, not table paging).
    var isQuery: Bool { tableName == nil }
    var isBuilder: Bool { kind == .builder }

    var title: String {
        switch kind {
        case .table(let t):
            if let label, whereText == labelWhere { return "\(t) · \(label)" }
            let w = Self.strip(whereText, "WHERE")
            let f = filters.conds?.count ?? 0
            let base = w.isEmpty ? t : "\(t) · \(w)"
            return f == 0 ? base : "\(base) · \(plural(f, "filter"))"
        case .query: return "SQL"
        case .builder: return builder.from.table.isEmpty ? "Query Builder" : "Builder · \(builder.from.table)"
        }
    }

    static func strip(_ s: String, _ kw: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix(";") { t.removeLast() }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.uppercased().hasPrefix(kw + " ") || t.uppercased() == kw {
            t = String(t.dropFirst(kw.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }

    var columnTypes: [String: String] {
        Dictionary((info?.columns ?? []).map { ($0.name, $0.type) }, uniquingKeysWith: { a, _ in a })
    }

    /// Column filters → condition text ('' when none). `without`: leave out that column's filter (value list of its popover).
    func filterSQL(without: String? = nil, group: FilterGroup? = nil) throws -> String {
        var g = group ?? filters
        if let without { g.conds = g.conds?.filter { $0.col != without } }
        return try QueryBuilder.filterWhere(connection.dialect, g, types: columnTypes)
    }

    /// Raw WHERE text AND column filters — used by data, COUNT, export and "Open in SQL Editor".
    func effectiveWhere(without: String? = nil) throws -> String {
        let w = Self.strip(whereText, "WHERE"), f = try filterSQL(without: without)
        return !w.isEmpty && !f.isEmpty ? "(\(w)) AND (\(f))" : w.isEmpty ? f : w
    }
    var safeWhere: String { (try? effectiveWhere()) ?? Self.strip(whereText, "WHERE") }

    func filter(on column: String) -> FilterCond? { filters.conds?.first { $0.col == column } }

    var defaultOrder: String {
        let w = safeWhere
        if w.isEmpty, let pk = info?.primaryKey, pk.count == 1 { return connection.dialect.column(pk[0]) + " DESC" }
        return ""
    }

    var effectiveOrder: String {
        let o = Self.strip(orderText, "ORDER BY")
        return o.isEmpty ? defaultOrder : o
    }

    var fromClause: String {
        guard let t = tableName else { return "" }
        return info?.quoted ?? connection.dialect.ident(t)
    }

    func buildSQL(extra: Int = 0) -> String {
        guard tableName != nil else { return sql }
        var s = "SELECT * FROM \(fromClause)"
        let w = safeWhere
        if !w.isEmpty { s += " WHERE \(w)" }
        let o = effectiveOrder
        if !o.isEmpty { s += " ORDER BY \(o)" }
        s += " LIMIT \(limit + extra)"
        if offset > 0 { s += " OFFSET \(offset)" }
        return s
    }

    func countSQL() -> String {
        var s = "SELECT COUNT(*) FROM \(fromClause)"
        let w = safeWhere
        if !w.isEmpty { s += " WHERE \(w)" }
        return s
    }

    var explainPrefix: String { connection.dialect == .sqlite ? "EXPLAIN QUERY PLAN " : "EXPLAIN " }
}
