import Foundation
import RowbaseCore

/// Column of one builder source. `src` is the source's stable id (aliases can change when joins come and go).
struct QBRef: Codable, Hashable {
    var src: String
    var col: String
}

struct QBPair: Codable, Hashable, Identifiable {
    var id = UUID()
    var left: QBRef     // column of the joined table
    var right: QBRef    // column of a table above it
}

struct QBSource: Codable, Hashable, Identifiable {
    var id: String
    var table = ""
    var alias = ""
    var type = "left"
    var on: [QBPair] = []
}

struct QBColumn: Codable, Hashable, Identifiable {
    var id = UUID()
    var ref: QBRef
    var agg = ""
    var name = ""
}

struct QBCond: Codable, Equatable, Identifiable {
    var id = UUID()
    var ref: QBRef
    var cond = FilterCond(op: "eq", value: "")
}

struct QBOrder: Codable, Hashable, Identifiable {
    var id = UUID()
    var ref: QBRef
    var agg = ""
    var desc = false
}

/// Visual query builder state (UI side of the shared QuerySpec contract, see rowbase/static/app.js specOut).
struct QBModel: Codable, Equatable {
    var from = QBSource(id: "s0")
    var joins: [QBSource] = []
    var columns: [QBColumn] = []
    var distinct = false
    var match = "all"
    var conds: [QBCond] = []
    var order: [QBOrder] = []
    var limit: Int? = 100

    static let aggs: [(key: String, label: String)] = [("", "value"), ("count", "count"), ("count_distinct", "count distinct"),
                                                        ("sum", "sum"), ("avg", "average"), ("min", "min"), ("max", "max")]
    static let joinTypes: [(key: String, label: String)] = [("inner", "only rows that match"), ("left", "all rows of the tables above"),
                                                             ("right", "all rows of this table")]

    var sources: [QBSource] { ([from] + joins).filter { !$0.table.isEmpty } }
    var multi: Bool { sources.count > 1 }
    func source(_ id: String) -> QBSource? { sources.first { $0.id == id } }
    var firstID: String { from.id }

    /// Short alias from the table name's first letter (o, o2, …), unique among the other sources.
    func nextAlias(for table: String, excluding id: String? = nil) -> String {
        let name = table.split(separator: ".").last.map(String.init) ?? table
        let base = name.first(where: \.isLetter).map { String($0).lowercased() } ?? "t"
        let used = Set(([from] + joins).filter { $0.id != id }.map(\.alias))
        var i = 1
        while used.contains(i == 1 ? base : "\(base)\(i)") { i += 1 }
        return i == 1 ? base : "\(base)\(i)"
    }

    /// Display name of a column: alias-qualified when there are joins.
    func label(_ r: QBRef) -> String {
        if r.col == "*" { return "all rows (*)" }
        guard multi, let s = source(r.src) else { return r.col }
        return "\(s.alias.isEmpty ? s.table : s.alias).\(r.col)"
    }

    func columnLabel(_ c: QBColumn) -> String {
        if !c.name.isEmpty { return c.name }
        return c.agg.isEmpty ? label(c.ref) : "\(Self.aggs.first { $0.key == c.agg }?.label ?? c.agg)(\(label(c.ref)))"
    }

    func joinRemoved(_ id: String) -> QBModel {
        var q = self
        q.joins.removeAll { $0.id == id }
        q.columns.removeAll { $0.ref.src == id }
        q.conds.removeAll { $0.ref.src == id }
        q.order.removeAll { $0.ref.src == id }
        for i in q.joins.indices { q.joins[i].on.removeAll { $0.right.src == id } }
        if q.joins.isEmpty { q.from.alias = "" }
        return q
    }

