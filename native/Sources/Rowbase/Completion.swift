import SwiftUI
import AppKit
import RowbaseCore

// MARK: - Items

struct CompletionItem {
    enum Kind { case table, column, keyword, function, value }
    var label: String
    var insert: String?
    var kind: Kind
    var detail = ""
    var back = 0
    /// Text used for prefix matching (defaults to label).
    var match: String?
    var matchText: String { match ?? label }
    var insertText: String { insert ?? label }
}

struct CompletionContext {
    var text: String      // current statement
    var before: String    // statement text up to the caret
    var prefix: String
    var qual: String?
    var start: Int        // absolute UTF-16 offset of the word start
    var pos: Int          // absolute UTF-16 offset of the caret
    var inString: Bool
}

// MARK: - Suggestion logic (port of consoleSuggestions / tableRefs / valueItems from the web UI)

enum CompletionLogic {
    static let keywords: [String] = ("SELECT FROM WHERE AND OR NOT IN IS NULL LIKE BETWEEN EXISTS JOIN LEFT RIGHT INNER OUTER CROSS STRAIGHT_JOIN ON USING AS " +
        "ORDER GROUP BY HAVING LIMIT OFFSET DISTINCT UNION ALL CASE WHEN THEN ELSE END ASC DESC WITH SHOW TABLES COLUMNS DESCRIBE EXPLAIN " +
        "ANALYZE FORMAT INTERVAL DAY HOUR MINUTE SECOND MONTH YEAR TRUE FALSE REGEXP COLLATE FORCE INDEX IGNORE ILIKE RETURNING LATERAL FILTER " +
        "INSERT INTO VALUES UPDATE SET DELETE").split(separator: " ").map(String.init)
    static let keywordSet = Set(keywords + ["NATURAL", "FULL", "WINDOW", "OVER"])
    static let functions = ["COUNT", "SUM", "MIN", "MAX", "AVG", "NOW", "CURDATE", "DATE", "DATE_FORMAT", "DATE_SUB", "DATE_ADD", "TIMESTAMPDIFF",
        "CONCAT", "CONCAT_WS", "GROUP_CONCAT", "IFNULL", "COALESCE", "IF", "NULLIF", "CAST", "LENGTH", "LOWER", "UPPER", "TRIM", "SUBSTRING",
        "REPLACE", "HEX", "UNHEX", "ROUND", "ABS", "JSON_EXTRACT", "JSON_UNQUOTE", "FIND_IN_SET",
        "TO_CHAR", "DATE_TRUNC", "STRING_AGG", "ARRAY_AGG", "JSONB_EXTRACT_PATH_TEXT"]
    static let whereKeywords: [CompletionItem] = [
        CompletionItem(label: "IN ()", insert: "IN ()", kind: .keyword, back: 1),
        CompletionItem(label: "NOT IN ()", insert: "NOT IN ()", kind: .keyword, back: 1),
        CompletionItem(label: "IS NULL", kind: .keyword), CompletionItem(label: "IS NOT NULL", kind: .keyword),
        CompletionItem(label: "LIKE ''", kind: .keyword, back: 1), CompletionItem(label: "NOW()", kind: .keyword),
    ]

