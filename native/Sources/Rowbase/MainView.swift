import SwiftUI
import RowbaseCore

struct MainView: View {
    @Bindable var state: AppState

    var body: some View {
        ThreePaneSplit(showSidebar: state.showSidebar, showInspector: state.showInspector,
                       sidebar: SidebarView(state: state),
                       detail: DetailView(state: state),
                       inspector: RowInspector(state: state, tab: state.activeTab))
        .toolbar { AppToolbar(state: state) }
        .navigationTitle(state.activeTab?.title ?? "Rowbase")
        .navigationSubtitle(subtitle)
        .sheet(isPresented: $state.showConnections) { ConnectionsSheet(state: state) }
        .sheet(isPresented: $state.showAIMCP) { AIMCPSheet(state: state) }
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

    private var subtitle: String {
        guard let c = state.selectedConnection else { return "" }
        let db = c.dialect == .sqlite ? nil : (c.database ?? state.currentDatabase)
        return [c.name, db].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
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
                    EmptyTabState()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            StatusBar(state: state)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct EmptyTabState: View {
    private let shortcuts: [(String, String)] = [("⌘P", "Find table"), ("⌘T", "New query"), ("⇧⌘K", "Connections"), ("⌘Y", "History")]

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "cylinder.split.1x2").font(.system(size: 48, weight: .light)).foregroundStyle(.tertiary)
            Text("No table open").font(.title3.weight(.medium))
            Text("Pick a table in the sidebar or start a new query.").font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(shortcuts, id: \.0) { k, label in
                    HStack(spacing: 12) {
                        Text(k).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                        Text(label).font(.callout)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(width: 220)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor).opacity(0.6)))
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct StatusBar: View {
    let state: AppState
    @State private var showSQL = false

    var body: some View {
        HStack(spacing: 8) {
            left
            Spacer(minLength: 8)
            if let t = state.activeTab, !t.isQuery {
                Button { showSQL.toggle() } label: { Image(systemName: "info.circle").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help(t.buildSQL())
                    .popover(isPresented: $showSQL, arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Generated SQL").font(.caption).foregroundStyle(.secondary)
                            Text(t.buildSQL()).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: 480, alignment: .leading)
                            HStack {
                                Button("Copy") { copyToPasteboard(t.buildSQL()) }
                                Button("Open in SQL Editor") { showSQL = false; state.openQuery(sql: t.buildSQL(), connection: t.connection) }
                            }.controlSize(.small)
                        }.padding(12)
                    }
            }
            if let c = state.activeTab?.connection ?? state.selectedConnection {
                AccessPill(readOnly: c.readOnly)
                ConnDot(color: c.color, size: 7)
                    .help([c.name, c.dialect == .sqlite ? nil : c.database, c.dialect.title].compactMap { $0 }.joined(separator: " · "))
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(Color(nsColor: .windowBackgroundColor))
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
                if !t.isQuery && !t.isExplain { pager(t, r) }
                if let a = r.affected {
                    Text("\(a) row(s) affected · \(formatMs(r.elapsed))").monospacedDigit()
                } else {
                    Text("\(plural(r.rows.count, "row")) · \(plural(r.columns.count, "col")) · \(formatMs(r.elapsed))").monospacedDigit()
                    if r.truncated {
                        Text(t.isQuery ? "truncated to LIMIT — add WHERE or raise limit" : "more rows")
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

    @ViewBuilder private func pager(_ t: WorkTab, _ r: QueryResult) -> some View {
        let n = r.rows.count
        HStack(spacing: 2) {
            Button { state.page(t, by: -1) } label: { Image(systemName: "chevron.left").frame(width: 16, height: 16).contentShape(Rectangle()) }
                .buttonStyle(.plain).disabled(t.offset == 0 || t.running).help("Previous page")
            Text(n == 0 ? "0" : "\(t.offset + 1)–\(t.offset + n)").monospacedDigit().foregroundStyle(.secondary)
            Button { state.page(t, by: 1) } label: { Image(systemName: "chevron.right").frame(width: 16, height: 16).contentShape(Rectangle()) }
                .buttonStyle(.plain).disabled(!t.hasMore || t.running).help("Next page")
        }
        Divider().frame(height: 12)
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
