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
                tableList
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
        // snapshots (cacheDisplay) cannot capture vibrancy/glass → opaque background so content is verifiable
        .background(isSnapshot ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial))
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

            if let c = state.selectedConnection {
                if c.readOnly {
                    Label("Read-only", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("READ-WRITE", systemImage: "pencil").font(.caption.weight(.bold)).foregroundStyle(.red)
                }
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
