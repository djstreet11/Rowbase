import Foundation

/// A table whose single-column primary key can hold a UUID — a possible target of an implicit reference.
public struct RefTable: Sendable, Hashable {
    public var name, pk, pkType: String
    public var labels: [String]
}

public struct RefMatch: Sendable, Hashable {
    public var table, label: String
}

/// Implicit references: UUID values in columns without FK constraints (1C-style schemas and similar). The pure
/// heuristics are pinned by tests/ref_vectors.json, shared with rowbase/refs.py.
public enum Refs {
    /// 1C "empty reference" — shown dimmed, never a link.
    public static let emptyUUID = "00000000-0000-0000-0000-000000000000"
    static let stop: Set<String> = ["ref", "tref", "id", "uuid", "guid", "key", "fk", "type"]
    static let labelOrder = ["description", "name", "title", "label", "number", "code"]

    /// Dashed 8-4-4-4-12 hex, not the all-zero "empty reference". Byte loop: runs for every visible grid cell.
    public static func isUUID(_ v: String) -> Bool {
        var n = 0, zero = true
        for b in v.utf8 {
            if n == 8 || n == 13 || n == 18 || n == 23 {
                guard b == 45 else { return false }
            } else {
                switch b {
                case 48...57, 65...70, 97...102: if b != 48 { zero = false }
                default: return false
                }
            }
            n += 1
            if n > 36 { return false }
        }
        return n == 36 && !zero
    }

    /// Lower-cased words of an identifier: snake_case and camelCase ("HTTPRequestID" → http, request, id).
    public static func words(_ s: String) -> [String] {
        var out: [String] = [], cur = ""
        let cs = Array(s)
        for (i, ch) in cs.enumerated() {
            if !(ch.isLetter || ch.isNumber) { if !cur.isEmpty { out.append(cur); cur = "" }; continue }
            if ch.isUppercase, !cur.isEmpty {
                let prev = cs[i - 1], next = i + 1 < cs.count ? cs[i + 1] : nil
                if prev.isLowercase || prev.isNumber || (prev.isUppercase && next?.isLowercase == true) { out.append(cur); cur = "" }
            }
            cur.append(ch)
        }
        if !cur.isEmpty { out.append(cur) }
        return out.map { $0.lowercased() }
    }

