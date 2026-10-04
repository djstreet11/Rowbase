import SwiftUI
import RowbaseCore

struct TabBarView: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(state.tabs) { tab in
                        TabItem(state: state, tab: tab, active: tab.id == state.activeTabID)
                    }
                }
                .padding(.horizontal, 6)
            }
            Button { state.openQuery() } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless).help("New SQL Tab (⌘T)")
                .disabled(state.selectedConnection == nil)
                .padding(.horizontal, 8)
        }
        .frame(height: 30)
        .background(.bar)
    }
}

private struct TabItem: View {
    let state: AppState
    let tab: WorkTab
    let active: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: tab.isQuery ? "terminal" : "tablecells")
                .font(.caption).foregroundStyle(.secondary)
            Text(tab.title).font(.callout).lineLimit(1).truncationMode(.tail)
            if tab.connection.id != state.selectedConnectionID {
                Text(tab.connection.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Button { state.requestClose(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.borderless)
                .opacity(hover || active ? 1 : 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(maxWidth: 260)
        .background(active ? Color.primary.opacity(0.12) : (hover ? Color.primary.opacity(0.06) : .clear), in: RoundedRectangle(cornerRadius: 6))
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
