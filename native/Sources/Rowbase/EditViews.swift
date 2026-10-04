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
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!enabled)
        .help(tab.isQuery ? "Re-run the last statement and save the full result (up to 1,000,000 rows)"
                          : "Save the whole filtered table, not just this page")
    }
}

/// Edit controls row of a table tab (only shown when the tab is edit-capable).
struct EditToolbar: View {
    let state: AppState
    @Bindable var tab: WorkTab

    var body: some View {
        let n = tab.pendingCount
        HStack(spacing: 8) {
            Button { tab.addInsertRow() } label: { Label("Row", systemImage: "plus") }
                .help("Add an empty row at the top (saved with Save)")
            Button { tab.deleteSelected() } label: { Label("Delete", systemImage: "trash") }
                .disabled(!tab.hasSelection)
                .help("Mark the selected rows for deletion")
            Spacer()
            if n > 0 {
                Text(plural(n, "change"))
                    .font(.caption.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Color.yellow.opacity(0.28), in: Capsule())
                Button("Preview SQL") { Task { await state.previewSQL(tab) } }
                Button("Discard") { tab.clearPending() }
                Button { state.requestSave(tab) } label: { Text(tab.saving ? "Saving…" : "Save") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(tab.saving)
                    .help("Apply all pending changes in one transaction (⌘S)")
            }
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
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
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
