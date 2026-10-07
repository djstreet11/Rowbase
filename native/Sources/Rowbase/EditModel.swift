import SwiftUI
import AppKit
import RowbaseCore

/// A pending value for a cell. `value == nil` means SQL NULL.
struct NewValue: Equatable, Sendable {
    var value: String?
}

/// Address of a cell in the pending model: a loaded result row, or a pending insert row (index into `WorkTab.inserts`).
struct CellRef: Identifiable, Hashable {
    var insert: Bool
    var row: Int
    var column: String
    var id: String { "\(insert ? "i" : "r")\(row):\(column)" }
}

extension WorkTab {
    // MARK: capability

    /// Editing is available on table tabs of write-enabled connections whose table has a primary key.
    var canEdit: Bool {
        guard tableName != nil, !connection.readOnly, let i = info else { return false }
        return !i.primaryKey.isEmpty
    }

    /// Why editing is unavailable (nil when it is available or the reason is not known yet / not a table tab).
    var editBlockReason: String? {
        guard tableName != nil else { return nil }
        if connection.readOnly { return "Read-only connection — enable writes in Connections to edit" }
        if let i = info, i.primaryKey.isEmpty { return "Table has no primary key — editing disabled" }
        return nil
    }

    func columnInfo(_ name: String) -> ColumnInfo? { info?.columns.first { $0.name == name } }

    func isBinary(_ name: String) -> Bool {
        guard let t = columnInfo(name)?.type else { return false }
        return t.range(of: "binary|blob|bytea", options: [.regularExpression, .caseInsensitive]) != nil
    }

    func isEditable(_ name: String) -> Bool { canEdit && !isBinary(name) }

    func flashHint(_ text: String) {
        hint = text
        hintToken += 1
        let tok = hintToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if let self, self.hintToken == tok { self.hint = nil }
        }
    }

    // MARK: values

    /// Number of pending changes: edited rows + deleted rows + inserted rows.
    var pendingCount: Int { edits.keys.filter { !deleted.contains($0) }.count + deleted.count + inserts.count }

    func original(row: Int, column: String) -> String? {
        guard let r = result, row < r.rows.count, let ci = r.columns.firstIndex(of: column), ci < r.rows[row].count else { return nil }
        return r.rows[row][ci]
    }

    func effective(row: Int, column: String) -> String? {
        if let e = edits[row]?[column] { return e.value }
        return original(row: row, column: column)
    }

    func effectiveRow(_ i: Int) -> [String?]? {
        guard let r = result, i < r.rows.count else { return nil }
        return r.columns.enumerated().map { ci, name in edits[i]?[name].map(\.value) ?? (ci < r.rows[i].count ? r.rows[i][ci] : nil) }
    }

    func isEdited(row: Int, column: String) -> Bool { edits[row]?[column] != nil }

    // MARK: mutation

    func setCell(_ ref: CellRef, to value: String?) {
        guard isEditable(ref.column) else { return }
        if ref.insert {
            guard ref.row < inserts.count else { return }
            inserts[ref.row][ref.column] = NewValue(value: value)
            return
        }
        guard !deleted.contains(ref.row) else { return }
        var row = edits[ref.row] ?? [:]
        if value == original(row: ref.row, column: ref.column) { row[ref.column] = nil } else { row[ref.column] = NewValue(value: value) }
        edits[ref.row] = row.isEmpty ? nil : row
    }

    /// Undo the pending change behind a cell: a cell edit, a delete mark, or (insert row) the whole insert.
    func revert(_ ref: CellRef) {
        if ref.insert {
            if ref.row < inserts.count { inserts.remove(at: ref.row) }
        } else if deleted.contains(ref.row) {
            deleted.remove(ref.row)
        } else if var row = edits[ref.row] {
            row[ref.column] = nil
            edits[ref.row] = row.isEmpty ? nil : row
        }
    }

    func addInsertRow() {
        inserts.insert([:], at: 0)
        selectedInserts = []
    }

    /// Delete marks on result rows (toggle off when all are already marked) and removal of pending insert rows.
    func deleteRows(result rows: Set<Int>, inserts ins: Set<Int>) {
        if !ins.isEmpty {
            for i in ins.sorted(by: >) where i < inserts.count { inserts.remove(at: i) }
            selectedInserts = []
        }
        let valid = rows.filter { r in r < (result?.rows.count ?? 0) }
        guard !valid.isEmpty else { return }
        if valid.allSatisfy({ deleted.contains($0) }) { deleted.subtract(valid) } else { deleted.formUnion(valid) }
    }

    func deleteSelected() { deleteRows(result: selectedRows, inserts: selectedInserts) }

    var hasSelection: Bool { !selectedRows.isEmpty || !selectedInserts.isEmpty }

    /// Insert row with the same non-PK values as a result row (pending edits included).
    func duplicate(row: Int) {
        guard let r = result, row < r.rows.count, let pk = info?.primaryKey else { return }
        var d: [String: NewValue] = [:]
        for name in r.columns where !pk.contains(name) && isEditable(name) {
            d[name] = NewValue(value: effective(row: row, column: name))
        }
        inserts.insert(d, at: 0)
        selectedInserts = []
    }

    func duplicate(insert i: Int) {
        guard i < inserts.count else { return }
        inserts.insert(inserts[i], at: 0)
        selectedInserts = []
    }

    func clearPending() {
        if !edits.isEmpty { edits = [:] }
        if !deleted.isEmpty { deleted = [] }
        if !inserts.isEmpty { inserts = [] }
        selectedInserts = []
    }

    // MARK: save

    /// Translate the pending state into Core changes: deletes, then updates keyed by the ORIGINAL primary key, then inserts
    /// (only the columns the user filled).
    func buildChanges() throws -> [RowChange] {
        guard let info, let r = result else { throw RowbaseError("No data loaded.") }
        let pk = info.primaryKey
        func key(_ row: Int) throws -> [ColumnValue] {
            try pk.map { p in
                guard let ci = r.columns.firstIndex(of: p), ci < r.rows[row].count else { throw RowbaseError("Primary key column '\(p)' is missing from the result.") }
                return ColumnValue(p, r.rows[row][ci])
            }
        }
        var out: [RowChange] = []
        for row in deleted.sorted() where row < r.rows.count { out.append(.delete(key: try key(row))) }
        for row in edits.keys.sorted() where !deleted.contains(row) && row < r.rows.count {
            let set = r.columns.compactMap { c in edits[row]?[c].map { ColumnValue(c, $0.value) } }
            if !set.isEmpty { out.append(.update(key: try key(row), set: set)) }
        }
        for ins in inserts.reversed() {  // oldest first
            out.append(.insert(r.columns.compactMap { c in ins[c].map { ColumnValue(c, $0.value) } }))
        }
        return out
    }

    // MARK: export

    /// Whole filtered table (no LIMIT/OFFSET) — what Export runs for table tabs.
    func exportSQL() -> String {
        var s = "SELECT * FROM \(fromClause)"
        let w = safeWhere
        if !w.isEmpty { s += " WHERE \(w)" }
        let o = effectiveOrder
        if !o.isEmpty { s += " ORDER BY \(o)" }
        return s
    }
}
