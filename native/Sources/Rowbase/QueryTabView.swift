import SwiftUI
import RowbaseCore

struct QueryTabView: View {
    let state: AppState
    @Bindable var tab: WorkTab

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if tab.running {
                    Button { state.cancel(tab) } label: { Label("Stop", systemImage: "stop.fill") }
                        .tint(.red).keyboardShortcut(".", modifiers: .command).help("Stop the running query (⌘.)")
                } else {
                    Button { state.run(tab) } label: { Label("Run", systemImage: "play.fill") }
                        .help("Run statement under caret or selection (⌘↩)")
                }
                Button { state.run(tab, explain: true) } label: { Label("Explain", systemImage: "chart.bar.doc.horizontal") }
                Picker("Limit", selection: $tab.limit) {
                    ForEach([100, 500, 1000, 5000], id: \.self) { Text("\($0)").tag($0) }
                }
                .frame(width: 130)
                Spacer()
                ConnDot(color: tab.connection.color, size: 7)
                Text(tab.connection.name).font(.caption).foregroundStyle(.secondary)
                if !tab.connection.readOnly { Text("READ-WRITE").font(.caption.weight(.bold)).foregroundStyle(.red) }
            }
            .controlSize(.small)
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            VSplitView {
                SQLEditor(tab: tab, state: state)
                    .frame(minHeight: 120, idealHeight: 220)
                ResultArea(state: state, tab: tab)
                    .frame(minHeight: 120)
            }
        }
    }
}
