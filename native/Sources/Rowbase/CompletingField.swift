import SwiftUI
import AppKit
import RowbaseCore

/// Single-line SQL fragment field (WHERE / ORDER BY) with the editor's completion popup.
/// Enter accepts the highlighted suggestion while the popup is open, otherwise submits.
struct CompletingField: NSViewRepresentable {
    enum Mode { case whereClause, orderBy }

    @Binding var text: String
    let placeholder: String
    let mode: Mode
    let tab: WorkTab
    let state: AppState
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField(string: text)
        f.placeholderString = placeholder
        f.isBezeled = true
        f.bezelStyle = .roundedBezel
        f.controlSize = .small
        f.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        f.lineBreakMode = .byClipping
        f.usesSingleLineMode = true
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        f.delegate = context.coordinator
        context.coordinator.field = f
        if mode == .whereClause {
            tab.whereField = f
            tab.whereCompleter = context.coordinator.completer
        }
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
        if f.placeholderString != placeholder { f.placeholderString = placeholder }
    }

    static func dismantleNSView(_ f: NSTextField, coordinator: Coordinator) {
        MainActor.assumeIsolated { coordinator.completer.close() }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CompletingField
        weak var field: NSTextField?
        let completer: Completer
        private var lastLen = 0

        init(_ p: CompletingField) {
            parent = p
            completer = Completer(tab: p.tab, state: p.state)
            super.init()
            let mode = p.mode
            completer.custom = { [weak self] ctx, valueOnly in await self?.suggestions(ctx, valueOnly: valueOnly, mode: mode) }
            lastLen = (p.text as NSString).length
        }

        private func columns() async -> [ColumnInfo]? {
            let tab = parent.tab
            if let i = tab.info { return i.columns }
            guard let t = tab.tableName else { return nil }
            return (try? await parent.state.tableInfo(for: tab.connection, table: t))?.columns
        }

        private func suggestions(_ c: CompletionContext, valueOnly: Bool, mode: Mode) async -> [CompletionItem]? {
            guard let cols = await columns() else { return nil }
            let d = parent.tab.connection.dialect
            let colItems = cols.map { CompletionItem(label: $0.name, kind: .column, detail: $0.type) }
            if mode == .orderBy {
                if valueOnly || c.inString { return nil }
                return colItems + ["ASC", "DESC"].map { CompletionItem(label: $0, kind: .keyword) }
            }
            let beforeWord = (c.before as NSString).substring(to: max(0, (c.before as NSString).length - (c.prefix as NSString).length))
            if c.inString {
                if valueOnly { return nil }
                return CompletionLogic.valueItems(before: beforeWord, columns: cols, quoted: true, dialect: d) ?? []
            }
            if c.qual != nil { return valueOnly ? nil : colItems }
            let vals = CompletionLogic.valueItems(before: beforeWord, columns: cols, quoted: false, dialect: d)
            if valueOnly { return vals }
            if let vals, c.prefix.isEmpty { return vals }
            let kws = ["AND", "OR", "NOT"].map { CompletionItem(label: $0, kind: .keyword) }
                + CompletionLogic.whereKeywords
                + ["BETWEEN", "CURDATE()", "INTERVAL", "DAY", "HOUR", "REGEXP"].map { CompletionItem(label: $0, kind: .keyword) }
            let fns = CompletionLogic.functions.map { CompletionItem(label: $0, insert: $0 + "()", kind: .function, detail: "function", back: 1) }
            return (vals ?? []) + colItems + kws + fns
        }

        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSTextField else { return }
            if let tv = n.userInfo?["NSFieldEditor"] as? NSTextView { completer.tv = tv }
            if parent.text != f.stringValue { parent.text = f.stringValue }
            let len = (f.stringValue as NSString).length
            let delta = len - lastLen
            lastLen = len
            if completer.skipNext { completer.skipNext = false; return }
            if delta > 1 { completer.close(); return }                       // paste / completion insert
            if delta <= 0 { if completer.isOpen { completer.update(force: false) }; return }
            completer.update(force: false)
        }

        func controlTextDidEndEditing(_ n: Notification) { completer.close() }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            completer.tv = textView
            let open = completer.isOpen
            switch sel {
            case #selector(NSResponder.moveDown(_:)) where open: completer.move(1); return true
            case #selector(NSResponder.moveUp(_:)) where open: completer.move(-1); return true
            case #selector(NSResponder.insertNewline(_:)):
                if open { completer.acceptSelected() } else { parent.onSubmit() }
                return true
            case #selector(NSResponder.insertTab(_:)) where open: completer.acceptSelected(); return true
            case #selector(NSResponder.cancelOperation(_:)) where open: completer.close(); return true
            case #selector(NSResponder.complete(_:)): completer.update(force: true); return true
            case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)),
                 #selector(NSResponder.moveToBeginningOfLine(_:)), #selector(NSResponder.moveToEndOfLine(_:)):
                completer.close()
            default: break
            }
            return false
        }
    }
}
