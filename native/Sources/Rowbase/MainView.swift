import SwiftUI
import RowbaseCore

struct MainView: View {
    @Bindable var state: AppState

    var body: some View {
        ThreePaneSplit(showSidebar: state.showSidebar, showInspector: state.showInspector,
                       sidebar: SidebarView(state: state),
                       detail: DetailView(state: state),
                       inspector: RowInspector(state: state, tab: state.activeTab))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { state.toggleSidebar() } label: { Image(systemName: "sidebar.left") }
                    .help("Toggle Sidebar (⌥⌘S)")
            }
            ToolbarItem(placement: .navigation) { ConnectionBadge(state: state) }
            ToolbarItem(placement: .primaryAction) {
                Button { state.toggleInspector() } label: { Image(systemName: "sidebar.right") }
                    .help("Toggle Inspector (⌘I)")
            }
        }
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
        .modifier(EditAlerts(state: state))
        .task { await state.bootstrap() }
        .onAppear { installEscMonitor() }
    }

    /// Esc closes the inspector unless a text view (editor, field editor) is handling keys.
    private func installEscMonitor() {
        guard !escMonitorInstalled else { return }
        escMonitorInstalled = true
        let st = state
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.keyCode == 53, e.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return e }
            let win = e.window
            let handled: Bool = MainActor.assumeIsolated {
                guard st.showInspector, win?.attachedSheet == nil, win?.sheetParent == nil, !(win?.firstResponder is NSText) else { return false }
                st.showInspector = false
                return true
            }
            return handled ? nil : e
        }
    }
}

@MainActor private var escMonitorInstalled = false

struct ConnectionBadge: View {
    let state: AppState
    var body: some View {
        if let c = state.activeTab?.connection ?? state.selectedConnection {
            HStack(spacing: 6) {
                ConnDot(color: c.color, size: 8)
                Text(c.name).fontWeight(.medium).lineLimit(1)
                Text(c.readOnly ? "RO" : "RW")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(c.readOnly ? Color.secondary.opacity(0.2) : Color.red.opacity(0.85), in: Capsule())
                    .foregroundStyle(c.readOnly ? Color.secondary : Color.white)
                EnvPill(env: c.env)
            }
            .help("\(c.name) · \(c.dialect.title) · \(c.readOnly ? "read-only" : "READ-WRITE")")
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
                Text([c.name, c.dialect == .sqlite ? nil : c.database, c.dialect.title].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .frame(height: 24)
    }

    @ViewBuilder private var left: some View {
        if let t = state.activeTab {
            if t.exporting {
                ProgressView().controlSize(.mini)
                Text("Exporting… ").foregroundStyle(.secondary)
            } else if t.saving {
                ProgressView().controlSize(.mini)
                Text("Saving… ").foregroundStyle(.secondary)
            } else if t.running {
                ProgressView().controlSize(.mini)
                TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                    let secs = max(0, ctx.date.timeIntervalSince(t.runStart ?? ctx.date))
                    Text("Running… \(String(format: "%.1f", secs)) s").monospacedDigit().foregroundStyle(.secondary)
                }
            } else if let e = t.error {
                Text(e.split(separator: "\n").first.map(String.init) ?? e).foregroundStyle(.red).lineLimit(1)
            } else if let r = t.result {
                if let a = r.affected {
                    Text("\(a) row(s) affected · \(formatElapsed(r.elapsed))").monospacedDigit()
                } else {
                    Text("\(r.rows.count) rows · \(r.columns.count) cols · \(formatElapsed(r.elapsed))").monospacedDigit()
                    if r.truncated {
                        Text(t.isQuery ? "· truncated to LIMIT — add WHERE or raise limit" : "· more rows — use › or raise limit")
                            .foregroundStyle(.orange)
                    }
                }
                if let n = t.note { Text("· \(n)").foregroundStyle(.secondary) }
            } else {
                Text(t.note ?? "Ready").foregroundStyle(.secondary)
            }
            if let h = t.hint { Text(h).foregroundStyle(.orange).lineLimit(1) }
        } else {
            Text(state.status.isEmpty ? "Ready" : state.status).foregroundStyle(state.status.isEmpty ? .secondary : Color.red).lineLimit(1)
        }
    }
}

/// Confirmation / error alerts and the export table-name sheet of the edit & export features.
struct EditAlerts: ViewModifier {
    @Bindable var state: AppState

    func body(content: Content) -> some View {
        content
            .alert(saveTitle, isPresented: Binding(get: { state.pendingSave != nil }, set: { if !$0 { state.pendingSave = nil } }),
                   presenting: state.pendingSave) { t in
                Button("Save", role: .destructive) { state.pendingSave = nil; Task { await state.save(t) } }
                Button("Cancel", role: .cancel) { state.pendingSave = nil }
            } message: { t in
                Text("All changes to \(t.tableName ?? "this table") run in one transaction on a production connection.")
            }
            .alert(discardTitle, isPresented: Binding(get: { state.pendingDiscard != nil }, set: { if !$0 { state.pendingDiscard = nil } }),
                   presenting: state.pendingDiscard) { p in
                Button("Discard", role: .destructive) { state.pendingDiscard = nil; p.tab.clearPending(); p.action() }
                Button("Cancel", role: .cancel) { state.pendingDiscard = nil }
            } message: { p in
                Text("Pending edits to \(p.tab.tableName ?? "this table") have not been saved.")
            }
            .alert(state.alert?.title ?? "", isPresented: Binding(get: { state.alert != nil }, set: { if !$0 { state.alert = nil } }),
                   presenting: state.alert) { _ in
                Button("OK", role: .cancel) { state.alert = nil }
            } message: { a in
                Text(String(a.message.prefix(1200)))
            }
            .sheet(item: $state.exportPrompt) { p in ExportTableSheet(state: state, prompt: p) }
    }

    private var saveTitle: String {
        guard let t = state.pendingSave else { return "" }
        return "Save \(plural(t.pendingCount, "change")) to PRODUCTION (\(t.connection.name))?"
    }

    private var discardTitle: String {
        guard let p = state.pendingDiscard else { return "" }
        return "Discard \(plural(p.tab.pendingCount, "unsaved change"))?"
    }
}
