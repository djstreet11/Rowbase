import SwiftUI
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
    enum Kind: Equatable { case table(String), query }

    let id = UUID()
    let kind: Kind
    var connection: Connection
    var whereText = ""
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
    @ObservationIgnored var selection = NSRange(location: 0, length: 0)
    @ObservationIgnored var token = 0
    @ObservationIgnored weak var editor: SQLTextView?

    init(kind: Kind, connection: Connection) {
        self.kind = kind
        self.connection = connection
        if kind == .query { limit = 500 }
    }

    var tableName: String? { if case .table(let t) = kind { t } else { nil } }
    var isQuery: Bool { kind == .query }

    var title: String {
        switch kind {
        case .table(let t):
            let w = Self.strip(whereText, "WHERE")
            return w.isEmpty ? t : "\(t) · \(w)"
        case .query: return "SQL"
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

    var defaultOrder: String {
        let w = Self.strip(whereText, "WHERE")
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
        let w = Self.strip(whereText, "WHERE")
        if !w.isEmpty { s += " WHERE \(w)" }
        let o = effectiveOrder
        if !o.isEmpty { s += " ORDER BY \(o)" }
        s += " LIMIT \(limit + extra)"
        if offset > 0 { s += " OFFSET \(offset)" }
        return s
    }

    func countSQL() -> String {
        var s = "SELECT COUNT(*) FROM \(fromClause)"
        let w = Self.strip(whereText, "WHERE")
        if !w.isEmpty { s += " WHERE \(w)" }
        return s
    }

    var explainPrefix: String { connection.dialect == .sqlite ? "EXPLAIN QUERY PLAN " : "EXPLAIN " }
}
