import SwiftUI
import RowbaseCore

struct TableTabView: View {
    let state: AppState
    @Bindable var tab: WorkTab

    var body: some View {
        VStack(spacing: 0) {
            if !tab.breadcrumbs.isEmpty { crumbs; Divider() }
            VStack(spacing: 6) {
                row1
                row2
                if tab.canEdit { EditToolbar(state: state, tab: tab) }
                Text(tab.buildSQL())
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .controlSize(.small)
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            if tab.showStructure {
                StructureView(state: state, tab: tab)
            } else {
                ResultArea(state: state, tab: tab)
            }
        }
        .sheet(item: $tab.editSheet) { ref in CellEditSheet(tab: tab, ref: ref) }
        .sheet(isPresented: Binding(get: { tab.previewStatements != nil }, set: { if !$0 { tab.previewStatements = nil } })) {
            SQLPreviewSheet(statements: tab.previewStatements ?? [])
        }
    }

    private var crumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(tab.breadcrumbs) { c in
                    Button(c.title) { state.openCrumb(c, from: tab) }.buttonStyle(.link)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    if let v = c.via { Text("via \(v)").font(.caption).foregroundStyle(.secondary) }
                    if c.via != nil { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                }
                Text(tab.title).fontWeight(.medium)
            }
            .font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
    }

    private var row1: some View {
        HStack(spacing: 8) {
            Picker("", selection: $tab.showStructure) {
                Text("Data").tag(false)
                Text("Structure").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            CompletingField(text: $tab.whereText, placeholder: "WHERE …", mode: .whereClause, tab: tab, state: state, onSubmit: apply)
                .frame(maxWidth: .infinity)
            CompletingField(text: $tab.orderText, placeholder: tab.defaultOrder.isEmpty ? "ORDER BY …" : tab.defaultOrder,
                            mode: .orderBy, tab: tab, state: state, onSubmit: apply)
                .frame(maxWidth: 240)
            Picker("", selection: $tab.limit) {
                ForEach([50, 100, 500, 1000], id: \.self) { Text("\($0)").tag($0) }
            }
            .labelsHidden().frame(width: 70)
            .onChange(of: tab.limit) { apply() }
            if tab.running {
                Button { state.cancel(tab) } label: { Label("Stop", systemImage: "stop.fill") }
                    .tint(.red).keyboardShortcut(".", modifiers: .command).help("Stop the running query (⌘.)")
            } else {
                Button { apply() } label: { Label("Run", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).help("Run (Return in a field, ⌘↩)")
            }
        }
    }

    private var row2: some View {
        HStack(spacing: 8) {
            Button { state.page(tab, by: -1) } label: { Image(systemName: "chevron.left") }
                .disabled(tab.offset == 0 || tab.running)
            Text(rangeLabel).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Button { state.page(tab, by: 1) } label: { Image(systemName: "chevron.right") }
                .disabled(!tab.hasMore || tab.running)
            Button("Count") { Task { await state.count(tab) } }
            Spacer()
            Picker("", selection: $tab.transpose) {
                Text("Grid").tag(false)
                Text("Transpose").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 150).help("Transpose: rows become columns")
            ColumnsButton(tab: tab)
            ExportMenu(state: state, tab: tab)
            Button { state.openQuery(sql: tab.buildSQL(), connection: tab.connection) } label: { Label("Open in SQL", systemImage: "terminal") }
            Button { if let r = tab.visibleExport { copyToPasteboard(Export.json(columns: r.columns, rows: r.rows)) } } label: { Label("Copy JSON", systemImage: "curlybraces") }
                .disabled(tab.result == nil)
            Button { if let r = tab.visibleExport { copyToPasteboard(Export.tsv(columns: r.columns, rows: r.rows)) } } label: { Label("Copy TSV", systemImage: "doc.on.doc") }
                .disabled(tab.result == nil)
        }
    }

    private var rangeLabel: String {
        let n = tab.result?.rows.count ?? 0
        return n == 0 ? "0" : "\(tab.offset + 1)–\(tab.offset + n)"
    }

    private func apply() {
        state.guardPending(tab) {
            tab.offset = 0
            Task { await state.loadTable(tab) }
        }
    }
}
