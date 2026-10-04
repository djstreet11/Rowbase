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
                searchField
                if state.needsDatabase { databaseChooser } else { tableList }
            }
            Divider()
            HStack(spacing: 4) {
                Button { state.showConnections = true } label: { Image(systemName: "plus").frame(width: 22, height: 20).contentShape(Rectangle()) }
                    .buttonStyle(.borderless).help("New Connection")
                Button { state.showConnections = true } label: {
                    Label("Connections", systemImage: "externaldrive.connected.to.line.below")
                }
                .buttonStyle(.borderless).help("Manage Connections (⇧⌘K)")
                Spacer()
                if state.tablesLoading { ProgressView().controlSize(.mini) }
            }
            .controlSize(.small)
            .padding(.horizontal, 8).frame(height: 28)
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

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("Search tables", text: $state.tableFilter)
                .textFieldStyle(.plain).focused($filterFocused)
                .onSubmit { if let f = state.filteredTables.first { state.openTable(f.name) } }
            if !state.tableFilter.isEmpty {
                Button { state.tableFilter = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).help("Clear")
            }
            kindMenu
        }
        .font(.callout)
        .padding(.horizontal, 8).frame(height: 24)
        .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    /// All / Tables / Views filter (persisted).
    private var kindMenu: some View {
        Menu {
            Picker("Show", selection: $state.kindFilter) {
                Text("All").tag("all")
                Text("Tables").tag("table")
                Text("Views").tag("view")
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: state.kindFilter == "all" ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(state.kindFilter == "all" ? Color.secondary : Color.accentColor)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Show: \(state.kindFilter == "all" ? "all" : state.kindFilter == "table" ? "tables only" : "views only")")
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
        let all = state.filteredTables
        let tables = all.filter { !$0.isView }, views = all.filter(\.isView)
        return List(selection: Binding<String?>(
            get: {
                guard let t = state.activeTab, t.connection.id == state.selectedConnectionID else { return nil }
                return t.tableName
            },
            set: { if let n = $0 { state.openTable(n) } }
        )) {
            if !tables.isEmpty {
                Section { ForEach(tables) { row($0) } } header: { SectionLabel(title: "Tables", count: tables.count) }
            }
            if !views.isEmpty {
                Section { ForEach(views) { row($0) } } header: { SectionLabel(title: "Views", count: views.count) }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .overlay {
            if state.tables.isEmpty && !state.tablesLoading {
                Text(state.status.isEmpty ? "No tables" : state.status).font(.caption).foregroundStyle(.secondary).padding()
            } else if all.isEmpty && !state.tablesLoading {
                Text("No matches").font(.caption).foregroundStyle(.secondary).padding()
            }
        }
    }

    private func row(_ t: TableEntry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: t.isView ? "eye" : "tablecells")
                .font(.system(size: 12))
                .foregroundStyle(t.isView ? Color.purple : Color.accentColor).frame(width: 16)
            Text(t.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if let n = t.rows {
                Text(compactCount(n)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .help(n.formatted() + " rows")
            }
        }
        .frame(height: 24)
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .tag(t.name)
    }
}
