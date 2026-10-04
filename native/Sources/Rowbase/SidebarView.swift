import SwiftUI
import RowbaseCore

struct SidebarView: View {
    @Bindable var state: AppState
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if state.connections.isEmpty {
                emptyState
            } else {
                header
                if state.needsDatabase { databaseChooser } else { tableList }
            }
            Divider()
            HStack {
                Button { state.showConnections = true } label: { Label("Connections…", systemImage: "externaldrive.connected.to.line.below") }
                    .buttonStyle(.borderless).controlSize(.small)
                Spacer()
                if state.tablesLoading { ProgressView().controlSize(.mini) }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: state.filterFocusTick) { filterFocused = true }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "externaldrive.badge.plus").font(.system(size: 36)).foregroundStyle(.secondary)
            Button("Add your first connection") { state.showConnections = true }
                .controlSize(.large).buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                ForEach(state.connections) { c in
                    Button { state.selectConnection(c.id) } label: {
                        Text(c.env.map { "\(c.name)  [\($0)]" } ?? c.name)
                    }
                }
                Divider()
                Button("Connections…") { state.showConnections = true }
            } label: {
                HStack(spacing: 6) {
                    ConnDot(color: state.selectedConnection?.color)
                    Text(state.selectedConnection?.name ?? "Select connection").fontWeight(.medium).lineLimit(1)
                    EnvPill(env: state.selectedConnection?.env)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)

            if let c = state.selectedConnection, c.dialect != .sqlite { databaseMenu(c) }
            if let c = state.selectedConnection, !c.readOnly {
                Label("READ-WRITE", systemImage: "pencil").font(.caption.weight(.bold)).foregroundStyle(.red)
            }
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter tables", text: $state.tableFilter)
                    .textFieldStyle(.plain).focused($filterFocused)
                    .onSubmit { if let f = state.filteredTables.first { state.openTable(f.name) } }
                if !state.tableFilter.isEmpty {
                    Button { state.tableFilter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(8)
    }

    /// Database switcher: lists server databases; the choice overrides the connection's configured database.
    private func databaseMenu(_ c: Connection) -> some View {
        let configured = state.connections.first { $0.id == c.id }?.database
        let user = state.databases.filter { !Catalog.systemDatabases.contains($0) }
        let system = state.databases.filter { Catalog.systemDatabases.contains($0) }
        return Menu {
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
            HStack(spacing: 6) {
                Image(systemName: "cylinder.split.1x2").foregroundStyle(.secondary).frame(width: 16)
                Text(c.database ?? state.currentDatabase ?? "Choose database…")
                    .foregroundStyle(state.needsDatabase ? Color.accentColor : .primary).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .font(.callout).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .help("Switch database")
    }

    private func dbButton(_ db: String, current: String?) -> some View {
        Button { state.selectDatabase(db) } label: {
            if db == current { Label(db, systemImage: "checkmark") } else { Text(db) }
        }
    }

    /// Shown instead of the table list when a MySQL connection has no database yet.
    private var databaseChooser: some View {
        List {
            Section("Choose a database") {
                ForEach(state.databases, id: \.self) { db in
                    Button { state.selectDatabase(db) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "cylinder").foregroundStyle(.secondary).frame(width: 16)
                            Text(db).foregroundStyle(Catalog.systemDatabases.contains(db) ? .secondary : .primary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .overlay { if state.databases.isEmpty && !state.tablesLoading { Text("No databases visible").font(.caption).foregroundStyle(.secondary) } }
    }

    private var tableList: some View {
        List(selection: Binding<String?>(
            get: {
                guard let t = state.activeTab, t.connection.id == state.selectedConnectionID else { return nil }
                return t.tableName
            },
            set: { if let n = $0 { state.openTable(n) } }
        )) {
            ForEach(state.filteredTables) { t in
                HStack(spacing: 6) {
                    Image(systemName: t.isView ? "eye" : "tablecells").foregroundStyle(.secondary).frame(width: 16)
                    Text(t.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let n = t.rows {
                        Text(n.formatted()).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .tag(t.name)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .overlay {
            if state.tables.isEmpty && !state.tablesLoading {
                Text(state.status.isEmpty ? "No tables" : state.status).font(.caption).foregroundStyle(.secondary).padding()
            }
        }
    }
}
