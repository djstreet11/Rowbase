import SwiftUI
import RowbaseCore

struct StructureView: View {
    let state: AppState
    let tab: WorkTab

    var body: some View {
        ScrollView {
            if let info = tab.info {
                VStack(alignment: .leading, spacing: 20) {
                    section("Columns") {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                            GridRow { head("#"); head("Name"); head("Type"); head("Null"); head("Key"); head("Default"); head("References") }
                            Divider().gridCellUnsizedAxes(.horizontal)
                            ForEach(Array(info.columns.enumerated()), id: \.offset) { i, c in
                                GridRow {
                                    Text("\(i + 1)").foregroundStyle(.secondary).monospacedDigit()
                                    Text(c.name).fontWeight(.semibold)
                                    Text(c.type).font(.system(size: 12, design: .monospaced))
                                    Text(c.nullable ? "YES" : "NO").foregroundStyle(.secondary)
                                    Text(c.key).foregroundStyle(.secondary)
                                    Text(c.defaultValue ?? "").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                                    if let fk = c.fk {
                                        Button("\(fk.table).\(fk.column)") { state.openTable(fk.table, connection: tab.connection) }.buttonStyle(.link)
                                    } else { Text("") }
                                }
                            }
                        }
                    }
                    section("Indexes") {
                        if info.indexes.isEmpty { Text("None").foregroundStyle(.secondary) }
                        else {
                            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                                GridRow { head("Name"); head("Unique"); head("Columns") }
                                Divider().gridCellUnsizedAxes(.horizontal)
                                ForEach(Array(info.indexes.enumerated()), id: \.offset) { _, ix in
                                    GridRow {
                                        Text(ix.name).fontWeight(.semibold)
                                        Text(ix.unique ? "YES" : "NO").foregroundStyle(.secondary)
                                        Text(ix.columns).font(.system(size: 12, design: .monospaced))
                                    }
                                }
                            }
                        }
                    }
                    section("Referenced by") {
                        if info.referencedBy.isEmpty { Text("None").foregroundStyle(.secondary) }
                        else {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(info.referencedBy.enumerated()), id: \.offset) { _, r in
                                    HStack(spacing: 6) {
                                        Button("\(r.table).\(r.column)") { state.openTable(r.table, connection: tab.connection) }.buttonStyle(.link)
                                        Text("→ \(r.refColumn)").foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let e = tab.error {
                Text(e).foregroundStyle(.red).padding()
            } else {
                ProgressView().padding(40)
            }
        }
        .font(.callout)
    }

    private func head(_ s: String) -> some View { Text(s).font(.caption.weight(.medium)).foregroundStyle(.secondary) }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }
}
