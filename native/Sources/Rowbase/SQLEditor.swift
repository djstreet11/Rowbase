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

    static let baseFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)

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

/// Line-number gutter: tertiary monospaced digits on the text background, thin right border.
final class LineNumberRuler: NSRulerView {
    private var textView: NSTextView? { clientView as? NSTextView }
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    init(scrollView: NSScrollView, textView: NSTextView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSText.didChangeNotification, object: textView)
    }
    required init(coder: NSCoder) { fatalError() }

    @objc private func refresh() {
        guard let tv = textView else { return }
        let digits = max(2, String(tv.string.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }).count)
        let w = CGFloat(digits) * 7 + 18
        if abs(w - ruleThickness) > 0.5 { ruleThickness = w }
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let ns = tv.string as NSString
        let origin = tv.textContainerOrigin
        let visible = tv.visibleRect
        let caretLine = ns.substring(to: min(tv.selectedRange().location, ns.length)).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        func label(_ n: Int, y: CGFloat, h: CGFloat) {
            let attrs: [NSAttributedString.Key: Any] = [.font: font,
                .foregroundColor: n == caretLine ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor]
            let str = NSAttributedString(string: String(n), attributes: attrs)
            let sz = str.size()
            let py = convert(NSPoint(x: 0, y: y), from: tv).y + (h - sz.height) / 2
            str.draw(at: NSPoint(x: bounds.maxX - 8 - sz.width, y: py))
        }
        let glyphs = lm.glyphRange(forBoundingRect: visible.offsetBy(dx: -origin.x, dy: -origin.y), in: tc)
        var line = 1
        if glyphs.location > 0 {
            let chars = lm.characterRange(forGlyphRange: NSRange(location: 0, length: glyphs.location), actualGlyphRange: nil)
            line = ns.substring(with: chars).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        }
        var idx = glyphs.location
        while idx < NSMaxRange(glyphs) {
            var lr = NSRange()
            let r = lm.lineFragmentRect(forGlyphAt: idx, effectiveRange: &lr)
            let chars = lm.characterRange(forGlyphRange: lr, actualGlyphRange: nil)
            if chars.location == 0 || ns.character(at: chars.location - 1) == 10 { label(line, y: r.minY + origin.y, h: r.height) }
            if chars.length > 0, ns.character(at: NSMaxRange(chars) - 1) == 10 { line += 1 }
            idx = NSMaxRange(lr)
        }
        if tv.string.isEmpty || ns.hasSuffix("\n") {
            let r = lm.extraLineFragmentRect
            if r.height > 0 { label(line, y: r.minY + origin.y, h: r.height) }
            else if tv.string.isEmpty { label(1, y: origin.y, h: font.pointSize + 6) }
        }
    }
}

final class SQLTextView: NSTextView {
    var completer: Completer?

    /// Subtle highlight of the caret's line.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard selectedRange().length == 0, let lm = layoutManager, window?.firstResponder === self else { return }
        let ns = string as NSString
        let loc = selectedRange().location
        var r: NSRect
        if loc >= ns.length, ns.length == 0 || ns.hasSuffix("\n") { r = lm.extraLineFragmentRect }
        else {
            let g = lm.glyphIndexForCharacter(at: min(loc, max(0, ns.length - 1)))
            r = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        }
        guard r.height > 0 else { return }
        r.origin.y += textContainerOrigin.y
        r.origin.x = 0; r.size.width = bounds.width
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        r.fill()
    }

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
        tv.textContainerInset = NSSize(width: 8, height: 8)
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
        sv.verticalRulerView = LineNumberRuler(scrollView: sv, textView: tv)
        sv.hasVerticalRuler = true
        sv.rulersVisible = true
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
            if let tv = notification.object as? NSTextView {
                tab.selection = tv.selectedRange()
                tv.needsDisplay = true
                tv.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            }
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
