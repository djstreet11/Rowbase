import SwiftUI
import RowbaseCore

struct MainView: View {
    @Bindable var state: AppState

    var body: some View {
        layout
        .sheet(isPresented: $state.showConnections) { ConnectionsSheet(state: state) }
        .sheet(isPresented: $state.showHistory) { HistorySheet(state: state) }
        .alert("Run on READ-WRITE connection \(state.pendingRun?.tab.connection.name ?? "")?",
               isPresented: Binding(get: { state.pendingRun != nil }, set: { if !$0 { state.pendingRun = nil } }),
               presenting: state.pendingRun) { p in
            Button("Run", role: .destructive) { state.confirm(p) }
            Button("Cancel", role: .cancel) { state.pendingRun = nil }
        } message: { p in
            Text(String(p.sql.prefix(300)))
        }
        .task { await state.bootstrap() }
    }

    @ViewBuilder private var layout: some View {
        if isSnapshot {  // the macOS 26 glass sidebar is invisible to cacheDisplay → plain layout for snapshots
            HStack(spacing: 0) {
                SidebarView(state: state).frame(width: 260)
                Divider()
                DetailView(state: state)
            }
        } else {
            NavigationSplitView {
                SidebarView(state: state)
                    .navigationSplitViewColumnWidth(min: 210, ideal: 260, max: 380)
            } detail: {
                DetailView(state: state)
            }
        }
    }
}

struct DetailView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            if let c = state.activeTab?.connection, c.env == "prod" {
                Rectangle().fill(hexColor(c.color) ?? .red).frame(height: 3)
            }
            TabBarView(state: state)
            Divider()
            Group {
                if let tab = state.activeTab {
                    switch tab.kind {
                    case .table: TableTabView(state: state, tab: tab).id(tab.id)
                    case .query: QueryTabView(state: state, tab: tab).id(tab.id)
                    }
                } else {
                    ContentUnavailableView {
                        Label("No tab open", systemImage: "tablecells")
                    } description: {
                        Text("Pick a table in the sidebar or start a SQL tab.")
                    } actions: {
                        Button("New SQL Tab") { state.openQuery() }.disabled(state.selectedConnection == nil)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            StatusBar(state: state)
        }
        .inspector(isPresented: $state.showInspector) {
            if let tab = state.activeTab {
                RowInspector(state: state, tab: tab)
                    .inspectorColumnWidth(min: 260, ideal: 320, max: 520)
            }
        }
    }
}

struct StatusBar: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 6) {
            left
            Spacer()
            if let c = state.activeTab?.connection ?? state.selectedConnection {
                ConnDot(color: c.color, size: 7)
                Text("\(c.name) · \(c.dialect.title)").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .frame(height: 24)
    }

    @ViewBuilder private var left: some View {
        if let t = state.activeTab {
            if t.running {
                ProgressView().controlSize(.mini); Text("Running…").foregroundStyle(.secondary)
            } else if let e = t.error {
                Text(e.split(separator: "\n").first.map(String.init) ?? e).foregroundStyle(.red).lineLimit(1)
            } else if let r = t.result {
                if let a = r.affected {
                    Text("\(a) row(s) affected · \(formatElapsed(r.elapsed))").monospacedDigit()
                } else {
                    Text("\(r.rows.count) rows · \(formatElapsed(r.elapsed))").monospacedDigit()
                    if r.truncated {
                        Text(t.isQuery ? "· truncated to LIMIT — add WHERE or raise limit" : "· more rows — use › or raise limit")
                            .foregroundStyle(.orange)
                    }
                }
                if let n = t.note { Text("· \(n)").foregroundStyle(.secondary) }
            } else {
                Text(t.note ?? "Ready").foregroundStyle(.secondary)
            }
        } else {
            Text(state.status.isEmpty ? "Ready" : state.status).foregroundStyle(state.status.isEmpty ? .secondary : Color.red).lineLimit(1)
        }
    }
}
