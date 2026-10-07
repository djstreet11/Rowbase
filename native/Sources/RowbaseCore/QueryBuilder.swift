import Foundation

/// Column filters and the visual query builder → SQL. Port of rowbase/query.py; both suites read tests/query_vectors.json.
public struct FilterCond: Codable, Sendable, Equatable {
    public var col: String?
    public var src: String?
    public var op: String?
    public var value: String?
    public var value2: String?
    public var values: [String?]?
    /// Present when this item is a nested group.
    public var match: String?
    public var conds: [FilterCond]?

    public init(col: String? = nil, src: String? = nil, op: String? = nil, value: String? = nil, value2: String? = nil,
                values: [String?]? = nil, match: String? = nil, conds: [FilterCond]? = nil) {
        (self.col, self.src, self.op, self.value, self.value2, self.values, self.match, self.conds) = (col, src, op, value, value2, values, match, conds)
    }
}

public struct FilterGroup: Codable, Sendable, Equatable {
    public var match: String?
    public var conds: [FilterCond]?
    public init(match: String? = "all", conds: [FilterCond]? = []) { (self.match, self.conds) = (match, conds) }
}

public struct QueryColumn: Codable, Sendable, Equatable {
    public var src: String?
    public var col: String?
    public var agg: String?
    public var `as`: String?
    public var dir: String?
    public init(src: String? = nil, col: String? = nil, agg: String? = nil, as alias: String? = nil, dir: String? = nil) {
        (self.src, self.col, self.agg, self.as, self.dir) = (src, col, agg, alias, dir)
    }
}

public struct QuerySource: Codable, Sendable, Equatable {
    public struct Pair: Codable, Sendable, Equatable {
        public var left: QueryColumn
        public var right: QueryColumn
        public init(left: QueryColumn, right: QueryColumn) { (self.left, self.right) = (left, right) }
    }
    public var table: String?
    public var `as`: String?
    public var type: String?
    public var on: [Pair]?
    public init(table: String? = nil, as alias: String? = nil, type: String? = nil, on: [Pair]? = nil) {
        (self.table, self.as, self.type, self.on) = (table, alias, type, on)
    }
}

public struct QuerySpec: Codable, Sendable, Equatable {
    public var from: QuerySource?
    public var joins: [QuerySource]?
    public var columns: [QueryColumn]?
    public var distinct: Bool?
    public var `where`: FilterGroup?
    public var orderBy: [QueryColumn]?
    public var limit: Int?
    public init(from: QuerySource? = nil, joins: [QuerySource]? = nil, columns: [QueryColumn]? = nil, distinct: Bool? = nil,
                where w: FilterGroup? = nil, orderBy: [QueryColumn]? = nil, limit: Int? = nil) {
        (self.from, self.joins, self.columns, self.distinct, self.where, self.orderBy, self.limit) = (from, joins, columns, distinct, w, orderBy, limit)
    }
}

public enum QueryBuilder {
    /// op -> (label, arity): 0 none, 1 value, 2 value + value2, -1 values list
    public static let ops: [(key: String, label: String, arity: Int)] = [
        ("in", "is one of", -1), ("not_in", "is not one of", -1),
        ("eq", "=", 1), ("ne", "≠", 1), ("gt", ">", 1), ("ge", "≥", 1), ("lt", "<", 1), ("le", "≤", 1), ("between", "between", 2),
        ("contains", "contains", 1), ("not_contains", "doesn't contain", 1), ("starts", "starts with", 1), ("ends", "ends with", 1),
        ("like", "LIKE pattern", 1), ("not_like", "NOT LIKE pattern", 1), ("regex", "matches regex", 1),
        ("null", "is NULL", 0), ("not_null", "is not NULL", 0), ("empty", "is empty", 0), ("not_empty", "is not empty", 0),
    ]
    public static func arity(_ op: String) -> Int { ops.first { $0.key == op }?.arity ?? 1 }
    static let aggs = ["count": "COUNT(%@)", "count_distinct": "COUNT(DISTINCT %@)", "sum": "SUM(%@)", "avg": "AVG(%@)", "min": "MIN(%@)", "max": "MAX(%@)"]
    static let joinKinds = ["inner": "INNER JOIN", "left": "LEFT JOIN", "right": "RIGHT JOIN"]
    static let reserved: Set<String> = Set(("ALL AND ANY AS ASC BETWEEN BY CASE CROSS DESC DISTINCT DO ELSE END EXISTS FOR FROM FULL GROUP HAVING IF IN INNER INTO "
        + "IS JOIN KEY LEFT LIKE LIMIT NATURAL NOT NULL OFFSET ON OR ORDER OUTER RIGHT SELECT SET TABLE THEN TO UNION USING "
        + "VALUES WHEN WHERE WITH").split(separator: " ").map(String.init))

