import SwiftUI
import AppKit
import RowbaseCore

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

struct PendingDiscard: Identifiable {
    let id = UUID()
    let tab: WorkTab
    let action: @MainActor () -> Void
}

struct ExportPrompt: Identifiable {
    let id = UUID()
    let tab: WorkTab
    let format: ExportFormat
    var table: String
}

func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

extension AppState {
    // MARK: unsaved changes guards

    /// Run `proceed` now, or after the user agrees to discard the tab's pending changes.
    func guardPending(_ tab: WorkTab, _ proceed: @escaping @MainActor () -> Void) {
        guard tab.pendingCount > 0 else { proceed(); return }
        pendingDiscard = PendingDiscard(tab: tab, action: proceed)
    }

    func requestClose(_ id: UUID) {
        guard let t = tabs.first(where: { $0.id == id }) else { return }
        guardPending(t) { [self] in closeTab(id) }
    }

    // MARK: save / preview

    func requestSave(_ tab: WorkTab) {
        guard tab.pendingCount > 0, !tab.saving else { return }
        if tab.connection.env == "prod" { pendingSave = tab } else { Task { await save(tab) } }
    }

    func save(_ tab: WorkTab) async {
        guard let table = tab.tableName, !tab.saving else { return }
        let conn = tab.connection
        let n = tab.pendingCount
        tab.saving = true
        defer { tab.saving = false }
        do {
            let changes = try tab.buildChanges()
            let r = try await engine.apply(conn, table: table, changes: changes)
            for s in r.statements {
                history.add(History.Entry(conn: conn.id, connName: conn.name, sql: s, source: "edit", affected: 1))
            }
            tab.clearPending()
            await loadTable(tab)
            tab.note = "Saved \(plural(n, "change"))"
        } catch {
            history.add(History.Entry(conn: conn.id, connName: conn.name, sql: "-- edit \(table): \(plural(n, "change")) (rolled back)",
                                      source: "edit", error: error.localizedDescription))
            alert = AppAlert(title: "Save failed — nothing was saved", message: error.localizedDescription)
        }
    }

    func previewSQL(_ tab: WorkTab) async {
        guard let table = tab.tableName else { return }
        do {
            let changes = try tab.buildChanges()
            let r = try await engine.apply(tab.connection, table: table, changes: changes, dryRun: true)
            tab.previewStatements = r.statements
        } catch {
            alert = AppAlert(title: "Can't preview changes", message: error.localizedDescription)
        }
    }

    // MARK: export

    func export(_ tab: WorkTab, _ fmt: ExportFormat) {
        if fmt == .sql, tab.isQuery {
            exportPrompt = ExportPrompt(tab: tab, format: fmt, table: Self.guessTable(in: tab.lastSQL))
            return
        }
        Task { await runExport(tab, fmt, table: tab.tableName) }
    }

    /// First table after FROM (identifier quotes and schema prefix kept as written, quotes stripped).
    static func guessTable(in sql: String) -> String {
        let part = #"(?:[\w$]+|"[^"]+"|`[^`]+`)"#
        let pattern = #"\bFROM\s+("# + part + #"(?:\s*\.\s*"# + part + #")?)"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: sql, range: NSRange(sql.startIndex..., in: sql)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: sql) else { return "" }
        return String(sql[r]).replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    func runExport(_ tab: WorkTab, _ fmt: ExportFormat, table: String?) async {
        if tab.tableName != nil && !filtersOK(tab) { return }
        let sql = tab.tableName != nil ? tab.exportSQL() : tab.lastSQL
        guard !sql.isEmpty, !tab.exporting else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (tab.tableName ?? "query") + "." + fmt.fileExtension
        panel.canCreateDirectories = true
        panel.title = "Export as \(fmt.title)"
        let resp: NSApplication.ModalResponse
        if let w = NSApp.keyWindow ?? NSApp.mainWindow { resp = await panel.beginSheetModal(for: w) } else { resp = panel.runModal() }
        guard resp == .OK, let url = panel.url else { return }
        let conn = tab.connection
        let source = "export:\(fmt.rawValue)"
        tab.exporting = true
        defer { tab.exporting = false }
        do {
            let r = try await engine.execute(conn, sql, limit: 1_000_000, timeout: 300)
            let idx = r.columns.indices.filter { !tab.hidden.contains(r.columns[$0]) }
            let cols = idx.map { r.columns[$0] }
            let data = r.rows.map { row in idx.map { $0 < row.count ? row[$0] : nil } }
            let dialect = conn.dialect
            let text = try await Task.detached { try Exporter.render(columns: cols, rows: data, format: fmt, table: table, dialect: dialect) }.value
            try text.write(to: url, atomically: true, encoding: .utf8)
            tab.note = "Exported \(data.count) rows to \(url.lastPathComponent)" + (r.truncated ? " · truncated" : "")
            record(tab, sql: sql, source: source, result: r, error: nil)
        } catch {
            record(tab, sql: sql, source: source, result: nil, error: error.localizedDescription)
            alert = AppAlert(title: "Export failed", message: error.localizedDescription)
        }
    }
}
