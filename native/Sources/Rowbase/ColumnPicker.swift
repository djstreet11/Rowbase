import SwiftUI
import RowbaseCore

/// Icon toolbar button (accent dot while some columns are hidden) with the picker popover.
struct ColumnsButton: View {
    @Bindable var tab: WorkTab

    var body: some View {
        let cols = tab.allColumns
        let shown = cols.filter { !tab.hidden.contains($0) }.count
        let partial = !cols.isEmpty && shown < cols.count
        IconButton(symbol: "slider.horizontal.3", help: cols.isEmpty ? "Columns" : "Columns — \(shown) of \(cols.count) shown", active: false) {
            tab.columnPickerOpen.toggle()
        }
        .overlay(alignment: .topTrailing) {
            if partial { Circle().fill(Color.accentColor).frame(width: 6, height: 6).offset(x: -3, y: 3) }
        }
        .disabled(cols.isEmpty)
        .popover(isPresented: $tab.columnPickerOpen, arrowEdge: .bottom) { ColumnPicker(tab: tab) }
    }
}

struct ColumnPicker: View {
    @Bindable var tab: WorkTab
    @State private var query = ""

    private var types: [String: String] {
        Dictionary(uniqueKeysWithValues: (tab.info?.columns ?? []).map { ($0.name, $0.type) })
    }

    private var filtered: [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = tab.allColumns
        return q.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        let list = filtered
        let types = types
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                TextField("Find column", text: $query).textFieldStyle(.roundedBorder)
                Button("All") { tab.hidden.subtract(list) }
                Button("None") { tab.hidden.formUnion(list) }
            }
            .controlSize(.small)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(list, id: \.self) { c in
                        Toggle(isOn: Binding(get: { !tab.hidden.contains(c) },
                                             set: { if $0 { tab.hidden.remove(c) } else { tab.hidden.insert(c) } })) {
                            HStack(spacing: 8) {
                                Text(c).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 6)
                                if let t = types[c], !t.isEmpty {
                                    Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                    if list.isEmpty { Text("No match").foregroundStyle(.secondary).font(.caption) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(width: 300, height: max(150, min(360, CGFloat(tab.allColumns.count) * 22 + 70)))
    }
}