    static func regex(_ p: String, _ o: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: o)
    }
    static let ctxRE = regex(#"(?:[`"]?([A-Za-z_]\w*)[`"]?\.)?[`"]?(\w*)$"#, [])
    static let doneStringRE = regex(#"'(?:[^'\\]|\\[\s\S]|'')*'"#, [])
    static let openStringRE = regex(#"'[^']*$"#, [])
    static let dotTailRE = regex(#"\.\w*$"#, [])
    static let valueTriggerRE = regex(#"[=(]\s*$"#, [])
    static let prevWordRE = regex(#"(\w+|,)$"#, [])
    static let lastKwRE = regex(#"\b(SELECT|FROM|JOIN|WHERE|ON|AND|OR|BY|HAVING|LIMIT|DESC|DESCRIBE|SHOW)\b"#)
    static let valueRE = regex(#"[`"]?(\w+)[`"]?\s*(?:=|<>|!=|(?:NOT\s+)?IN\s*\((?:\s*'[^']*'\s*,)*)\s*'?\w*$"#)
    static let enumRE = regex(#"^(?:enum|set)\((.*)\)$"#, [.caseInsensitive, .dotMatchesLineSeparators])
    static let enumValRE = regex(#"'((?:[^']|'')*)'"#, [])
    static let refPart = #"((?:[`"]?\w+[`"]?\.)?[`"]?\w+[`"]?)(?:\s+(?:AS\s+)?[`"]?(\w+)[`"]?)?"#
    static let fromRE = regex(#"\b(?:FROM|JOIN)\s+"# + refPart)
    static let commaRE = regex(#"\s*,\s*"# + refPart)
    static let plainIdent = regex(#"^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)?$"#, [])

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// Blank out comments and string literals (same length) so keyword scans are not fooled.
    static func stripLiterals(_ s: String, _ d: Dialect) -> String {
        let p = d == .mysql ? #"--[^\n]*|#[^\n]*|/\*[\s\S]*?(?:\*/|\z)|'(?:[^'\\]|\\[\s\S]|'')*'?|"(?:[^"\\]|\\[\s\S])*"?"#
                            : #"--[^\n]*|/\*[\s\S]*?(?:\*/|\z)|'(?:[^'\\]|\\[\s\S]|'')*'?"#
        let re = regex(p, [])
        let ns = s as NSString
        var out = ""
        var last = 0
        re.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += String(repeating: " ", count: m.range.length)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    struct Ref { var table: String; var alias: String? }

    static func tableRefs(_ text: String, known: [String: String], dialect: Dialect) -> [Ref] {
        let clean = stripLiterals(text, dialect)
        let ns = clean as NSString
        var out: [Ref] = []
        func add(_ m: NSTextCheckingResult) {
            let raw = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "\"", with: "")
            var name = known[raw.lowercased()]
            if name == nil, raw.lowercased().hasPrefix("public.") { name = known[String(raw.dropFirst(7)).lowercased()] }
            guard let name else { return }
            var alias: String?
            if m.range(at: 2).location != NSNotFound {
                let a = ns.substring(with: m.range(at: 2))
                if !keywordSet.contains(a.uppercased()) { alias = a }
            }
            out.append(Ref(table: name, alias: alias))
        }
        let full = NSRange(location: 0, length: ns.length)
        for m in fromRE.matches(in: clean, range: full) {
            add(m)
            // comma-separated list: FROM a x, b y
            var end = m.range.location + m.range.length
            if m.range(at: 2).location != NSNotFound, keywordSet.contains(ns.substring(with: m.range(at: 2)).uppercased()) {
                end = m.range(at: 2).location  // alias slot swallowed a keyword → continuation can't follow
                continue
            }
            while let c = commaRE.firstMatch(in: clean, options: .anchored, range: NSRange(location: end, length: ns.length - end)) {
                add(c)
                end = c.range.location + c.range.length
            }
        }
        return out
    }

    static func enumValues(_ type: String) -> [String]? {
        guard let m = enumRE.firstMatch(in: type, range: NSRange(location: 0, length: (type as NSString).length)) else { return nil }
        let inner = (type as NSString).substring(with: m.range(at: 1))
        let ns = inner as NSString
        return enumValRE.matches(in: inner, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1)).replacingOccurrences(of: "''", with: "'")
        }
    }

    /// Values for the column right before an operator: enum values, 0/1 (or true/false) for flags.
    static func valueItems(before: String, columns: [ColumnInfo], quoted: Bool, dialect: Dialect) -> [CompletionItem]? {
        let ns = before as NSString
        guard let m = valueRE.firstMatch(in: before, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let name = ns.substring(with: m.range(at: 1)).lowercased()
        guard let c = columns.first(where: { $0.name.lowercased() == name }) else { return nil }
        if let ev = enumValues(c.type) {
            return ev.map { CompletionItem(label: quoted ? $0 : "'\($0)'", insert: quoted ? $0 : "'\($0)'", kind: .value, detail: c.name, match: $0) }
        }
        let t = c.type.lowercased()
        if t.hasPrefix("tinyint(1)") { return quoted ? [] : ["0", "1"].map { CompletionItem(label: $0, kind: .value, detail: c.name) } }
        if t == "boolean" || t == "bool" {
            if quoted { return [] }
            let vs = dialect == .postgres ? ["true", "false"] : ["1", "0"]
            return vs.map { CompletionItem(label: $0, kind: .value, detail: c.name) }
        }
        return nil
    }

    static func tableRef(_ name: String, _ d: Dialect) -> String {
        matches(plainIdent, name) ? name : d.ident(name)
    }

    static func rank(_ items: [CompletionItem], prefix: String) -> [CompletionItem] {
        let p = prefix.lowercased()
        var starts: [CompletionItem] = [], contains: [CompletionItem] = []
        for it in items {
            let l = it.matchText.lowercased()
            if p.isEmpty || l.hasPrefix(p) { starts.append(it) } else if l.contains(p) { contains.append(it) }
        }
        return Array((starts + contains).prefix(80))
    }
}

// MARK: - Provider (needs AppState for tables / column metadata)

@MainActor
final class CompletionProvider {
    let state: AppState
    let tab: WorkTab
    private var foreignTables: [String: [TableEntry]] = [:]

    init(state: AppState, tab: WorkTab) { self.state = state; self.tab = tab }

    private func tables() async -> [TableEntry] {
        let conn = tab.connection
        if conn.id == state.selectedConnectionID, !state.tables.isEmpty { return state.tables }
        if let t = foreignTables[conn.id] { return t }
        let t = (try? await state.engine.tables(conn)) ?? []
        foreignTables[conn.id] = t
        return t
    }

    private func info(_ table: String) async -> TableInfo? {
        try? await state.tableInfo(for: tab.connection, table: table)
    }

    /// `valueOnly` → the caller only wants value suggestions (trigger was `= ` / `IN (`); returns nil when there are none.
    func items(_ c: CompletionContext, valueOnly: Bool = false) async -> [CompletionItem]? {
        let d = tab.connection.dialect
        let tbls = await tables()
        var known: [String: String] = [:]
        for t in tbls where known[t.name.lowercased()] == nil { known[t.name.lowercased()] = t.name }
        let refs = CompletionLogic.tableRefs(c.text, known: known, dialect: d)
        var metas: [TableInfo?] = []
        for r in refs { metas.append(await info(r.table)) }
        var allCols: [(ColumnInfo, CompletionLogic.Ref)] = []
        for (i, r) in refs.enumerated() { for col in metas[i]?.columns ?? [] { allCols.append((col, r)) } }
        let cols = allCols.map(\.0)

        if c.inString {
            if valueOnly { return nil }
            return CompletionLogic.valueItems(before: String(c.before.dropLast(c.prefix.count)), columns: cols, quoted: true, dialect: d) ?? []
        }
        let beforeWord = (c.before as NSString).substring(to: max(0, (c.before as NSString).length - c.prefix.utf16.count))
        if let q = c.qual {
            let ql = q.lowercased()
            let tableName = refs.first(where: { ($0.alias ?? "").lowercased() == ql })?.table
                ?? refs.first(where: { $0.table.lowercased() == ql })?.table
                ?? known[ql]
            if valueOnly { return nil }
            if let tableName, let inf = await info(tableName) {
                return inf.columns.map { CompletionItem(label: $0.name, insert: nil, kind: .column, detail: $0.type) }
            }
            return tbls.filter { $0.name.lowercased().hasPrefix(ql + ".") }.map {
                CompletionItem(label: String($0.name.dropFirst(q.count + 1)), kind: .table, detail: $0.isView ? "view" : "")
            }
        }
        let prev = CompletionLogic.stripLiterals(beforeWord, d).trimmingCharacters(in: .whitespacesAndNewlines)
        let pns = prev as NSString
        let prevWord = CompletionLogic.prevWordRE.firstMatch(in: prev, range: NSRange(location: 0, length: pns.length))
            .map { pns.substring(with: $0.range(at: 1)).uppercased() } ?? ""
        let lastKw = CompletionLogic.lastKwRE.matches(in: prev, range: NSRange(location: 0, length: pns.length)).last
            .map { pns.substring(with: $0.range(at: 1)).uppercased() }
        let tableTrigger = ["FROM", "JOIN", "INTO", "UPDATE", "DESCRIBE"].contains(prevWord)
            || (prevWord == "DESC" && prev.uppercased() == "DESC")
            || (prevWord == "," && lastKw == "FROM")
        if tableTrigger {
            if valueOnly { return nil }
            return tbls.map {
                CompletionItem(label: $0.name, insert: CompletionLogic.tableRef($0.name, d), kind: .table,
                               detail: $0.isView ? "view" : ($0.rows.map { "\($0.formatted()) rows" } ?? ""))
            }
        }
        let vals = CompletionLogic.valueItems(before: beforeWord, columns: cols, quoted: false, dialect: d)
        if valueOnly { return vals }
        if let vals, c.prefix.isEmpty { return vals }
        let multi = refs.count > 1
        let colItems = allCols.map { col, r in
            CompletionItem(label: multi ? "\(r.alias ?? r.table).\(col.name)" : col.name, kind: .column, detail: col.type)
        }
        let aliasItems = refs.map { CompletionItem(label: $0.alias ?? $0.table, kind: .table, detail: $0.alias != nil ? $0.table : "table") }
        let fns = CompletionLogic.functions.map { CompletionItem(label: $0, insert: $0 + "()", kind: .function, detail: "function", back: 1) }
        let kws = CompletionLogic.keywords.map { CompletionItem(label: $0, kind: .keyword) } + CompletionLogic.whereKeywords
        var out = (vals ?? []) + colItems + aliasItems + fns + kws
        if refs.isEmpty {
            out += tbls.map {
                CompletionItem(label: $0.name, insert: CompletionLogic.tableRef($0.name, d), kind: .table, detail: $0.isView ? "view" : "table")
            }
        }
        return out
    }
}

// MARK: - Popup window

private final class CompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CompletionBackground: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 0.5
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }
}

private final class CompletionRowView: NSTableRowView {
    override var isEmphasized: Bool { get { true } set {} }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected ? .emphasized : .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 1), xRadius: 4, yRadius: 4).fill()
    }
}

private final class CompletionCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("cc")
    let badge = NSTextField(labelWithString: "")
    let label = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    private var item: CompletionItem?
    private var prefix = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.id
        badge.alignment = .center
        badge.font = .systemFont(ofSize: 10, weight: .bold)
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 3
        label.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.alignment = .right
        detail.lineBreakMode = .byTruncatingHead
        for v in [badge, label, detail] { v.isBordered = false; v.drawsBackground = false; addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError() }

    private var selected: Bool { backgroundStyle == .emphasized }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { if oldValue != backgroundStyle { refresh() } } }

    func configure(_ it: CompletionItem, prefix: String) {
        item = it
        self.prefix = prefix
        refresh()
    }

    private func color(_ k: CompletionItem.Kind) -> NSColor {
        switch k {
        case .table: .systemBlue
        case .column: .systemTeal
        case .keyword: .systemPurple
        case .function: .systemOrange
        case .value: .systemPink
        }
    }

    private func refresh() {
        guard let it = item else { return }
        let sel = selected
        let letter: String
        switch it.kind { case .table: letter = "T"; case .column: letter = "C"; case .keyword: letter = "K"; case .function: letter = "ƒ"; case .value: letter = "V" }
        badge.stringValue = letter
        badge.textColor = sel ? .white : color(it.kind)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            badge.layer?.backgroundColor = (sel ? NSColor.white.withAlphaComponent(0.25) : color(it.kind).withAlphaComponent(0.16)).cgColor
        }
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        let fg: NSColor = sel ? .white : .labelColor
        let a = NSMutableAttributedString(string: it.label, attributes: [.font: mono, .foregroundColor: fg])
        if !prefix.isEmpty, let r = it.label.range(of: prefix, options: [.caseInsensitive, .anchored]) ?? it.label.range(of: prefix, options: .caseInsensitive) {
            a.addAttribute(.font, value: bold, range: NSRange(r, in: it.label))
        }
        label.attributedStringValue = a
        detail.stringValue = it.detail
        detail.textColor = sel ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        badge.frame = NSRect(x: 8, y: (h - 15) / 2, width: 15, height: 15)
        let dw = min(((detail.stringValue as NSString).size(withAttributes: [.font: detail.font ?? .systemFont(ofSize: 11)]).width).rounded(.up) + 6, bounds.width * 0.4)
        detail.frame = NSRect(x: bounds.width - dw - 10, y: (h - 15) / 2, width: dw, height: 15)
        let lh = label.intrinsicContentSize.height
        label.frame = NSRect(x: 30, y: (h - lh) / 2, width: max(0, detail.frame.minX - 30 - 8), height: lh)
    }
}

private final class CompletionTable: NSTableView {
    override var acceptsFirstResponder: Bool { false }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let r = row(at: p)
        if r >= 0 { selectRowIndexes([r], byExtendingSelection: false); (target as? CompletionPopup)?.clicked(r) }
    }
}

@MainActor
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private let table = CompletionTable()
    private let scroll = NSScrollView()
    private var items: [CompletionItem] = []
    private var prefix = ""
    var onAccept: ((CompletionItem) -> Void)?
    static let rowH: CGFloat = 22
    static let maxRows = 12

    var window: NSWindow? { isVisible ? panel : nil }
    var isVisible: Bool { panel.isVisible }
    var selectedItem: CompletionItem? {
        let r = table.selectedRow
        return r >= 0 && r < items.count ? items[r] : nil
    }

    override init() {
        panel = CompletionPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let bg = CompletionBackground(frame: panel.contentRect(forFrameRect: panel.frame))
        panel.contentView = bg
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = Self.rowH
        table.intercellSpacing = .zero
        table.style = .plain
        table.backgroundColor = .clear
        table.allowsEmptySelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]
        scroll.frame = bg.bounds.insetBy(dx: 0, dy: 4)
        bg.addSubview(scroll)
    }

    func clicked(_ row: Int) { if row < items.count { onAccept?(items[row]) } }

    func show(items: [CompletionItem], prefix: String, caretRect: NSRect, parent: NSWindow) {
        self.items = items
        self.prefix = prefix
        table.reloadData()
        table.selectRowIndexes([0], byExtendingSelection: false)
        table.scrollRowToVisible(0)
        // size
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let small = NSFont.systemFont(ofSize: 11)
        var w: CGFloat = 0
        for it in items.prefix(200) {
            let lw = (it.label as NSString).size(withAttributes: [.font: mono]).width
            let dw = min(220, (it.detail as NSString).size(withAttributes: [.font: small]).width)
            w = max(w, lw + dw + (dw > 0 ? 24 : 0))
        }
        let width = min(580, max(300, w + 60))
        let rows = min(items.count, Self.maxRows)
        let height = CGFloat(rows) * Self.rowH + 8
        var origin = NSPoint(x: caretRect.minX - 30, y: caretRect.minY - height - 3)
        let vf = (parent.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1600, height: 1000)
        if origin.y < vf.minY { origin.y = caretRect.maxY + 3 }
        origin.x = max(vf.minX + 4, min(origin.x, vf.maxX - width - 4))
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func close() {
        guard panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func move(_ d: Int) {
        guard !items.isEmpty else { return }
        let n = items.count
        let r = ((table.selectedRow + d) % n + n) % n
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { CompletionRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: CompletionCell.id, owner: nil) as? CompletionCell) ?? CompletionCell(frame: .zero)
        cell.configure(items[row], prefix: prefix)
        return cell
    }
}

// MARK: - Controller

@MainActor
final class Completer {
    weak var tv: NSTextView?
    let tab: WorkTab
    let provider: CompletionProvider
    let popup = CompletionPopup()
    private var seq = 0
    var skipNext = false
    var lastChangeLen = 0
    /// Replaces the SQL-editor provider (WHERE / ORDER BY fields suggest only the table's columns, keywords, values).
    var custom: (@MainActor (CompletionContext, Bool) async -> [CompletionItem]?)?

    var isOpen: Bool { popup.isVisible }

    init(tab: WorkTab, state: AppState) {
        self.tab = tab
        provider = CompletionProvider(state: state, tab: tab)
        popup.onAccept = { [weak self] in self?.accept($0) }
    }

    func close() {
        seq += 1
        popup.close()
    }

    func move(_ d: Int) { popup.move(d) }
    func acceptSelected() { if let it = popup.selectedItem { accept(it) } }

    func context() -> CompletionContext? {
        guard let tv, tv.selectedRange().length == 0 else { return nil }
        let ns = tv.string as NSString
        let pos = min(tv.selectedRange().location, ns.length)
        let u = Array(tv.string.utf16)
        let segs = SQLSplit.segments(u, tab.connection.dialect)
        var s = 0
        for seg in segs where seg.1 <= pos && seg.1 > seg.0 && u[seg.1 - 1] == 59 { s = max(s, seg.1) }
        var e = ns.length
        for seg in segs where seg.1 > pos { e = seg.1; break }
        e = max(e, pos)
        let before = ns.substring(with: NSRange(location: s, length: pos - s))
        let text = ns.substring(with: NSRange(location: s, length: e - s))
        let bns = before as NSString
        let tail = bns.substring(from: max(0, bns.length - 200))
        let tns = tail as NSString
        guard let m = CompletionLogic.ctxRE.firstMatch(in: tail, range: NSRange(location: 0, length: tns.length)) else { return nil }
        let prefix = m.range(at: 2).location == NSNotFound ? "" : tns.substring(with: m.range(at: 2))
        let qual: String? = m.range(at: 1).location == NSNotFound ? nil : tns.substring(with: m.range(at: 1))
        let stripped = CompletionLogic.doneStringRE.stringByReplacingMatches(in: before, range: NSRange(location: 0, length: bns.length), withTemplate: "")
        let inString = CompletionLogic.matches(CompletionLogic.openStringRE, stripped)
        return CompletionContext(text: text, before: before, prefix: prefix, qual: qual, start: pos - (prefix as NSString).length, pos: pos, inString: inString)
    }

    func update(force: Bool) {
        guard let c = context() else { return close() }
        let lastLine = c.before.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        if !c.inString, CompletionLogic.stripLiterals(lastLine, tab.connection.dialect).contains("--") { return close() }
        let afterDot = c.qual != nil && CompletionLogic.matches(CompletionLogic.dotTailRE, c.before)
        let strQuote = c.inString && c.before.hasSuffix("'")
        let valueTrigger = CompletionLogic.matches(CompletionLogic.valueTriggerRE, c.before)
        if !force && c.prefix.isEmpty && !afterDot && !strQuote && !valueTrigger { return close() }
        if !force, c.qual == nil, let f = c.prefix.unicodeScalars.first, CharacterSet.decimalDigits.contains(f) { return close() }
        let valueOnly = !force && c.prefix.isEmpty && !afterDot && !strQuote && valueTrigger
        seq += 1
        let my = seq
        Task { [weak self] in
            guard let self else { return }
            let raw: [CompletionItem]?
            if let custom { raw = await custom(c, valueOnly) } else { raw = await provider.items(c, valueOnly: valueOnly) }
            guard my == seq else { return }       // stale response
            guard let raw else { return close() }
            let items = CompletionLogic.rank(raw, prefix: c.prefix)
            if items.isEmpty || (items.count == 1 && items[0].matchText == c.prefix && !force) { return close() }
            present(items, ctx: c)
        }
    }

    private func present(_ items: [CompletionItem], ctx: CompletionContext) {
        guard let tv, let win = tv.window else { return }
        var r = tv.firstRect(forCharacterRange: NSRange(location: ctx.start, length: 0), actualRange: nil)
        if r == .zero || r.isNull {
            let f = win.frame
            r = NSRect(x: f.midX, y: f.midY, width: 1, height: 16)
        }
        popup.show(items: items, prefix: ctx.prefix, caretRect: r, parent: win)
    }

    func accept(_ it: CompletionItem) {
        guard let tv, let c = context() else { return close() }
        close()
        let ns = tv.string as NSString
        var ins = it.insertText
        var start = c.start
        if c.inString, it.kind == .value, !(c.pos < ns.length && ns.character(at: c.pos) == 39) { ins += "'" }
        if start > 0, [96, 34].contains(ns.character(at: start - 1)), ins.hasPrefix("`") || ins.hasPrefix("\"") { start -= 1 }
        skipNext = true
        tv.insertText(ins, replacementRange: NSRange(location: start, length: c.pos - start))
        if it.back > 0 {
            let loc = tv.selectedRange().location - it.back
            tv.setSelectedRange(NSRange(location: max(0, loc), length: 0))
        }
        skipNext = false
        tv.window?.makeFirstResponder(tv)
    }
}
