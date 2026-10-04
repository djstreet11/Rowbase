import SwiftUI
import AppKit
import RowbaseCore

@MainActor
enum SQLHighlighter {
    static let keywords: Set<String> = Set("""
    SELECT FROM WHERE AND OR NOT IN IS NULL LIKE ILIKE BETWEEN EXISTS JOIN LEFT RIGHT INNER OUTER CROSS ON USING AS ORDER GROUP BY HAVING LIMIT OFFSET DISTINCT UNION ALL CASE WHEN THEN ELSE END ASC DESC WITH SHOW EXPLAIN ANALYZE INSERT INTO VALUES UPDATE SET DELETE CREATE ALTER DROP TABLE INDEX VIEW RETURNING TRUE FALSE INTERVAL
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

    private static func make(_ hash: Bool) -> NSRegularExpression {
        let comment = hash ? #"--[^\n]*|#[^\n]*"# : #"--[^\n]*"#
        let p = "(\(comment)|/\\*[\\s\\S]*?(?:\\*/|\\z))|('(?:[^'\\\\]|\\\\[\\s\\S]|'')*(?:'|\\z))|(\\b\\d+(?:\\.\\d+)?\\b)|(\\b[A-Za-z_][A-Za-z_0-9]*\\b)"
        return try! NSRegularExpression(pattern: p)
    }
    static let plain = make(false)
    static let mysql = make(true)

    static let baseFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let boldFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)

    static func apply(to storage: NSTextStorage, dialect: Dialect) {
        let text = storage.string
        let full = NSRange(location: 0, length: (text as NSString).length)
        storage.beginEditing()
        storage.setAttributes([.font: baseFont, .foregroundColor: NSColor.labelColor], range: full)
        let re = dialect == .mysql ? mysql : plain
        let ns = text as NSString
        re.enumerateMatches(in: text, range: full) { m, _, _ in
            guard let m else { return }
            if m.range(at: 1).location != NSNotFound {
                storage.addAttribute(.foregroundColor, value: NSColor.systemGray, range: m.range(at: 1))
            } else if m.range(at: 2).location != NSNotFound {
                storage.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: m.range(at: 2))
            } else if m.range(at: 3).location != NSNotFound {
                storage.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: m.range(at: 3))
            } else if m.range(at: 4).location != NSNotFound, keywords.contains(ns.substring(with: m.range(at: 4)).uppercased()) {
                storage.addAttributes([.foregroundColor: NSColor.systemPurple, .font: boldFont], range: m.range(at: 4))
            }
        }
        storage.endEditing()
    }
}

final class SQLTextView: NSTextView {
    var completer: Completer?

    override func keyDown(with event: NSEvent) {
        if let c = completer, c.isOpen {
            switch event.keyCode {
            case 125: c.move(1); return                       // down
            case 126: c.move(-1); return                      // up
            case 36, 76:                                      // return / enter
                if event.modifierFlags.intersection([.command, .control]).isEmpty { c.acceptSelected(); return }
                c.close()
            case 48: c.acceptSelected(); return               // tab
            case 53: c.close(); return                        // esc
            case 123, 124, 115, 119, 116, 121: c.close()      // caret moves
            default: break
            }
        }
        if event.keyCode == 49, event.modifierFlags.contains(.control), let c = completer {  // ctrl+space
            c.update(force: true)
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.keyCode == 36 || event.keyCode == 76 { completer?.close() }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        completer?.close()
        super.mouseDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        completer?.close()
        return super.resignFirstResponder()
    }
}

struct SQLEditor: NSViewRepresentable {
    let tab: WorkTab
    let state: AppState

    func makeCoordinator() -> Coordinator { Coordinator(tab: tab) }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = true
        sv.borderType = .noBorder
        sv.drawsBackground = true
        sv.backgroundColor = .textBackgroundColor
        let tv = SQLTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        sv.documentView = tv
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = SQLHighlighter.baseFont
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.isHorizontallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: 1_000_000, height: 1_000_000)
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.typingAttributes = [.font: SQLHighlighter.baseFont, .foregroundColor: NSColor.labelColor]
        tv.string = tab.sql
        SQLHighlighter.apply(to: tv.textStorage!, dialect: tab.connection.dialect)
        let completer = Completer(tab: tab, state: state)
        completer.tv = tv
        tv.completer = completer
        context.coordinator.completer = completer
        context.coordinator.textView = tv
        tab.editor = tv
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? NSTextView else { return }
        context.coordinator.tab = tab
        if tv.string != tab.sql {
            tv.string = tab.sql
            SQLHighlighter.apply(to: tv.textStorage!, dialect: tab.connection.dialect)
        }
    }

    static func dismantleNSView(_ sv: NSScrollView, coordinator: Coordinator) {
        MainActor.assumeIsolated { coordinator.completer?.close() }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var tab: WorkTab
        weak var textView: NSTextView?
        var completer: Completer?
        init(tab: WorkTab) { self.tab = tab }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            completer?.lastChangeLen = (replacementString as NSString?)?.length ?? 0
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            tab.sql = tv.string
            if !tv.hasMarkedText() { SQLHighlighter.apply(to: tv.textStorage!, dialect: tab.connection.dialect) }
            guard let c = completer else { return }
            if c.skipNext { c.skipNext = false; return }
            if c.lastChangeLen > 1 { c.close(); return }                   // paste / multi-char edit
            if c.lastChangeLen == 0 { if c.isOpen { c.update(force: false) }; return }  // deletion
            c.update(force: false)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if let tv = notification.object as? NSTextView { tab.selection = tv.selectedRange() }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                textView.insertText("  ", replacementRange: textView.selectedRange())
                return true
            }
            return false
        }
    }
}
