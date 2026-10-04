import SwiftUI
import RowbaseCore

struct RowInspector: View {
    let state: AppState
    let tab: WorkTab?
    @State private var filter = ""

    private var row: [String?]? {
        guard let tab, let r = tab.result, let i = tab.inspectRow, i < r.rows.count else { return nil }
        return r.rows[i]
    }

    private var title: String {
        guard let tab, tab.inspectRow != nil else { return "Inspector" }
        return "\(tab.tableName ?? "Result") · row \((tab.inspectRow ?? 0) + 1 + (tab.isQuery ? 0 : tab.offset))"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Button("Copy JSON") {
                    if let r = tab?.result, let row { copyToPasteboard(Export.jsonObject(columns: r.columns, row: row, indent: "")) }
                }
                .controlSize(.small).disabled(row == nil)
                Button { state.showInspector = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Close (Esc)")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            TextField("Filter fields", text: $filter).textFieldStyle(.roundedBorder).controlSize(.small)
                .padding(.horizontal, 10).padding(.bottom, 8)
            Divider()
            if let tab, let r = tab.result, let row {
                List {
                    Section {
                        ForEach(Array(r.columns.enumerated()), id: \.offset) { i, name in
                            if filter.isEmpty || name.localizedCaseInsensitiveContains(filter) {
                                field(tab: tab, name: name, value: i < row.count ? row[i] : nil)
                            }
                        }
                    }
                    if let info = tab.info, !info.referencedBy.isEmpty {
                        Section("Referenced by") {
                            ForEach(Array(info.referencedBy.enumerated()), id: \.offset) { _, ref in
                                if let ci = r.columns.firstIndex(of: ref.refColumn), ci < row.count, let v = row[ci] {
                                    Button { openRef(tab, ref, value: v) } label: {
                                        HStack {
                                            Image(systemName: "arrow.turn.down.right")
                                            Text("\(ref.table).\(ref.column)")
                                            Spacer()
                                        }
                                    }
                                    .buttonStyle(.link)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            } else {
                Spacer()
                Text("Select a row").foregroundStyle(.secondary)
                Text("Double-click a row or press Space").font(.caption).foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func field(tab: WorkTab, name: String, value: String?) -> some View {
        let ci = tab.info?.columns.first { $0.name == name }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(name).fontWeight(.semibold)
                if let t = ci?.type { Text(t).font(.caption).foregroundStyle(.secondary) }
            }
            if let value {
                if ci?.fk != nil, !tab.isQuery {
                    Button { state.followFK(from: tab, column: name, value: value) } label: {
                        Text(value).font(.system(size: 12, design: .monospaced)).multilineTextAlignment(.leading)
                    }.buttonStyle(.link)
                } else {
                    Text(value).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
            } else {
                Text("NULL").font(.system(size: 12, design: .monospaced)).italic().foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func openRef(_ tab: WorkTab, _ ref: Reference, value: String) {
        let d = tab.connection.dialect
        let lit = value.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil ? value : d.literal(value)
        state.openTable(ref.table, where: "\(d.column(ref.column)) = \(lit)", chain: state.chain(from: tab, via: ref.refColumn), connection: tab.connection)
    }
}