    static func norm(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter || $0.isNumber }) }

    /// Sibling column naming the target type of a polymorphic reference (`Owner_Ref` → `Owner_TRef`, `parent_id` → `parent_type`).
    public static func hintColumn(for column: String, in columns: [String]) -> String? {
        var base = column
        for suf in ["_Ref", "_ref", "_REF", "_id", "_Id", "_ID", "_uuid"] where base.hasSuffix(suf) { base = String(base.dropLast(suf.count)); break }
        let lower = Dictionary(columns.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        for s in ["_TRef", "_Type", "TRef", "Type"] { if let c = lower[(base + s).lowercased()], c != column { return c } }
        return nil
    }

    /// Likely target tables, best first. Empty: no idea (caller scans every RefTable).
    public static func candidates(column: String, hint: String?, tables: [String]) -> [String] {
        if let hint, !hint.isEmpty {
            let h = norm(hint)
            if let t = tables.first(where: { norm($0) == h }) { return [t] }
        }
        let w = words(column).filter { !stop.contains($0) }
        guard !w.isEmpty else { return [] }
        let normed = tables.map { norm($0) }
        for len in stride(from: w.count, through: 1, by: -1) {
            for start in stride(from: w.count - len, through: 0, by: -1) {
                let p = w[start..<start + len].joined()
                guard p.count >= 3 else { continue }
                var forms = [p, p + "s", p + "es"]
                if p.hasSuffix("y") { forms.append(p.dropLast() + "ies") }
                let hits = tables.indices.filter { i in forms.contains { normed[i].hasSuffix($0) } }.map { tables[$0] }
                if !hits.isEmpty { return hits }
            }
        }
        return []
    }

    /// PK types that can store a UUID.
    static func uuidCapable(_ type: String, _ d: Dialect) -> Bool {
        let t = type.lowercased()
        if t.contains("uuid") || t.contains("(36)") || t == "binary(16)" { return true }
        return d == .sqlite && (t.isEmpty || t.contains("text") || t.contains("char"))
    }

    /// One row per table: name, pk column(s), pk count, pk type, label columns (comma separated).
    public static func catalogSQL(_ d: Dialect) -> String {
        let labels = labelOrder.map { "'\($0)'" }.joined(separator: ", ")
        switch d {
        case .mysql:
            return "SELECT TABLE_NAME, GROUP_CONCAT(CASE WHEN COLUMN_KEY = 'PRI' THEN COLUMN_NAME END), SUM(COLUMN_KEY = 'PRI'), "
                + "MAX(CASE WHEN COLUMN_KEY = 'PRI' THEN COLUMN_TYPE END), "
                + "GROUP_CONCAT(CASE WHEN LOWER(COLUMN_NAME) IN (\(labels)) THEN COLUMN_NAME END) "
                + "FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() GROUP BY TABLE_NAME"
        case .postgres:
            return "SELECT \(String(format: Catalog.pgName, "n", "c")), MAX(a.attname), COUNT(*), MAX(format_type(a.atttypid, a.atttypmod)), "
                + "(SELECT string_agg(l.attname, ',') FROM pg_attribute l WHERE l.attrelid = c.oid AND l.attnum > 0 AND NOT l.attisdropped "
                + "AND lower(l.attname) IN (\(labels))) "
                + "FROM pg_index i JOIN pg_class c ON c.oid = i.indrelid JOIN pg_namespace n ON n.oid = c.relnamespace "
                + "JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY (i.indkey) "
                + "WHERE i.indisprimary AND n.nspname NOT IN ('pg_catalog', 'information_schema') GROUP BY 1, c.oid"
        case .sqlite:
            return "SELECT m.name, (SELECT group_concat(name) FROM pragma_table_info(m.name) WHERE pk > 0), "
                + "(SELECT count(*) FROM pragma_table_info(m.name) WHERE pk > 0), (SELECT type FROM pragma_table_info(m.name) WHERE pk = 1), "
                + "(SELECT group_concat(name) FROM pragma_table_info(m.name) WHERE lower(name) IN (\(labels))) "
                + "FROM sqlite_master m WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite\\_%' ESCAPE '\\'"
        }
    }

    public static func parseCatalog(_ rows: [[String?]], _ d: Dialect) -> [RefTable] {
        rows.compactMap { r in
            guard r.count >= 5, let name = r[0], let pk = r[1], r[2] == "1", uuidCapable(r[3] ?? "", d) else { return nil }
            let have = (r[4] ?? "").split(separator: ",").map(String.init)
            let labels = labelOrder.compactMap { l in have.first { $0.lowercased() == l } }
            return RefTable(name: name, pk: pk, pkType: r[3] ?? "", labels: labels)
        }.sorted { $0.name < $1.name }
    }

    /// `SELECT 'table', label` for every table holding `value` as its primary key.
    public static func lookupSQL(_ d: Dialect, tables: [RefTable], value: String) -> String {
        let v = value.lowercased()
        return tables.map { t in
            let label = t.labels.isEmpty ? "''"
                : "COALESCE(" + t.labels.map { "NULLIF(CAST(\(d.column($0)) AS \(d == .mysql ? "CHAR" : "TEXT")), '')" }.joined(separator: ", ") + ", '')"
            let key = d == .mysql && t.pkType.lowercased() == "binary(16)"
                ? "UNHEX('\(v.replacingOccurrences(of: "-", with: ""))')" : d.literal(v)
            return "SELECT \(d.literal(t.name)) AS t, \(label) AS label FROM \(d.ident(t.name)) WHERE \(d.column(t.pk)) = \(key)"
        }.joined(separator: " UNION ALL ")
    }
}

extension Engine {
    /// Tables with a single UUID-capable primary key in the connection's current database.
    public func refTables(_ c: Connection) async throws -> [RefTable] {
        Refs.parseCatalog(try await execute(c, Refs.catalogSQL(c.dialect), limit: 100_000, timeout: 60, trusted: true).rows, c.dialect)
    }

    /// Find `value` as a primary key: candidate tables first, then (if `scanAll`) every ref table, 40 per query.
    public func resolveRef(_ c: Connection, value: String, candidates: [RefTable], all: [RefTable]) async throws -> [RefMatch] {
        guard Refs.isUUID(value) else { throw RowbaseError("Not a UUID") }
        let rest = all.filter { !candidates.contains($0) }
        for group in [candidates, rest] {
            var found: [RefMatch] = []
            for start in stride(from: 0, to: group.count, by: 40) {
                let chunk = Array(group[start..<min(start + 40, group.count)])
                let rows = try await execute(c, Refs.lookupSQL(c.dialect, tables: chunk, value: value), limit: 50, timeout: 30, trusted: true).rows
                found += rows.map { RefMatch(table: $0[0] ?? "", label: $0.count > 1 ? $0[1] ?? "" : "") }
            }
            if !found.isEmpty { return found }
        }
        return []
    }
}
