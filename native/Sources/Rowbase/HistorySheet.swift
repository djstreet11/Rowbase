import SwiftUI
import RowbaseCore

struct HistorySheet: View {
    let state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [History.Entry] = []
    @State private var search = ""
    @State private var selection: String?
    @State private var errorsOnly = ProcessInfo.processInfo.environment["ROWBASE_SNAPSHOT_ERRORS"] == "1"

    private var filtered: [History.Entry] {
        entries.filter {
            (!errorsOnly || $0.error != nil)
                && (search.isEmpty || $0.sql.localizedCaseInsensitiveContains(search) || ($0.connName ?? "").localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search history", text: $search).textFieldStyle(.plain)
                Toggle("Errors only", isOn: $errorsOnly).toggleStyle(.checkbox)
            }
            .padding(10)
            Divider()
            List(filtered, selection: $selection) { e in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(e.ts.replacingOccurrences(of: "T", with: " ")).monospacedDigit().foregroundStyle(.secondary)
                        Text(e.connName ?? e.conn).fontWeight(.medium)
                        if let src = e.source, !src.isEmpty { Text(src).foregroundStyle(.tertiary) }
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
                Text("\(filtered.count) of \(entries.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open") { if let e = entries.first(where: { $0.id == selection }) { open(e) } }
                    .keyboardShortcut(.defaultAction).disabled(selection == nil)
            }
            .padding(10)
        }
        .frame(width: 720, height: 520)
        .overlay { if filtered.isEmpty { Text("Nothing found").foregroundStyle(.secondary) } }
        .onAppear { entries = state.history.read(limit: 500) }
    }

    private func open(_ e: History.Entry) {
        guard let c = state.connections.first(where: { $0.id == e.conn }) else { return }
        state.openQuery(sql: e.sql, connection: c)
        dismiss()
    }
}
