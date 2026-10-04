import SwiftUI
import AppKit

/// Flat three-pane layout (sidebar | detail | inspector) on a plain NSSplitView:
/// no glass, no shadows, panes separated by the thin divider. Sidebar and inspector can be hidden.
struct ThreePaneSplit<S: View, D: View, I: View>: NSViewRepresentable {
    let showSidebar: Bool
    let showInspector: Bool
    let sidebar: S
    let detail: D
    let inspector: I

    static var sidebarRange: ClosedRange<CGFloat> { 200...400 }
    static var inspectorRange: ClosedRange<CGFloat> { 260...480 }
    static var detailMin: CGFloat { 360 }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSplitView {
        let c = context.coordinator
        let sv = NSSplitView()
        sv.isVertical = true
        sv.dividerStyle = .thin
        sv.delegate = c
        func host<V: View>(_ v: V) -> NSHostingView<V> {
            let h = NSHostingView(rootView: v)
            h.sizingOptions = []
            return h
        }
        let sb = host(sidebar), dt = host(detail), ins = host(inspector)
        c.sidebarHost = sb; c.detailHost = dt; c.inspectorHost = ins
        c.split = sv
        c.apply(showSidebar: showSidebar, showInspector: showInspector)
        return sv
    }

    func updateNSView(_ sv: NSSplitView, context: Context) {
        let c = context.coordinator
        c.sidebarHost?.rootView = sidebar
        c.detailHost?.rootView = detail
        c.inspectorHost?.rootView = inspector
        c.apply(showSidebar: showSidebar, showInspector: showInspector)
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        var split: NSSplitView?
        var sidebarHost: NSHostingView<S>?
        var detailHost: NSHostingView<D>?
        var inspectorHost: NSHostingView<I>?
        var sidebarW: CGFloat = {
            let v = UserDefaults.standard.double(forKey: "rowbase.sidebarWidth"); return v >= 200 ? v : 250
        }()
        var inspectorW: CGFloat = {
            let v = UserDefaults.standard.double(forKey: "rowbase.inspectorWidth"); return v >= 260 ? v : 300
        }()

        func apply(showSidebar: Bool, showInspector: Bool) {
            guard let sv = split, let sb = sidebarHost, let dt = detailHost, let ins = inspectorHost else { return }
            var want: [NSView] = []
            if showSidebar { want.append(sb) }
            want.append(dt)
            if showInspector { want.append(ins) }
            if sv.arrangedSubviews == want { return }
            for v in sv.arrangedSubviews where !want.contains(v) { sv.removeArrangedSubview(v); v.removeFromSuperview() }
            for (i, v) in want.enumerated() where !sv.arrangedSubviews.contains(v) {
                if v === sb { v.frame.size.width = sidebarW }
                if v === ins { v.frame.size.width = inspectorW }
                sv.insertArrangedSubview(v, at: i)
            }
            sv.adjustSubviews()
        }

        // Sidebar and inspector keep their width on window resize; the detail pane absorbs the change.
        func splitView(_ sv: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
            guard let sb = sidebarHost, let dt = detailHost, let ins = inspectorHost else { return }
            let th = sv.dividerThickness
            let total = sv.bounds.width, h = sv.bounds.height
            let hasSb = sv.arrangedSubviews.contains(sb), hasIns = sv.arrangedSubviews.contains(ins)
            func fit(_ w: CGFloat, _ r: ClosedRange<CGFloat>) -> CGFloat { min(max(w < 1 ? r.lowerBound : w, r.lowerBound), r.upperBound) }
            var sw = hasSb ? fit(sb.frame.width < 1 ? sidebarW : sb.frame.width, ThreePaneSplit.sidebarRange) : 0
            var iw = hasIns ? fit(ins.frame.width < 1 ? inspectorW : ins.frame.width, ThreePaneSplit.inspectorRange) : 0
            let dividers = (hasSb ? th : 0) + (hasIns ? th : 0)
            var dw = total - sw - iw - dividers
            if dw < ThreePaneSplit.detailMin {
                var deficit = ThreePaneSplit.detailMin - dw
                let cutI = hasIns ? min(deficit, iw - ThreePaneSplit.inspectorRange.lowerBound) : 0
                iw -= max(0, cutI); deficit -= max(0, cutI)
                let cutS = hasSb ? min(deficit, sw - ThreePaneSplit.sidebarRange.lowerBound) : 0
                sw -= max(0, cutS)
                dw = total - sw - iw - dividers
            }
            var x: CGFloat = 0
            if hasSb { sb.frame = NSRect(x: 0, y: 0, width: sw, height: h); x = sw + th }
            dt.frame = NSRect(x: x, y: 0, width: max(0, dw), height: h)
            if hasIns { ins.frame = NSRect(x: x + dw + th, y: 0, width: iw, height: h) }
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard let sv = split, NSApp.currentEvent?.type == .leftMouseDragged else { return }
            if let sb = sidebarHost, sv.arrangedSubviews.contains(sb), sb.frame.width >= 200, sb.frame.width != sidebarW {
                sidebarW = sb.frame.width
                UserDefaults.standard.set(Double(sidebarW), forKey: "rowbase.sidebarWidth")
            }
            if let ins = inspectorHost, sv.arrangedSubviews.contains(ins), ins.frame.width >= 260, ins.frame.width != inspectorW {
                inspectorW = ins.frame.width
                UserDefaults.standard.set(Double(inspectorW), forKey: "rowbase.inspectorWidth")
            }
        }

        func splitView(_ sv: NSSplitView, constrainMinCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat {
            guard i < sv.arrangedSubviews.count else { return p }
            let v = sv.arrangedSubviews[i]
            if v === sidebarHost { return ThreePaneSplit.sidebarRange.lowerBound }
            let left: CGFloat = sidebarHost.map { sv.arrangedSubviews.contains($0) ? $0.frame.width + sv.dividerThickness : 0 } ?? 0
            return max(left + ThreePaneSplit.detailMin, sv.bounds.width - ThreePaneSplit.inspectorRange.upperBound - sv.dividerThickness)
        }

        func splitView(_ sv: NSSplitView, constrainMaxCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat {
            guard i < sv.arrangedSubviews.count else { return p }
            let v = sv.arrangedSubviews[i]
            let th = sv.dividerThickness
            if v === sidebarHost {
                let right: CGFloat = inspectorHost.map { sv.arrangedSubviews.contains($0) ? $0.frame.width + th : 0 } ?? 0
                return min(ThreePaneSplit.sidebarRange.upperBound, sv.bounds.width - right - ThreePaneSplit.detailMin - th)
            }
            return sv.bounds.width - ThreePaneSplit.inspectorRange.lowerBound - th
        }

        func splitView(_ sv: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    }
}
