import SwiftUI
import AppKit
import RowbaseCore

/// Toolbar menu "Export" (table and query tabs).
struct ExportMenu: View {
    let state: AppState
    let tab: WorkTab

    private var enabled: Bool {
        guard let r = tab.result, !tab.running, !tab.exporting, !r.columns.isEmpty || tab.tableName != nil else { return false }
        return tab.isQuery ? tab.exportable : !tab.isExplain
    }

    var body: some View {
        Menu {
            ForEach(ExportFormat.allCases, id: \.self) { f in
                Button(f.title) { state.export(tab, f) }
            }
        } label: {
            IconMenuLabel(symbol: "square.and.arrow.up")
        }
        .menuStyle(.button).buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!enabled)
        .help(tab.isQuery ? "Export — re-run the last statement and save the full result (up to 1,000,000 rows)"
                          : "Export — save the whole filtered table, not just this page")
    }
}

/// "…" menu of the tab toolbars: copy actions (+ table-only Open in SQL Editor / Count Rows).
struct MoreMenu: View {
    let state: AppState
    let tab: WorkTab

    var body: some View {
        Menu {
            Button("Copy as JSON") { if let r = tab.visibleExport { copyToPasteboard(Export.json(columns: r.columns, rows: r.rows)) } }
                .disabled(tab.result == nil)
            Button("Copy as TSV") { if let r = tab.visibleExport { copyToPasteboard(Export.tsv(columns: r.columns, rows: r.rows)) } }
                .disabled(tab.result == nil)
            if !tab.isQuery {
                Divider()
                Button("Open in SQL Editor") { if state.filtersOK(tab) { state.openQuery(sql: tab.buildSQL(), connection: tab.connection) } }
                Button("Count Rows") { Task { await state.count(tab) } }
                Button("Open in Query Builder") { state.openBuilder(from: tab) }
            }
        } label: {
            IconMenuLabel(symbol: "ellipsis.circle")
        }
        .menuStyle(.button).buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }
}

/// Soft yellow strip under the toolbar while a table tab has pending edits.
struct PendingStrip: View {
    let state: AppState
    @Bindable var tab: WorkTab

    var body: some View {
        let n = tab.pendingCount
        if n > 0 {
            HStack(spacing: 10) {
                Image(systemName: "pencil.circle.fill").foregroundStyle(.orange)
                Text(plural(n, "unsaved change")).fontWeight(.medium).monospacedDigit()
                Spacer()
                Button("Preview SQL") { Task { await state.previewSQL(tab) } }.buttonStyle(.link)
                Button("Discard") { tab.clearPending() }.buttonStyle(.link)
                Button { state.requestSave(tab) } label: { Text(tab.saving ? "Saving…" : "Save") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(tab.saving)
                    .help("Apply all pending changes in one transaction (⌘S)")
            }
            .font(.callout)
            .controlSize(.small)
            .padding(.horizontal, 12).frame(height: 28)
            .background(Color.yellow.opacity(0.16))
            Divider()
        }
    }
}

/// Generated statements from `Engine.apply(dryRun: true)`.
struct SQLPreviewSheet: View {
    let statements: [String]
    @Environment(\.dismiss) private var dismiss

    private var text: String {
        statements.isEmpty ? "-- nothing to run" : statements.map { $0 + ";" }.joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Preview SQL").font(.headline)
                Text(plural(statements.count, "statement")).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                SelectableText(text, font: .mono(), wraps: false)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .defaultScrollAnchor(.topLeading)
            .background(Color(nsColor: .textBackgroundColor))
            Divider()
            HStack {
                Text("Runs in a single transaction; any failure rolls everything back.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { copyToPasteboard(text) }
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 380)
    }
}

/// Multiline editor for long values (context menu "Edit…").
struct CellEditSheet: View {
    let tab: WorkTab
    let ref: CellRef
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    private var current: String? {
        ref.insert ? (ref.row < tab.inserts.count ? tab.inserts[ref.row][ref.column]?.value : nil)
                   : tab.effective(row: ref.row, column: ref.column)
    }

    var body: some View {
        let ci = tab.columnInfo(ref.column)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(ref.column).font(.headline)
                if let t = ci?.type { Text(t).foregroundStyle(.secondary) }
                Spacer()
                if current == nil { Text("currently NULL").font(.caption).foregroundStyle(.tertiary) }
            }
            TextEditor(text: $draft)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
            HStack {
                Button("Set NULL") { tab.setCell(ref, to: nil); dismiss() }.disabled(ci?.nullable == false)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { tab.setCell(ref, to: draft); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520, height: 340)
        .onAppear { draft = current ?? "" }
    }
}

/// Table name for SQL INSERT export from a query tab.
struct ExportTableSheet: View {
    let state: AppState
    let prompt: ExportPrompt
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Table name for INSERT statements").font(.headline)
            TextField("table or schema.table", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(go)
            HStack {
                Spacer()
                Button("Cancel") { state.exportPrompt = nil }.keyboardShortcut(.cancelAction)
                Button("Continue", action: go)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { name = prompt.table }
    }

    private func go() {
        let t = name.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        state.exportPrompt = nil
        Task { await state.runExport(prompt.tab, prompt.format, table: t) }
    }
}
