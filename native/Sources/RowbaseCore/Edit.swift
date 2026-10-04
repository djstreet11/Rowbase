import Foundation

/// One column assignment; value nil = NULL. Values are sent as quoted literals (engines coerce '42'/'true').
public struct ColumnValue: Sendable, Hashable {
    public var column: String
    public var value: String?
    public init(_ column: String, _ value: String?) { (self.column, self.value) = (column, value) }
}

/// Row edit — same contract as rowbase/edit.py (SPEC §5). `key` must be exactly the table's primary key.
public enum RowChange: Sendable, Hashable {
    case update(key: [ColumnValue], set: [ColumnValue])
    case insert([ColumnValue])
    case delete(key: [ColumnValue])
}

public struct EditResult: Sendable {
    public var statements: [String]
    public var affected: [Int]
}

public enum RowEditor {
    static let binary = try! NSRegularExpression(pattern: "binary|blob|bytea", options: .caseInsensitive)

    enum Op { case update, insert, delete }

    /// Validate and generate SQL (no database access).
    static func build(_ d: Dialect, _ info: TableInfo, _ changes: [RowChange]) throws -> [(Op, String, String?)] {
        let cols = Dictionary(info.columns.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let pk = info.primaryKey
        func val(_ v: String?) -> String { v.map(d.literal) ?? "NULL" }
        func check(_ list: [ColumnValue], _ what: String) throws {
            for cv in list {
                guard let c = cols[cv.column] else { throw RowbaseError("Unknown column '\(cv.column)' in \(what).") }
                if binary.firstMatch(in: c.type, range: NSRange(c.type.startIndex..., in: c.type)) != nil {
                    throw RowbaseError("Column '\(c.name)' (\(c.type)) is binary and can't be edited here.")
                }
            }
        }
        func whereClause(_ key: [ColumnValue]) throws -> String {
            guard !pk.isEmpty else { throw RowbaseError("Table \(info.name) has no primary key — rows can't be identified safely.") }
            guard key.map(\.column).sorted() == pk.sorted(), key.allSatisfy({ $0.value != nil }) else {
                throw RowbaseError("Row key must be the primary key (\(pk.joined(separator: ", "))) with non-NULL values.")
            }
            let byName = Dictionary(key.map { ($0.column, $0.value) }, uniquingKeysWith: { a, _ in a })
            return pk.map { "\(d.column($0)) = \(val(byName[$0] ?? nil))" }.joined(separator: " AND ")
        }
        var out: [(Op, String, String?)] = []
        for (i, ch) in changes.enumerated() {
            switch ch {
            case .update(let key, let set):
                guard !set.isEmpty else { continue }
                try check(set, "change #\(i + 1)")
                let w = try whereClause(key)
                out.append((.update, "UPDATE \(info.quoted) SET " + set.map { "\(d.column($0.column)) = \(val($0.value))" }.joined(separator: ", ")
                            + " WHERE \(w)", "SELECT COUNT(*) FROM \(info.quoted) WHERE \(w)"))
            case .delete(let key):
                out.append((.delete, "DELETE FROM \(info.quoted) WHERE \(try whereClause(key))", nil))
            case .insert(let values):
                try check(values, "change #\(i + 1)")
                let sql = values.isEmpty
                    ? (d == .mysql ? "INSERT INTO \(info.quoted) () VALUES ()" : "INSERT INTO \(info.quoted) DEFAULT VALUES")
                    : "INSERT INTO \(info.quoted) (" + values.map { d.column($0.column) }.joined(separator: ", ") + ") VALUES ("
                        + values.map { val($0.value) }.joined(separator: ", ") + ")"
                out.append((.insert, sql, nil))
            }
        }
        return out
    }
}

extension Engine {
    /// Apply row changes atomically on a write-enabled connection. Every UPDATE/DELETE must hit exactly one row,
    /// otherwise everything is rolled back. `dryRun` only returns the SQL.
    public func apply(_ c: Connection, table: String, changes: [RowChange], dryRun: Bool = false, timeout: Int = 30) async throws -> EditResult {
        guard !c.readOnly else { throw RowbaseError("Read-only connection: enable writes in the connection settings to edit data.") }
        let info = try await tableInfo(c, table)
        let stmts = try RowEditor.build(c.dialect, info, changes)
        if dryRun || stmts.isEmpty { return EditResult(statements: stmts.map(\.1), affected: []) }
        let s = try await Self.open(c, password: store.password(for: c))
        var affected: [Int] = []
        do {
            try await s.txBegin(timeout: timeout)
            for (n, (op, sql, verify)) in stmts.enumerated() {
                var count: Int
                do { count = try await s.txExec(sql).affected }
                catch { throw RowbaseError("Statement \(n + 1) failed: \(error.localizedDescription)\n\(sql)") }
                if op == .update, count == 0, let verify {  // MySQL reports 0 when values are unchanged: confirm the row exists
                    count = Int(try await s.txExec(verify).first ?? "0") ?? 0
                }
                guard count == 1 else {
                    throw RowbaseError("Statement \(n + 1) affected \(count) rows (expected exactly 1) — nothing was saved.\n\(sql)")
                }
                affected.append(count)
            }
            try await s.txCommit()
        } catch {
            await s.txRollback()
            await s.close()
            throw error
        }
        await s.close()
        return EditResult(statements: stmts.map(\.1), affected: affected)
    }
}
