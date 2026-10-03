import SwiftUI
import RowbaseCore

struct HistorySheet: View {
    let state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [History.Entry] = []
    @State private var search = ""
    @State private var selection: String?

    private var filtered: [History.Entry] {
        search.isEmpty ? entries : entries.filter {
            $0.sql.localizedCaseInsensitiveContains(search) || ($0.connName ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search history", text: $search).textFieldStyle(.plain)
            }
            .padding(10)
            Divider()
            List(filtered, selection: $selection) { e in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(e.ts.replacingOccurrences(of: "T", with: " ")).monospacedDigit().foregroundStyle(.secondary)
                        Text(e.connName ?? e.conn).fontWeight(.medium)
                        Spacer()
                        if let err = e.error {
                            Text(err.split(separator: "\n").first.map(String.init) ?? err).foregroundStyle(.red).lineLimit(1)
                        } else if let a = e.affected {
                            Text("\(a) affected").foregroundStyle(.secondary)
                        } else if let r = e.rows {
                            Text("\(r) rows").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .font(.caption)
                    Text(e.sql).font(.system(size: 12, design: .monospaced)).lineLimit(2)
                }
                .padding(.vertical, 2)
                .tag(e.id)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { open(e) }
            }
            Divider()
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open") { if let e = entries.first(where: { $0.id == selection }) { open(e) } }
                    .keyboardShortcut(.defaultAction).disabled(selection == nil)
            }
            .padding(10)
        }
        .frame(width: 720, height: 520)
        .onAppear { entries = state.history.read(limit: 500) }
    }

    private func open(_ e: History.Entry) {
        guard let c = state.connections.first(where: { $0.id == e.conn }) else { return }
        state.openQuery(sql: e.sql, connection: c)
        dismiss()
    }
}
