import SwiftUI
import RowbaseCore

extension AppState {
    /// Run button / Return in a filter field: queries run the statement, table tabs reload from the first page.
    func runTab(_ tab: WorkTab) {
        if tab.isQuery { run(tab); return }
        guardPending(tab) { [self] in
            tab.offset = 0
            Task { await loadTable(tab) }
        }
    }
}

/// Window toolbar: sidebar toggle · connection · database | Run/Stop · New query · History · Inspector.
struct AppToolbar: ToolbarContent {
    let state: AppState

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { state.toggleSidebar() } label: { Image(systemName: "sidebar.left") }
                .help("Toggle Sidebar (⌥⌘S)")
        }
        ToolbarItem(placement: .navigation) { ConnectionMenu(state: state) }
        ToolbarItem(placement: .navigation) { DatabaseMenu(state: state) }
        ToolbarItemGroup(placement: .primaryAction) {
            if let t = state.activeTab, t.running {
                Button { state.cancel(t) } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Stop the running query (⌘.)")
            } else {
                Button { if let t = state.activeTab { state.runTab(t) } } label: { Label("Run", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.activeTab == nil)
                    .help("Run (⌘↩)")
            }
            Button { state.openQuery() } label: { Image(systemName: "plus") }
                .disabled(state.selectedConnection == nil)
                .help("New Query (⌘T)")
            Button { state.showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                .help("History (⌘Y)")
            Button { state.toggleInspector() } label: { Image(systemName: "sidebar.right") }
                .help("Toggle Inspector (⌘I)")
        }
    }
}

struct ConnectionMenu: View {
    let state: AppState

    private var groups: [(String?, [Connection])] {
        let ungrouped = state.connections.filter { ($0.group ?? "").isEmpty }
        var names: [String] = []
        for c in state.connections { if let g = c.group, !g.isEmpty, !names.contains(g) { names.append(g) } }
        var out: [(String?, [Connection])] = []
        if !ungrouped.isEmpty { out.append((nil, ungrouped)) }
        for g in names { out.append((g, state.connections.filter { $0.group == g })) }
        return out
    }

    @State private var open = false

    var body: some View {
        let c = state.selectedConnection
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                if let c {
                    ConnDot(color: c.color, size: 8)
                    Text(c.name).fontWeight(.medium).lineLimit(1)
                    EnvPill(env: c.env)
                    AccessPill(readOnly: c.readOnly)
                } else {
                    Image(systemName: "externaldrive").foregroundStyle(.secondary)
                    Text("No connection").foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }
            .fixedSize()
        }
        .help(c.map { "\($0.name) · \($0.dialect.title) · \($0.readOnly ? "read-only" : "READ-WRITE") — switch connection" } ?? "Connections")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                    if let name = g.0 { SectionLabel(title: name).padding(.horizontal, 8).padding(.top, 6) }
                    ForEach(g.1) { item($0) }
                }
                if !state.connections.isEmpty { Divider().padding(.vertical, 4) }
                Button { open = false; state.showConnections = true } label: {
                    HStack { Text("Manage Connections…"); Spacer(); Text("⇧⌘K").foregroundStyle(.secondary) }
                        .padding(.horizontal, 8).frame(height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            .padding(6).frame(width: 260)
        }
    }

    private func item(_ c: Connection) -> some View {
        Button { open = false; state.selectConnection(c.id) } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                    .opacity(c.id == state.selectedConnectionID ? 1 : 0).frame(width: 12)
                ConnDot(color: c.color, size: 8)
                Text(c.name).lineLimit(1)
                Spacer(minLength: 4)
                EnvPill(env: c.env)
                AccessPill(readOnly: c.readOnly, short: true)
            }
            .padding(.horizontal, 8).frame(height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Database switcher: lists server databases; the choice overrides the connection's configured database.
struct DatabaseMenu: View {
    let state: AppState

    var body: some View {
        if let c = state.selectedConnection, c.dialect != .sqlite {
            let configured = state.connections.first { $0.id == c.id }?.database
            let user = state.databases.filter { !Catalog.systemDatabases.contains($0) }
            let system = state.databases.filter { Catalog.systemDatabases.contains($0) }
            Menu {
                if let configured, !configured.isEmpty {
                    Button("Default (\(configured))") { state.selectDatabase(nil) }
                    Divider()
                }
                ForEach(user, id: \.self) { db in dbButton(db, current: c.database) }
                if !system.isEmpty {
                    Section("System") { ForEach(system, id: \.self) { db in dbButton(db, current: c.database) } }
                }
                if state.databases.isEmpty { Text("No databases visible") }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "cylinder").foregroundStyle(.secondary)
                    Text(c.database ?? state.currentDatabase ?? "Choose database…")
                        .foregroundStyle(state.needsDatabase ? Color.accentColor : .primary).lineLimit(1)
                }
                .fixedSize()
            }
            .fixedSize()
            .help("Switch database")
        }
    }

    private func dbButton(_ db: String, current: String?) -> some View {
        Button { state.selectDatabase(db) } label: {
            if db == current { Label(db, systemImage: "checkmark") } else { Text(db) }
        }
    }
}