    /// UI state → shared spec: source ids become aliases (only when there are joins).
    var spec: QuerySpec {
        let multi = multi
        let srcs = sources
        func key(_ id: String) -> String? {
            guard multi else { return nil }
            let s = srcs.first { $0.id == id } ?? srcs.first
            return s.map { $0.alias.isEmpty ? $0.table : $0.alias }
        }
        func src(_ s: QBSource, join: Bool) -> QuerySource {
            QuerySource(table: s.table, as: multi && !s.alias.isEmpty ? s.alias : nil, type: join ? s.type : nil,
                        on: join ? s.on.map { QuerySource.Pair(left: QueryColumn(src: key($0.left.src), col: $0.left.col),
                                                    right: QueryColumn(src: key($0.right.src), col: $0.right.col)) } : nil)
        }
        let conds = self.conds.filter { !$0.ref.col.isEmpty }.map { c -> FilterCond in
            var f = c.cond
            f.col = c.ref.col
            f.src = key(c.ref.src)
            return f
        }
        return QuerySpec(
            from: from.table.isEmpty ? nil : src(from, join: false),
            joins: joins.filter { !$0.table.isEmpty }.map { src($0, join: true) },
            columns: columns.filter { !$0.ref.col.isEmpty }.map {
                QueryColumn(src: key($0.ref.src), col: $0.ref.col, agg: $0.agg.isEmpty ? nil : $0.agg, as: $0.name.isEmpty ? nil : $0.name)
            },
            distinct: distinct, where: FilterGroup(match: match, conds: conds),
            orderBy: order.filter { !$0.ref.col.isEmpty }.map {
                QueryColumn(src: key($0.ref.src), col: $0.ref.col, agg: $0.agg.isEmpty ? nil : $0.agg, dir: $0.desc ? "desc" : "asc")
            },
            limit: limit)
    }

    /// Declared column types per source key (alias or table) — picks the literal style of condition values.
    func types(_ infos: [String: TableInfo]) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        for s in sources {
            guard let i = infos[s.table] else { continue }
            out[multi && !s.alias.isEmpty ? s.alias : s.table] = Dictionary(i.columns.map { ($0.name, $0.type) }, uniquingKeysWith: { a, _ in a })
        }
        return out
    }
}

/// Operator groups of the filter / condition pickers (same as the web UI).
enum FilterOps {
    static let groups: [(title: String, ops: [String])] = [
        ("Values", ["in", "not_in"]),
        ("Compare", ["eq", "ne", "gt", "ge", "lt", "le", "between"]),
        ("Text", ["contains", "not_contains", "starts", "ends", "like", "not_like", "regex"]),
        ("Empty", ["null", "not_null", "empty", "not_empty"]),
    ]
    static func label(_ op: String) -> String { QueryBuilder.ops.first { $0.key == op }?.label ?? op }
    static let hints: [String: String] = [
        "contains": "case-insensitive, no wildcards needed", "not_contains": "NULL rows are kept", "ne": "NULL rows are kept",
        "not_in": "NULL rows are kept unless NULL is selected", "like": "% = any text, _ = one character",
        "not_like": "% = any text, _ = one character", "regex": "e.g. ^ab.*z$ (not available on SQLite)",
        "between": "inclusive; leave one side empty for ≥ / ≤", "empty": "empty string ''",
    ]

    static func short(_ v: String?) -> String {
        guard let v else { return "NULL" }
        if v.isEmpty { return "''" }
        return v.count > 24 ? String(v.prefix(22)) + "…" : v
    }

    /// Chip text: "status ∈ new, paid", "total ≥ 10 and ≤ 20", "note contains x".
    static func text(_ c: FilterCond) -> String {
        let col = c.col ?? "", op = c.op ?? "eq"
        switch QueryBuilder.arity(op) {
        case 0: return "\(col) \(label(op))"
        case -1:
            let vs = c.values ?? []
            let shown = vs.prefix(3).map(short).joined(separator: ", ") + (vs.count > 3 ? " +\(vs.count - 3)" : "")
            return "\(col) \(op == "in" ? "∈" : "∉") \(shown)"
        case 2:
            let a = c.value ?? "", b = c.value2 ?? ""
            return "\(col) " + [a.isEmpty ? nil : "≥ \(short(a))", b.isEmpty ? nil : "≤ \(short(b))"].compactMap { $0 }.joined(separator: " and ")
        default: return "\(col) \(label(op)) \(short(c.value))"
        }
    }
}
