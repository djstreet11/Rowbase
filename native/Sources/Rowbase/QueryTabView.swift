import SwiftUI
import AppKit
import RowbaseCore

struct QueryTabView: View {
    let state: AppState
    @Bindable var tab: WorkTab

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            VerticalSplit(top: SQLEditor(tab: tab, state: state).frame(maxWidth: .infinity, maxHeight: .infinity),
                          bottom: ResultPanel(state: state, tab: tab))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if tab.running {
                Button { state.cancel(tab) } label: { Label("Stop", systemImage: "stop.fill") }
                    .tint(.red).buttonStyle(.borderedProminent).help("Stop the running query (⌘.)")
            } else {
                Button { state.run(tab) } label: { Label("Run", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).help("Run statement under caret or selection (⌘↩)")
            }
            Button { state.run(tab, explain: true) } label: { Label("Explain", systemImage: "chart.bar.doc.horizontal") }
                .help("EXPLAIN the statement under the caret")
            if tab.connection.dialect != .sqlite {
                Button { state.run(tab, explain: true, analyze: true) } label: { Label("Explain Analyze", systemImage: "stopwatch") }
                    .help("EXPLAIN ANALYZE actually executes the statement")
            }
            LimitMenu(limit: $tab.limit, options: [100, 500, 1000, 5000], onChange: {})
            Spacer(minLength: 0)
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
}

/// Results header strip (24pt) + result area.
struct ResultPanel: View {
    let state: AppState
    let tab: WorkTab

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Result").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                if let r = tab.result, tab.error == nil {
                    if let a = r.affected {
                        Text("\(a) row(s) affected · \(formatMs(r.elapsed))").foregroundStyle(.secondary)
                    } else {
                        Text("\(plural(r.rows.count, "row")) · \(plural(r.columns.count, "col")) · \(formatMs(r.elapsed))")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                } else if tab.error != nil {
                    Text("Error").foregroundStyle(.red)
                }
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 10).frame(height: 24)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            ResultArea(state: state, tab: tab)
        }
    }
}

/// Flat vertical split (editor above, results below) with a visible thin divider.
struct VerticalSplit<T: View, B: View>: NSViewRepresentable {
    let top: T
    let bottom: B

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Split: NSSplitView {
        var placed = false
        override func layout() {
            super.layout()
            if !placed, bounds.height > 300 {
                placed = true
                setPosition(min(260, bounds.height * 0.45), ofDividerAt: 0)
            }
        }
    }

    func makeNSView(context: Context) -> NSSplitView {
        let sv = Split()
        sv.isVertical = false
        sv.dividerStyle = .thin
        sv.delegate = context.coordinator
        let t = NSHostingView(rootView: top), b = NSHostingView(rootView: bottom)
        t.sizingOptions = []; b.sizingOptions = []
        context.coordinator.t = t; context.coordinator.b = b
        sv.addArrangedSubview(t)
        sv.addArrangedSubview(b)
        return sv
    }

    func updateNSView(_ sv: NSSplitView, context: Context) {
        context.coordinator.t?.rootView = top
        context.coordinator.b?.rootView = bottom
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        var t: NSHostingView<T>?
        var b: NSHostingView<B>?
        func splitView(_ sv: NSSplitView, constrainMinCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat { 100 }
        func splitView(_ sv: NSSplitView, constrainMaxCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat { sv.bounds.height - 100 }
        func splitView(_ sv: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    }
}
