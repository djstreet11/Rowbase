import SwiftUI
import RowbaseCore

struct TableTabView: View {
    let state: AppState
    @Bindable var tab: WorkTab

    var body: some View {
        VStack(spacing: 0) {
            if !tab.breadcrumbs.isEmpty { crumbs; Divider() }
            toolbar
            Divider()
            if tab.canEdit { PendingStrip(state: state, tab: tab) }
            if tab.showStructure {
                StructureView(state: state, tab: tab)
            } else {
                ResultArea(state: state, tab: tab)
            }
        }
        .sheet(item: $tab.editSheet) { ref in CellEditSheet(tab: tab, ref: ref) }
        .sheet(isPresented: Binding(get: { tab.previewStatements != nil }, set: { if !$0 { tab.previewStatements = nil } })) {
            SQLPreviewSheet(statements: tab.previewStatements ?? [])
        }
    }

    private var crumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(tab.breadcrumbs) { c in
                    Button(c.title) { state.openCrumb(c, from: tab) }.buttonStyle(.link)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    if let v = c.via { Text("via \(v)").font(.caption).foregroundStyle(.secondary) }
                    if c.via != nil { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                }
                Text(tab.title).fontWeight(.medium)
            }
            .font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            ModeSegment(structure: $tab.showStructure)
            SQLFilterField(text: $tab.whereText, placeholder: "Filter — WHERE …", icon: "line.3.horizontal.decrease",
                           mode: .whereClause, tab: tab, state: state, onSubmit: apply)
                .frame(minWidth: 120, maxWidth: .infinity)
            SQLFilterField(text: $tab.orderText, placeholder: tab.defaultOrder.isEmpty ? "Order by" : tab.defaultOrder, icon: nil,
                           mode: .orderBy, tab: tab, state: state, onSubmit: apply)
                .frame(minWidth: 100, idealWidth: 180, maxWidth: 180)
            LimitMenu(limit: $tab.limit, options: [50, 100, 500, 1000], onChange: apply)
            Spacer(minLength: 0).frame(width: 0)
            if tab.canEdit {
                IconButton(symbol: "plus", help: "Add an empty row at the top (saved with Save)") { tab.addInsertRow() }
                IconButton(symbol: "trash", help: "Mark the selected rows for deletion") { tab.deleteSelected() }
                    .disabled(!tab.hasSelection)
                Divider().frame(height: 14)
            }
            IconButton(symbol: "rectangle.split.2x1", help: tab.transpose ? "Back to grid" : "Transpose: rows become columns",
                       active: tab.transpose) { tab.transpose.toggle() }
            ColumnsButton(tab: tab)
            ExportMenu(state: state, tab: tab)
            MoreMenu(state: state, tab: tab)
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    private func apply() { state.runTab(tab) }
}

/// Data / Structure switch as two icon segments with tooltips.
struct ModeSegment: View {
    @Binding var structure: Bool

    var body: some View {
        HStack(spacing: 1) {
            seg("tablecells", "Data", on: !structure) { structure = false }
            seg("list.bullet.rectangle", "Structure", on: structure) { structure = true }
        }
        .padding(1)
        .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 6))
    }

    private func seg(_ symbol: String, _ help: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
                .foregroundStyle(on ? Color.primary : Color.secondary)
                .frame(width: 28, height: 20)
                .background(on ? Color(nsColor: .controlBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(on ? Color(nsColor: .separatorColor) : .clear, lineWidth: 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }
}

/// Borderless "100 ▾" row-limit menu.
struct LimitMenu: View {
    @Binding var limit: Int
    let options: [Int]
    var onChange: () -> Void

    var body: some View {
        Menu {
            Picker("Limit", selection: $limit) {
                ForEach(options, id: \.self) { Text("\($0) rows").tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 3) {
                Text("\(limit)").monospacedDigit()
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .frame(height: 22).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .fixedSize()
        .onChange(of: limit) { onChange() }
        .help("Rows per page")
    }
}

/// Flat rounded field container around the completing text field (focus = accent outline).
struct SQLFilterField: View {
    @Binding var text: String
    let placeholder: String
    let icon: String?
    let mode: CompletingField.Mode
    let tab: WorkTab
    let state: AppState
    var onSubmit: () -> Void
    @State private var focused = false

    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary) }
            CompletingField(text: $text, placeholder: placeholder, mode: mode, tab: tab, state: state, onSubmit: onSubmit,
                            onFocus: { v in DispatchQueue.main.async { focused = v } })
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(focused ? Color.accentColor.opacity(0.9) : Color(nsColor: .separatorColor), lineWidth: focused ? 1.5 : 1))
    }
}
