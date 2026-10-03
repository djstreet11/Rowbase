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

struct SQLEditor: NSViewRepresentable {
    let tab: WorkTab

    func makeCoordinator() -> Coordinator { Coordinator(tab: tab) }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSTextView.scrollableTextView()
        sv.hasHorizontalScroller = true
        guard let tv = sv.documentView as? NSTextView else { return sv }
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
        context.coordinator.textView = tv
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

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var tab: WorkTab
        weak var textView: NSTextView?
        init(tab: WorkTab) { self.tab = tab }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            tab.sql = tv.string
            if !tv.hasMarkedText() { SQLHighlighter.apply(to: tv.textStorage!, dialect: tab.connection.dialect) }
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
