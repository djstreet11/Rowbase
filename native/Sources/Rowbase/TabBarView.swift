import SwiftUI
import RowbaseCore

struct TabBarView: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(state.tabs) { tab in
                        TabItem(state: state, tab: tab, active: tab.id == state.activeTabID)
                    }
                }
            }
            Button { state.openQuery() } label: {
                Image(systemName: "plus").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("New Query (⌘T)")
            .disabled(state.selectedConnection == nil)
        }
        .frame(height: 30)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct TabItem: View {
    let state: AppState
    let tab: WorkTab
    let active: Bool
    @State private var hover = false

    /// Connection / database only when the tab differs from the toolbar selection.
    private var suffix: String? {
        let sel = state.selectedConnection
        if tab.connection.id != sel?.id { return tab.connection.name }
        if tab.connection.dialect != .sqlite, let db = tab.connection.database, db != sel?.database { return db }
        return nil
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.isBuilder ? "hammer" : tab.isQuery ? "terminal" : "tablecells")
                .font(.system(size: 11)).foregroundStyle(active ? Color.accentColor : Color.secondary)
            Text(tab.title).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(active ? Color.primary : Color.secondary)
            if let suffix { Text(suffix).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1) }
            Button { state.requestClose(tab.id) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 14, height: 14).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Tab (⌘W)")
            .opacity(hover || active ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: 240, minHeight: 30, maxHeight: 30)
        .background(active ? Color(nsColor: .controlBackgroundColor) : (hover ? Color.primary.opacity(0.05) : .clear))
        .overlay(alignment: .bottom) { if active { Rectangle().fill(Color.accentColor).frame(height: 2) } }
        .overlay(alignment: .trailing) { Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.5)).frame(width: 1).padding(.vertical, 6) }
        .contentShape(Rectangle())
        .onTapGesture { state.activate(tab.id) }
        .onHover { hover = $0 }
        .overlay(MiddleClick { state.requestClose(tab.id) })
    }
}

/// Transparent overlay that reports middle mouse button clicks and lets everything else through.
private struct MiddleClick: NSViewRepresentable {
    let action: @MainActor () -> Void
    func makeNSView(context: Context) -> NSView { MiddleView() }
    func updateNSView(_ v: NSView, context: Context) { (v as? MiddleView)?.action = action }

    final class MiddleView: NSView {
        var action: (@MainActor () -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? {
            if NSApp.currentEvent?.type == .otherMouseDown || NSApp.currentEvent?.type == .otherMouseUp { return self }
            return nil
        }
        override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { action?() } }
    }
}
