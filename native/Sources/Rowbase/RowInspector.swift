import SwiftUI
import RowbaseCore

struct RowInspector: View {
    let state: AppState
    let tab: WorkTab?
    @State private var filter = ""

    private var row: [String?]? {
        guard let tab, let i = tab.inspectRow else { return nil }
        return tab.effectiveRow(i)  // includes pending edits
    }

    private var rowNumber: Int { (tab?.inspectRow ?? 0) + 1 + ((tab?.isQuery ?? true) ? 0 : (tab?.offset ?? 0)) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab?.inspectRow == nil ? "Inspector" : "Row \(rowNumber)").font(.headline).lineLimit(1)
                    if tab?.inspectRow != nil {
                        Text(tab?.tableName ?? "Query result").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                IconButton(symbol: "doc.on.doc", help: "Copy row as JSON") {
                    if let r = tab?.result, let row { copyToPasteboard(Export.jsonObject(columns: r.columns, row: row, indent: "")) }
                }
                .disabled(row == nil)
                IconButton(symbol: "xmark", help: "Close (Esc)") { state.showInspector = false }
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8)
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Filter fields", text: $filter).textFieldStyle(.plain)
            }
            .font(.callout)
            .padding(.horizontal, 8).frame(height: 24)
            .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            if let tab, let r = tab.result, let row {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(r.columns.enumerated()), id: \.offset) { i, name in
                            if filter.isEmpty || name.localizedCaseInsensitiveContains(filter) {
                                field(tab: tab, name: name, value: i < row.count ? row[i] : nil, row: tab.inspectRow ?? 0)
                                Divider().padding(.leading, 12)
                            }
                        }
                        if let info = tab.info, !info.referencedBy.isEmpty {
                            SectionLabel(title: "Referenced by").padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 6)
                            ForEach(Array(info.referencedBy.enumerated()), id: \.offset) { _, ref in
                                if let ci = r.columns.firstIndex(of: ref.refColumn), ci < row.count, let v = row[ci] {
                                    Button { openRef(tab, ref, value: v) } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "arrow.turn.down.right").font(.system(size: 11)).foregroundStyle(.secondary)
                                            Text("\(ref.table).\(ref.column)").font(.callout)
                                            Spacer()
                                        }
                                        .padding(.horizontal, 12).frame(height: 24).contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                                    .help("Open \(ref.table) rows referencing this row")
                                }
                            }
                        }
                    }
                }
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

    private func field(tab: WorkTab, name: String, value: String?, row: Int) -> some View {
        let ci = tab.info?.columns.first { $0.name == name }
        let editable = tab.isEditable(name) && !tab.deleted.contains(row)
        let edited = tab.isEdited(row: row, column: name)
        let fk = ci?.fk != nil && !tab.isQuery
        let mono = Font.system(size: 12, design: .monospaced)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(name).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 4)
                if editable {
                    if ci?.nullable != false {
                        Button("NULL") { tab.setCell(CellRef(insert: false, row: row, column: name), to: nil) }
                            .buttonStyle(.borderless).font(.caption2).foregroundStyle(.secondary).help("Set to NULL")
                    }
                    if edited {
                        Button { tab.revert(CellRef(insert: false, row: row, column: name)) } label: { Image(systemName: "arrow.uturn.backward") }
                            .buttonStyle(.borderless).help("Revert change")
                    }
                }
                if let t = ci?.type { Text(t).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
            }
            HStack(alignment: .top, spacing: 6) {
                if editable {
                    InspectorEditField(tab: tab, row: row, name: name, value: value)
                        .id("\(row)|\(name)|\(edited)")
                } else if let value {
                    Text(value).font(mono).foregroundStyle(fk ? Color(nsColor: .linkColor) : .primary)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("NULL").font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color(nsColor: .quaternaryLabelColor), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                if fk, let value {
                    Button { state.followFK(from: tab, column: name, value: value) } label: { Image(systemName: "arrow.right.circle") }
                        .buttonStyle(.borderless).foregroundStyle(Color(nsColor: .linkColor)).help("Open referenced row")
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(edited ? Color.yellow.opacity(0.18) : Color.clear)
    }

    private func openRef(_ tab: WorkTab, _ ref: Reference, value: String) {
        let d = tab.connection.dialect
        let lit = value.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil ? value : d.literal(value)
        state.openTable(ref.table, where: "\(d.column(ref.column)) = \(lit)", chain: state.chain(from: tab, via: ref.refColumn), connection: tab.connection)
    }
}

/// Editable value of one inspector field; commits on Return / focus loss into the tab's pending model.
private struct InspectorEditField: View {
    let tab: WorkTab
    let row: Int
    let name: String
    let value: String?
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(value == nil ? "NULL" : "", text: $draft, axis: .vertical)
            .font(.system(size: 12, design: .monospaced))
            .lineLimit(1...8)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { if !focused { commit() } }
            .onAppear { draft = value ?? "" }
    }

    private func commit() {
        if (value == nil && draft.isEmpty) || draft == value { return }
        tab.setCell(CellRef(insert: false, row: row, column: name), to: draft)
    }
}