    static func matches(_ pattern: String, _ s: String, options: NSRegularExpression.Options = []) -> Bool {
        let re = try! NSRegularExpression(pattern: pattern, options: options)
        return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
    static func full(_ pattern: String, _ s: String) -> Bool { matches("^(?:" + pattern + ")$", s) }
    static func isNumericType(_ t: String) -> Bool {
        matches(#"^(?:(?:tiny|small|medium|big)?int|integer|dec|decimal|numeric|real|double|float|serial|bigserial|smallserial)\b"#, t, options: .caseInsensitive)
    }

    public static func alias(_ d: Dialect, _ name: String) -> String {
        full("[a-z_][a-z0-9_]{0,62}", name) && !reserved.contains(name.uppercased()) ? name : d.column(name)
    }

    public static func literal(_ d: Dialect, _ v: String?, type: String = "") -> String {
        guard let v else { return "NULL" }
        let uuid = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        if d == .mysql && type.lowercased() == "binary(16)" && full(uuid, v) {
            return "UNHEX('\(v.replacingOccurrences(of: "-", with: "").uppercased())')"
        }
        if matches("binary|blob|bytea", type, options: .caseInsensitive) && full("0x[0-9a-fA-F]+", v) {
            let h = String(v.dropFirst(2))
            return d == .postgres ? "'\\x\(h.lowercased())'::bytea" : "X'\(h.uppercased())'"
        }
        if full(#"-?\d+(?:\.\d+)?"#, v) && (isNumericType(type) || (d == .sqlite && type.isEmpty)) { return v }
        return d.literal(v)
    }

    static func likeEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "!", with: "!!").replacingOccurrences(of: "%", with: "!%").replacingOccurrences(of: "_", with: "!_")
    }

    /// One condition on an already-quoted column reference; nil when incomplete.
    public static func condSQL(_ d: Dialect, _ c: FilterCond, ref: String, type: String = "") throws -> String? {
        let op = c.op ?? "eq"
        guard ops.contains(where: { $0.key == op }) else { throw RowbaseError("Unknown filter operator '\(op)'") }
        let lit = { (x: String?) in literal(d, x, type: type) }
        let pg = d == .postgres
        let text = pg && !matches("char|text|^name$", type, options: .caseInsensitive) ? "CAST(\(ref) AS TEXT)" : ref
        let like = pg ? "ILIKE" : "LIKE"
        let withNulls = { (s: String) in "(\(s) OR \(ref) IS NULL)" }
        switch op {
        case "null", "not_null": return "\(ref) IS \(op == "not_null" ? "NOT " : "")NULL"
        case "empty": return "\(text) = ''"
        case "not_empty": return "\(text) <> ''"
        case "in", "not_in":
            let vals = c.values ?? []
            let nn = vals.compactMap { $0 }
            let hasNull = nn.count < vals.count
            if vals.isEmpty { return nil }
            let list = nn.count == 1 ? " = \(lit(nn[0]))" : " IN (\(nn.map(lit).joined(separator: ", ")))"
            if op == "in" {
                let parts = (nn.isEmpty ? [] : [ref + list]) + (hasNull ? ["\(ref) IS NULL"] : [])
                return parts.count == 1 ? parts[0] : "(\(parts[0]) OR \(parts[1]))"
            }
            if nn.isEmpty { return "\(ref) IS NOT NULL" }
            let neg = nn.count == 1 ? "\(ref) <> \(lit(nn[0]))" : "\(ref) NOT IN (\(nn.map(lit).joined(separator: ", ")))"
            return hasNull ? neg : withNulls(neg)
        case "between":
            let a = c.value ?? "", b = c.value2 ?? ""
            if a.isEmpty && b.isEmpty { return nil }
            if b.isEmpty { return "\(ref) >= \(lit(a))" }
            if a.isEmpty { return "\(ref) <= \(lit(b))" }
            return "\(ref) BETWEEN \(lit(a)) AND \(lit(b))"
        default: break
        }
        guard let v = c.value else {
            return op == "eq" || op == "ne" ? "\(ref) IS \(op == "ne" ? "NOT " : "")NULL" : nil
        }
        let cmp = ["eq": "=", "ne": "<>", "gt": ">", "ge": ">=", "lt": "<", "le": "<="]
        if let sym = cmp[op] {
            let s = "\(ref) \(sym) \(lit(v))"
            return op == "ne" ? withNulls(s) : s
        }
        if v.isEmpty { return nil }
        switch op {
        case "contains", "not_contains", "starts", "ends":
            let e = likeEscape(v)
            let pat = op == "starts" ? "\(e)%" : op == "ends" ? "%\(e)" : "%\(e)%"
            let s = "\(text) \(op == "not_contains" ? "NOT " : "")\(like) \(d.literal(pat)) ESCAPE '!'"
            return op == "not_contains" ? withNulls(s) : s
        case "like", "not_like":
            let s = "\(text) \(op == "not_like" ? "NOT " : "")\(like) \(d.literal(v))"
            return op == "not_like" ? withNulls(s) : s
        default:  // regex
            if d == .sqlite { throw RowbaseError("Regular expressions are not available on SQLite — use contains / LIKE") }
            return pg ? "\(text) ~* \(d.literal(v))" : "\(ref) REGEXP \(d.literal(v))"
        }
    }

    static func isAny(_ match: String?) -> Bool { match == "any" }

    public static func whereSQL(_ d: Dialect, _ group: FilterGroup?, ref: (FilterCond) throws -> String, type: (FilterCond) -> String) throws -> String {
        try parts(d, group?.conds, group?.match, ref: ref, type: type).joined(separator: isAny(group?.match) ? " OR " : " AND ")
    }

    static func parts(_ d: Dialect, _ conds: [FilterCond]?, _ match: String?, ref: (FilterCond) throws -> String, type: (FilterCond) -> String) throws -> [String] {
        var out: [String] = []
        for c in conds ?? [] {
            var s: String?
            if let sub = c.conds {
                let p = try parts(d, sub, c.match, ref: ref, type: type)
                let joined = p.joined(separator: isAny(c.match) ? " OR " : " AND ")
                s = p.count > 1 && isAny(c.match) != isAny(match) ? "(\(joined))" : joined
            } else if let col = c.col, !col.isEmpty {
                s = try condSQL(d, c, ref: ref(c), type: type(c))
            }
            if let s, !s.isEmpty { out.append(s) }
        }
        return out
    }

    /// Column filters of one table: unqualified columns; types = [column: declared type].
    public static func filterWhere(_ d: Dialect, _ group: FilterGroup?, types: [String: String] = [:]) throws -> String {
        try whereSQL(d, group, ref: { d.column($0.col ?? "") }, type: { types[$0.col ?? ""] ?? "" })
    }

    /// types: [source key (alias or table): [column: declared type]]
    public static func selectSQL(_ d: Dialect, _ spec: QuerySpec, types: [String: [String: String]] = [:]) throws -> String {
        guard let from = spec.from, let table = from.table, !table.isEmpty else { throw RowbaseError("Choose a table") }
        func nz(_ s: String?) -> String? { s?.isEmpty == false ? s : nil }
        var src = from
        src.as = nz(src.as)
        let joins = (spec.joins ?? []).filter { !($0.table ?? "").isEmpty }.map { j -> QuerySource in var j = j; j.as = nz(j.as); return j }
        var keys: [String: QuerySource] = [:]
        for s in [src] + joins { keys[s.as ?? s.table!] = s }
        let qualify = !joins.isEmpty
        let def = src.as ?? table
        func key(_ src: String?) -> String { nz(src) ?? def }
        func ref(_ src: String?, _ col: String) throws -> String {
            let c = col == "*" ? "*" : d.column(col)
            if !qualify { return c }
            guard let s = keys[key(src)] else { throw RowbaseError("Unknown table '\(key(src))' in column \(col)") }
            return "\(s.as.map { alias(d, $0) } ?? d.ident(s.table!)).\(c)"
        }
        func expr(_ c: QueryColumn) throws -> String {
            let col = c.col ?? ""
            if let a = c.agg, !a.isEmpty {
                guard let f = aggs[a] else { throw RowbaseError("Unknown aggregate '\(a)'") }
                if col == "*" {
                    if a != "count" { throw RowbaseError("\(a.uppercased()) needs a column, not *") }
                    return "COUNT(*)"
                }
                let r = try ref(c.src, col)
                return f.replacingOccurrences(of: "%@", with: r)
            }
            return try ref(c.src, col)
        }
        func type(_ c: FilterCond) -> String {
            let k = key(c.src)
            return (types[k] ?? keys[k].flatMap { types[$0.table!] } ?? [:])[c.col ?? ""] ?? ""
        }
        func source(_ s: QuerySource) -> String { d.ident(s.table!) + (s.as.map { " AS \(alias(d, $0))" } ?? "") }

        let cols = (spec.columns ?? []).filter { !($0.col ?? "").isEmpty }
        let list = try cols.map { c -> String in
            let name = nz(c.as)
            return try expr(c) + (name.map { n in " AS \(alias(d, n))" } ?? "")
        }
        var out = ["SELECT " + (spec.distinct == true ? "DISTINCT " : "") + (list.isEmpty ? "*" : list.joined(separator: ", ")), "FROM " + source(src)]
        for j in joins {
            var on: [String] = []
            for p in j.on ?? [] where !(p.left.col ?? "").isEmpty && !(p.right.col ?? "").isEmpty {
                let l = try ref(p.left.src, p.left.col!), r = try ref(p.right.src, p.right.col!)
                on.append("\(l) = \(r)")
            }
            if on.isEmpty { throw RowbaseError("Join with \(j.table!) needs at least one column pair") }
            out.append("\(joinKinds[j.type ?? "inner"] ?? "INNER JOIN") \(source(j)) ON \(on.joined(separator: " AND "))")
        }
        let w = try whereSQL(d, spec.where, ref: { try ref($0.src, $0.col ?? "") }, type: type)
        if !w.isEmpty { out.append("WHERE " + w) }
        if cols.contains(where: { !($0.agg ?? "").isEmpty }) {
            let g = try cols.filter { ($0.agg ?? "").isEmpty }.map { try ref($0.src, $0.col!) }
            if !g.isEmpty { out.append("GROUP BY " + g.joined(separator: ", ")) }
        }
        let order = (spec.orderBy ?? []).filter { !($0.col ?? "").isEmpty }
        if !order.isEmpty {
            let items = try order.map { try expr($0) + (($0.dir ?? "").lowercased() == "desc" ? " DESC" : "") }
            out.append("ORDER BY " + items.joined(separator: ", "))
        }
        if let l = spec.limit, l > 0 { out.append("LIMIT \(l)") }
        return out.joined(separator: "\n")
    }

    /// Distinct values of a column with their counts (column filter popover), most frequent first.
    public static func valuesSQL(_ d: Dialect, table: String, column: String, where w: String = "", search: String = "", type: String = "", limit: Int = 200) throws -> String {
        let ref = d.column(column)
        var conds = w.isEmpty ? [] : ["(\(w))"]
        if !search.isEmpty, let s = try condSQL(d, FilterCond(op: "contains", value: search), ref: ref, type: type) { conds.append(s) }
        return "SELECT \(ref), COUNT(*) FROM \(d.ident(table))" + (conds.isEmpty ? "" : " WHERE " + conds.joined(separator: " AND "))
            + " GROUP BY \(ref) ORDER BY 2 DESC, 1 LIMIT \(limit)"
    }
}
