import SwiftUI
import AppKit
import RowbaseCore

// MARK: - Result area (grid / plan / error / affected)

struct ResultArea: View {
    let state: AppState
    let tab: WorkTab

    /// Empty result sets carry no column names (known gap) — fall back to the table's columns so pending inserts can show.
    private func gridResult(_ r: QueryResult) -> QueryResult {
        guard r.columns.isEmpty, !tab.isQuery, let cols = tab.info?.columns, tab.canEdit else { return r }
        var q = r
        q.columns = cols.map(\.name)
        return q
    }

    var body: some View {
        ZStack {
            if let e = tab.error {
                ScrollView {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).padding(.top, 1)
                        SelectableText(e, font: .mono(), color: .systemRed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(10)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.red.opacity(0.25)))
                    .padding(12)
                }
            } else if let r = tab.result {
                if let a = r.affected, r.columns.isEmpty {
                    Text("\(a) row(s) affected").foregroundStyle(.secondary)
                } else if tab.isExplain && r.columns.count == 1 {
                    PlanText(lines: r.rows.map { $0.first.flatMap { $0 } ?? "" })
                } else {
                    if !r.columns.isEmpty && r.columns.allSatisfy({ tab.hidden.contains($0) }) {
                        Text("All columns are hidden — use the Columns button").foregroundStyle(.secondary)
                    } else {
                    ResultGrid(result: gridResult(r), version: tab.resultVersion, info: tab.isQuery ? nil : tab.info,
                               rowOffset: tab.isQuery ? 0 : tab.offset,
                               transpose: tab.transpose, hidden: tab.hidden,
                               explainMySQL: tab.isExplain && tab.connection.dialect == .mysql,
                               editTab: tab.isQuery ? nil : tab, pendingVersion: tab.pendingVersion, canEdit: tab.canEdit,
                               refLinks: state.refReady.contains(state.refKey(tab.connection)),
                               onFollowFK: { col, val, hint in state.followFK(from: tab, column: col, value: val, hint: hint) },
                               onInspect: { state.inspect(tab, row: $0) },
                               filtered: tab.tableName == nil ? nil : Set((tab.filters.conds ?? []).compactMap(\.col)),
                               onFilterEdit: { col, preset, view, rect in
                                   let cur = tab.filter(on: col)
                                   FilterPopoverPresenter.show(.table(state, tab, column: col), initial: preset ?? cur, showClear: cur != nil,
                                                               relativeTo: rect, of: view) { state.setFilter(tab, column: col, $0) }
                               },
                               onFilterSet: { col, c in state.setFilter(tab, column: col, c) })
                    }
                }
            } else if !tab.running {
                Text(tab.isBuilder ? "Press Run to see the result" : tab.isQuery ? "Write a query and press ⌘↩" : "").foregroundStyle(.tertiary)
            }
            if tab.running {
                ProgressView().controlSize(.small).padding(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct PlanText: View {
    let lines: [String]

    /// one attributed string: Seq Scan lines in orange (a full table scan)
    static func plan(_ lines: [String]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, l) in lines.enumerated() {
            out.append(NSAttributedString(string: (i > 0 ? "\n" : "") + l, attributes: [
                .font: NSFont.mono(), .foregroundColor: l.contains("Seq Scan") ? NSColor.systemOrange : NSColor.labelColor]))
        }
        return out
    }
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            SelectableText(attributed: Self.plan(lines), wraps: false)
                .fixedSize()
                .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.topLeading)  // 2-axis ScrollView centers small content otherwise
    }
}

// MARK: - AppKit grid

final class GridTableView: NSTableView {
    var onCopy: (() -> Void)?
    var onSpace: (() -> Void)?
    var menuProvider: ((NSPoint) -> NSMenu?)?
    var onReturn: (() -> Bool)?
    private(set) var hoverRow = -1

    override func drawBackground(inClipRect clipRect: NSRect) {
        backgroundColor.setFill()
        clipRect.fill()
        let alts = NSColor.alternatingContentBackgroundColors
        guard alts.count > 1, numberOfRows > 0 else { return }
        let rs = rows(in: clipRect)
        guard rs.length > 0 else { return }
        alts[1].setFill()
        for r in rs.location..<NSMaxRange(rs) where r % 2 == 1 { rect(ofRow: r).intersection(clipRect).fill() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas where a.owner === self { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        setHover(row(at: convert(event.locationInWindow, from: nil)))
    }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); setHover(-1) }

    private func setHover(_ r: Int) {
        guard r != hoverRow else { return }
        let old = hoverRow
        hoverRow = r
        for row in [old, r] where row >= 0 {
            for c in 0..<numberOfColumns { (view(atColumn: c, row: row, makeIfNecessary: false) as? GridCell)?.hover = row == hoverRow }
        }
    }

    @objc func copy(_ sender: Any?) { onCopy?() }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " && event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            onSpace?()
        } else if (event.keyCode == 36 || event.keyCode == 76), event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  onReturn?() == true {
            return
        } else {
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(convert(event.locationInWindow, from: nil)) ?? super.menu(for: event)
    }
}

/// Small rounded "NULL" capsule in tertiary color.
final class NullPill: NSView {
    let label = NSTextField(labelWithString: "NULL")
    static let size: NSSize = {
        let l = NSTextField(labelWithString: "NULL")
        l.font = .systemFont(ofSize: 9, weight: .semibold)
        return NSSize(width: ceil(l.intrinsicContentSize.width) + 10, height: 14)
    }()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        let h = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 5, y: (bounds.height - h) / 2, width: bounds.width - 10, height: h)
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 4
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Grid cell with manual frame layout. No Auto Layout on purpose: wide tables (70+ columns) put thousands of cell
/// views in the window's constraint engine and vertical scrolling spent ~all its time in CoreAutoLayout.
final class GridCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    // NULL pill and FK arrow are created on first use: wide tables keep thousands of cells alive.
    private var pill: NullPill?
    private var link: NSImageView?
    private var pillRight = false
    /// Background tint for edited cells (re-resolved on appearance change).
    var tint: NSColor? { didSet { if tint != oldValue || tint != nil { applyTint() } } }
    /// FK value: shows a small arrow glyph while the row is hovered.
    var isFK = false { didSet { if isFK != oldValue { needsLayout = true }; updateLink() } }
    var hover = false { didSet { if hover != oldValue { updateLink() } } }

    private func updateLink() {
        let show = isFK && hover
        if show && link == nil {
            let l = NSImageView()
            let cfg = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
            l.image = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: "Follow reference")?.withSymbolConfiguration(cfg)
            l.contentTintColor = .linkColor
            addSubview(l)
            link = l
            needsLayout = true
        }
        link?.isHidden = !show
    }

    func setNull(_ on: Bool, right: Bool) {
        if on && pill == nil { let p = NullPill(); addSubview(p); pill = p; needsLayout = true }
        pill?.isHidden = !on
        if right != pillRight { pillRight = right; needsLayout = true }
    }

    private func applyTint() {
        if tint != nil && !wantsLayer { wantsLayer = true }
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = tint?.cgColor }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); if tint != nil { applyTint() } }

    func beginEditing(text: String, font: NSFont) {
        pill?.isHidden = true
        label.isEditable = true
        label.isSelectable = true
        label.drawsBackground = true
        label.backgroundColor = .textBackgroundColor
        label.font = font
        label.textColor = .labelColor
        label.alignment = .left
        label.stringValue = text
        needsLayout = true
    }

    func endEditing() {
        guard label.isEditable else { return }
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
    }

    private static var lineHeight: [NSFont: CGFloat] = [:]
    override func layout() {
        let b = bounds
        let f = label.font ?? .systemFont(ofSize: 12)
        let lh = Self.lineHeight[f] ?? { let h = ceil(f.boundingRectForFont.height); Self.lineHeight[f] = h; return h }()
        let h = min(b.height, max(lh, 16))
        label.frame = NSRect(x: 4, y: floor((b.height - h) / 2), width: max(0, b.width - 4 - (isFK ? 16 : 8)), height: h)
        let ps = NullPill.size
        pill?.frame = NSRect(x: pillRight ? b.width - 4 - ps.width : 4, y: floor((b.height - ps.height) / 2), width: ps.width, height: ps.height)
        link?.frame = NSRect(x: b.width - 14, y: floor((b.height - 10) / 2), width: 10, height: 10)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = ResultGrid.cellID
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.cell?.truncatesLastVisibleLine = true
        label.maximumNumberOfLines = 1
        addSubview(label)
        textField = label
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Two-line column header: name (semibold 11) with the type below in tertiary 10pt.
/// Header model. NSCell is copied with NSCopyObject (bitwise, no retain), so a Swift NSCell subclass must NOT have
/// stored object properties (double release → heap corruption, crashed macOS 15). Data lives in `representedObject`.
final class GridHeaderInfo: NSObject {
    let name: String, typeText: String, numeric: Bool, dim: Bool
    /// Column filter button at the right edge (table tabs); `filtered` = a filter is active (accent, filled).
    let filterable: Bool, filtered: Bool
    init(name: String, typeText: String, numeric: Bool, dim: Bool, filterable: Bool = false, filtered: Bool = false) {
        (self.name, self.typeText, self.numeric, self.dim, self.filterable, self.filtered) = (name, typeText, numeric, dim, filterable, filtered)
    }
    static let filterWidth: CGFloat = 18
    static func filterIcon(_ on: Bool) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: on ? .semibold : .regular)
            .applying(.init(paletteColors: [on ? .controlAccentColor : .tertiaryLabelColor]))
        return NSImage(systemSymbolName: on ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle",
                       accessibilityDescription: "Filter")?.withSymbolConfiguration(cfg)
    }
}

/// Header view that routes clicks on a column's filter button (right edge) instead of sorting.
final class GridHeaderView: NSTableHeaderView {
    var onFilter: ((Int, NSRect) -> Void)?

    func filterRect(_ c: Int) -> NSRect? {
        guard let tv = tableView, c >= 0, c < tv.tableColumns.count,
              (tv.tableColumns[c].headerCell.representedObject as? GridHeaderInfo)?.filterable == true else { return nil }
        let r = headerRect(ofColumn: c)
        return NSRect(x: r.maxX - GridHeaderInfo.filterWidth - 2, y: r.minY, width: GridHeaderInfo.filterWidth, height: r.height)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let c = column(at: p)
        if let r = filterRect(c), r.contains(p) { onFilter?(c, r); return }
        super.mouseDown(with: event)
    }
}

final class GridHeaderCell: NSTableHeaderCell {
    convenience init(_ info: GridHeaderInfo) {
        self.init(textCell: info.name)
        representedObject = info
    }

    override func drawInterior(withFrame f: NSRect, in v: NSView) {
        guard let i = representedObject as? GridHeaderInfo else { return }
        let (name, typeText, numeric, dim) = (i.name, i.typeText, i.numeric, i.dim)
        // The header view paints a copy of the last cell over the empty filler area: only draw real columns.
        guard let hv = v as? NSTableHeaderView, hv.tableView?.tableColumns.contains(where: { $0.headerCell === self }) == true else { return }
        let ps = NSMutableParagraphStyle()
        ps.lineBreakMode = .byTruncatingTail
        ps.alignment = numeric ? .right : .left
        let n = NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: dim ? NSColor.tertiaryLabelColor : NSColor.labelColor, .paragraphStyle: ps])
        let t = NSAttributedString(string: typeText, attributes: [.font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: ps])
        let fw = i.filterable ? GridHeaderInfo.filterWidth : 0
        let x = f.minX + 6, w = max(0, f.width - 12 - fw - (numeric || fw > 0 ? 0 : 10))
        let nh: CGFloat = 14, th: CGFloat = typeText.isEmpty ? 0 : 13
        var y = f.minY + (f.height - nh - th) / 2
        n.draw(in: NSRect(x: x, y: y, width: w, height: nh))
        y += nh
        if th > 0 { t.draw(in: NSRect(x: x, y: y, width: w, height: th)) }
        if i.filterable, let img = GridHeaderInfo.filterIcon(i.filtered) {
            let s = img.size
            img.draw(in: NSRect(x: f.maxX - fw + (fw - s.width) / 2 - 3, y: f.minY + (f.height - s.height) / 2, width: s.width, height: s.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

/// Row view that tints rows flagged by the MySQL EXPLAIN check (full table scan).
final class GridRowView: NSTableRowView {
    static let id = NSUserInterfaceItemIdentifier("rbrow")
    var bad = false { didSet { if bad != oldValue { needsDisplay = true } } }
    /// Pending insert (green) / delete (red) tint.
    var tint: NSColor? { didSet { if tint != oldValue { needsDisplay = true } } }
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if bad {
            NSColor.systemOrange.withAlphaComponent(0.16).setFill()
            bounds.fill()
        }
        if let tint {
            tint.setFill()
            bounds.fill()
        }
    }
}

struct ResultGrid: NSViewRepresentable {
    static let cellID = NSUserInterfaceItemIdentifier("rbcell")

    let result: QueryResult
    let version: Int
    var info: TableInfo?
    var rowOffset = 0
    var transpose = false
    var hidden: Set<String> = []
    var explainMySQL = false
    var editTab: WorkTab?
    var pendingVersion = 0
    var canEdit = false
    /// Show UUID values as implicit-reference links (the database has UUID-keyed tables).
    var refLinks = false
    var onFollowFK: ((String, String, String?) -> Void)?
    var onInspect: (Int) -> Void
    /// Column filters (table tabs): columns with an active filter, open the editor (column, preset, anchor), set one directly.
    var filtered: Set<String>? = nil
    var onFilterEdit: ((String, FilterCond?, NSView, NSRect) -> Void)?
    var onFilterSet: ((String, FilterCond?) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator
        let tv = GridTableView()
        tv.usesAlternatingRowBackgroundColors = false
        tv.backgroundColor = .textBackgroundColor
        tv.gridStyleMask = [.solidVerticalGridLineMask]
        tv.gridColor = NSColor(white: 0.5, alpha: 0.16)
        let hv = GridHeaderView(frame: NSRect(x: 0, y: 0, width: 100, height: 34))
        hv.onFilter = { [weak c] col, rect in c?.headerFilter(col, rect) }
        tv.headerView = hv
        tv.allowsMultipleSelection = true
        tv.allowsColumnResizing = true
        tv.allowsColumnReordering = true
        tv.columnAutoresizingStyle = .noColumnAutoresizing
        tv.rowHeight = 22
        tv.intercellSpacing = NSSize(width: 1, height: 0)
        tv.style = .plain
        tv.dataSource = c
        tv.delegate = c
        tv.target = c
        tv.action = #selector(Coordinator.clicked(_:))
        tv.doubleAction = #selector(Coordinator.doubleClicked(_:))
        tv.onCopy = { [weak c] in c?.copyRows(json: false) }
        tv.onSpace = { [weak c] in c?.inspectSelected() }
        tv.onReturn = { [weak c] in c?.beginEditSelected() ?? false }
        tv.menuProvider = { [weak c] p in c?.menu(at: p) }
        c.table = tv
        if let n = Int(ProcessInfo.processInfo.environment["ROWBASE_SNAPSHOT_SCROLL"] ?? "") { Self.benchScroll(tv, passes: n) }
        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = true
        sv.backgroundColor = .textBackgroundColor
        return sv
    }

    /// Fill the offered space. Without this SwiftUI asks the scroll view for `fittingSize`, which pushes every cell view
    /// into a constraint engine on each SwiftUI layout pass (the bulk of the remaining scroll cost on wide tables).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 300)
    }

    /// Snapshot hook: scroll the grid top→bottom `passes` times, forcing a display each step; prints the time (perf checks).
    private static func benchScroll(_ tv: NSTableView, passes: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard let clip = tv.enclosingScrollView?.contentView else { return }
            let t0 = Date()
            var steps = 0
            for _ in 0..<passes {
                var y: CGFloat = 0
                while y < tv.bounds.height - clip.bounds.height {
                    y += 44
                    clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
                    tv.enclosingScrollView?.reflectScrolledClipView(clip)
                    tv.window?.displayIfNeeded()
                    steps += 1
                }
                clip.scroll(to: .zero)
            }
            print(String(format: "ROWBASE_SCROLL steps=%d total=%.3fs per_step=%.2fms", steps, Date().timeIntervalSince(t0),
                         Date().timeIntervalSince(t0) * 1000 / Double(max(steps, 1))))
            fflush(stdout)
        }
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let c = context.coordinator
        c.onFollowFK = onFollowFK
        c.onInspect = onInspect
        c.rowOffset = rowOffset
        c.tab = editTab
        c.onFilterEdit = onFilterEdit
        c.onFilterSet = onFilterSet
        c.setFiltered(filtered)
        c.update(result: result, version: version, info: info, transpose: transpose, hidden: hidden, explain: explainMySQL,
                 pending: pendingVersion, refLinks: refLinks)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        weak var table: GridTableView?
        weak var tab: WorkTab?
        var onFollowFK: ((String, String, String?) -> Void)?
        var onInspect: ((Int) -> Void)?
        var onFilterEdit: ((String, FilterCond?, NSView, NSRect) -> Void)?
        var onFilterSet: ((String, FilterCond?) -> Void)?
        private var filtered: Set<String>?   // nil: filters unavailable (query tabs)
        var rowOffset = 0
        private var columns: [String] = []
        private var types: [String] = []
        private var rows: [[String?]] = []
        private var vis: [Int] = []           // visible result column indexes (hidden ones removed)
        private var transpose = false
        private var typeI = -1, rowsI = -1    // MySQL EXPLAIN highlighting (-1: off)
        private var order: [Int]?
        private var version = -1
        private var pendingV = -1
        private var insertCount = 0
        private var colKey = ""
        private var fkCols: Set<Int> = []
        private var refLinks = false
        private var pkCol = -1                // single-column PK: its own UUIDs are not links
        private var numCols: Set<Int> = []
        private var menuColumn = -1, menuRow = -1
        private var lastClickedColumn = -1
        private var sorting = false
        private var fkToken = 0
        private var editCancelled = false
        private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        private let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        private let nullFont: NSFont = {
            let f = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            return NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask)
        }()

        /// Pending insert rows shown above the loaded rows (grid mode only).
        private var nIns: Int { transpose ? 0 : (tab?.inserts.count ?? 0) }

        func update(result: QueryResult, version v: Int, info: TableInfo?, transpose tp: Bool, hidden: Set<String>, explain: Bool, pending: Int,
                    refLinks rl: Bool) {
            guard let tv = table else { return }
            var fk: Set<Int> = []
            var tys: [String] = []
            for (i, name) in result.columns.enumerated() {
                let ci = info?.columns.first { $0.name == name }
                if ci?.fk != nil { fk.insert(i) }
                tys.append(ci?.type ?? "")
            }
            let visible = result.columns.indices.filter { !hidden.contains(result.columns[$0]) }
            var num: Set<Int> = []
            if v == version && tys == types { num = numCols } else { for i in result.columns.indices {
                if !tys[i].isEmpty { if isNumericType(tys[i]) { num.insert(i) }; continue }
                let vals = result.rows.prefix(60).compactMap { i < $0.count ? $0[i] : nil }
                if !vals.isEmpty, vals.allSatisfy({ $0.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil }) { num.insert(i) }
            } }
            let key = zip(result.columns, tys).map { "\($0)\u{1}\($1)" }.joined(separator: "\u{2}")
                + "|\(fk.sorted())|N\(num.sorted())|T\(tp)|V\(visible)|E\(explain)|R\(rl)"
            let dataChanged = v != version
            let pendingChanged = pending != pendingV
            guard dataChanged || key != colKey || pendingChanged else { return }
            version = v
            pendingV = pending
            columns = result.columns
            types = tys
            rows = result.rows
            fkCols = fk
            refLinks = rl
            pkCol = info.flatMap { i in i.primaryKey.count == 1 ? result.columns.firstIndex(of: i.primaryKey[0]) : nil } ?? -1
            numCols = num
            vis = visible
            transpose = tp
            typeI = explain ? columns.firstIndex(of: "type") ?? -1 : -1
            rowsI = explain ? columns.firstIndex(of: "rows") ?? -1 : -1
            if key != colKey || (tp && dataChanged) {
                colKey = key
                rebuildColumns(tv)
            }
            applySort()
            let ins = nIns
            let grew = ins > insertCount
            if ins != insertCount { insertCount = ins; if !dataChanged { tv.deselectAll(nil) } }  // row indexes shifted
            tv.reloadData()
            if dataChanged { tv.scrollRowToVisible(0); tv.scrollColumnToVisible(0) }
            else if grew { tv.scrollRowToVisible(0) }
        }

        private func header(_ name: String, type: String, numeric: Bool, dim: Bool = false, filter: Bool = false) -> GridHeaderCell {
            GridHeaderCell(GridHeaderInfo(name: name, typeText: type, numeric: numeric, dim: dim, filterable: filter && filtered != nil,
                                          filtered: filter && filtered?.contains(name) == true))
        }

        /// Filter state changed: refresh the header buttons in place (keeps widths, order and sort).
        func setFiltered(_ f: Set<String>?) {
            guard f != filtered else { return }
            filtered = f
            guard let tv = table, !transpose else { return }
            for c in tv.tableColumns {
                guard let old = c.headerCell.representedObject as? GridHeaderInfo, c.identifier.rawValue.hasPrefix("c") else { continue }
                c.headerCell.representedObject = GridHeaderInfo(name: old.name, typeText: old.typeText, numeric: old.numeric, dim: old.dim,
                                                                filterable: f != nil, filtered: f?.contains(old.name) == true)
            }
            tv.headerView?.needsDisplay = true
        }

        func headerFilter(_ c: Int, _ rect: NSRect) {
            guard let tv = table, let hv = tv.headerView, !transpose, c < tv.tableColumns.count else { return }
            let id = tv.tableColumns[c].identifier.rawValue
            guard id.hasPrefix("c"), let ci = Int(id.dropFirst()), ci < columns.count else { return }
            onFilterEdit?(columns[ci], nil, hv, rect)
        }

        private func textWidth(_ s: String, _ f: NSFont) -> CGFloat { (s as NSString).size(withAttributes: [.font: f]).width }

        private func rebuildColumns(_ tv: GridTableView) {
            sorting = true
            tv.sortDescriptors = []
            sorting = false
            for c in tv.tableColumns { tv.removeTableColumn(c) }
            let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
            if transpose { return rebuildTransposed(tv, headerFont) }
            let num = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("#"))
            num.title = "#"
            num.width = 44; num.minWidth = 36; num.maxWidth = 100
            num.headerCell = header("#", type: "", numeric: true, dim: true)
            tv.addTableColumn(num)
            for i in vis {
                let name = columns[i]
                let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(i)"))
                c.title = name
                c.headerCell = header(name, type: types[i], numeric: numCols.contains(i), filter: true)
                c.minWidth = 50
                c.sortDescriptorPrototype = NSSortDescriptor(key: "c\(i)", ascending: true)
                c.headerToolTip = types[i].isEmpty ? name : "\(name): \(types[i])"
                var w = max(textWidth(name, headerFont), textWidth(types[i], NSFont.systemFont(ofSize: 10))) + 28
                    + (filtered != nil ? GridHeaderInfo.filterWidth : 0)
                for r in rows.prefix(60) where i < r.count {
                    if let v = r[i] { w = max(w, textWidth(String(v.prefix(80)), font) + 20) }
                }
                c.width = min(max(w, 60), 380)
                tv.addTableColumn(c)
            }
        }

        /// Transpose: first column = field name, then one column per result row (header = row number).
        private func rebuildTransposed(_ tv: GridTableView, _ headerFont: NSFont) {
            let f = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("f"))
            f.title = "Field"
            f.headerCell = header("Field", type: "", numeric: false)
            f.minWidth = 80
            var fw: CGFloat = 60
            for i in vis { fw = max(fw, textWidth(columns[i], NSFont.systemFont(ofSize: 11, weight: .semibold)) + 16) }
            f.width = min(fw, 260)
            tv.addTableColumn(f)
            let sample = Array(vis.prefix(40))
            for (ri, row) in rows.enumerated() {
                let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("r\(ri)"))
                c.title = String(rowOffset + ri + 1)
                c.headerCell = header(c.title, type: "", numeric: false)
                c.minWidth = 50
                c.headerToolTip = "All fields of the row"
                var w: CGFloat = textWidth(c.title, headerFont) + 28
                for i in sample where i < row.count {
                    if let v = row[i] { w = max(w, textWidth(String(v.prefix(60)), font) + 16) }
                }
                c.width = min(max(w, 70), 280)
                tv.addTableColumn(c)
            }
        }

        // sorting (grid mode only)
        private func applySort() {
            guard !transpose, let tv = table, let d = tv.sortDescriptors.first, let key = d.key, key.hasPrefix("c"),
                  let ci = Int(key.dropFirst()), ci < columns.count else { order = nil; return }
            let asc = d.ascending
            let keys: [(Double?, String?)] = rows.map { r in
                guard ci < r.count, let v = r[ci] else { return (nil, nil) }
                return (Double(v), v)
            }
            order = Array(rows.indices).sorted { a, b in
                let ka = keys[a], kb = keys[b]
                if ka.1 == nil { return false }          // NULLs last in either direction
                if kb.1 == nil { return true }
                let cmp: ComparisonResult
                if let x = ka.0, let y = kb.0 { cmp = x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame) }
                else { cmp = ka.1!.localizedStandardCompare(kb.1!) }
                if cmp == .orderedSame { return a < b }
                return asc ? cmp == .orderedAscending : cmp == .orderedDescending
            }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !sorting else { return }
            applySort()
            tableView.reloadData()
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard transpose, let r = rowIndex(of: tableColumn.identifier.rawValue) else { return }
            onInspect?(r)
        }

        private func orig(_ row: Int) -> Int { order.map { row < $0.count ? $0[row] : row } ?? row }

        /// Loaded-result row behind a grid row (nil for pending insert rows).
        private func resultRow(_ display: Int) -> Int? {
            let r = display - nIns
            return r >= 0 && r < rows.count ? orig(r) : nil
        }

        /// "r12" → 12 (transpose row-column id)
        private func rowIndex(of id: String) -> Int? {
            guard id.hasPrefix("r"), let n = Int(id.dropFirst()), n < rows.count else { return nil }
            return n
        }

        private func isBad(_ ci: Int, _ v: String?) -> Bool {
            guard let v else { return false }
            return (ci == typeI && v == "ALL") || (ci == rowsI && (Double(v) ?? 0) > 100_000)
        }

        /// Value of a loaded row's cell including pending edits.
        private func cellValue(_ o: Int, _ ci: Int) -> String? {
            if let e = tab?.edits[o]?[columns[ci]] { return e.value }
            return ci < rows[o].count ? rows[o][ci] : nil
        }

        /// Real FK column, or a UUID value in another column when implicit references are on.
        private func isLink(_ ci: Int, _ v: String?) -> Bool {
            guard let v else { return false }
            return fkCols.contains(ci) || (refLinks && ci != pkCol && Refs.isUUID(v))
        }

        func numberOfRows(in tableView: NSTableView) -> Int { transpose ? vis.count : nIns + rows.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let v = (tableView.makeView(withIdentifier: GridRowView.id, owner: nil) as? GridRowView) ?? {
                let n = GridRowView(); n.identifier = GridRowView.id; return n
            }()
            v.tint = nil
            v.bad = false
            guard !transpose else { return v }
            if let o = resultRow(row) {
                v.bad = typeI >= 0 && typeI < rows[o].count && rows[o][typeI] == "ALL"
                if tab?.deleted.contains(o) == true { v.tint = NSColor.systemRed.withAlphaComponent(0.20) }
            } else if row < nIns {
                v.tint = NSColor.systemGreen.withAlphaComponent(0.22)
            }
            return v
        }

        /// Single-line cell text. A cell is at most ~380pt wide, so lay out only a short prefix: truncating multi-KB
        /// strings made CoreText typeset every big value on each vertical scroll (90% CPU on wide tables).
        static func display(_ v: String) -> String {
            let s = v.utf8.count > 400 ? String(v.prefix(300)) + "…" : v
            guard s.contains(where: \.isNewline) else { return s }
            return s.replacingOccurrences(of: "\r\n", with: "↵").replacingOccurrences(of: "\n", with: "↵").replacingOccurrences(of: "\r", with: "↵")
        }

        private func style(_ cell: GridCell, value v: String?, column ci: Int, edited: Bool = false, strike: Bool = false, blank: Bool = false) {
            let l = cell.label
            let right = !transpose && numCols.contains(ci)
            l.alignment = right ? .right : .left
            cell.setNull(false, right: right)
            cell.tint = edited ? NSColor.systemYellow.withAlphaComponent(0.34) : nil
            if let v {
                let bad = isBad(ci, v)
                l.font = bad ? boldFont : font
                l.textColor = strike ? .secondaryLabelColor : (bad ? .systemOrange : (isLink(ci, v) ? .linkColor
                    : v == Refs.emptyUUID ? .tertiaryLabelColor : .labelColor))
                l.stringValue = Self.display(v)
                let n = v.utf8.count  // O(1); String.count is O(n) and ran for every visible cell on each scroll
                cell.toolTip = n < 24 ? nil : n > 500 ? String(v.prefix(500)) + "…" : v
            } else if blank {
                l.font = font
                l.textColor = .tertiaryLabelColor
                l.stringValue = ""
                cell.toolTip = nil
            } else {
                l.font = font
                l.stringValue = ""
                cell.setNull(true, right: right)
                cell.toolTip = nil
            }
            if strike {
                let ps = NSMutableParagraphStyle()
                ps.lineBreakMode = .byTruncatingTail
                ps.alignment = l.alignment
                l.attributedStringValue = NSAttributedString(string: l.stringValue, attributes: [
                    .font: l.font ?? font, .foregroundColor: l.textColor ?? NSColor.secondaryLabelColor,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue, .paragraphStyle: ps])
            }
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn else { return nil }
            let cell = (tableView.makeView(withIdentifier: ResultGrid.cellID, owner: nil) as? GridCell) ?? GridCell(frame: .zero)
            cell.label.delegate = self
            cell.endEditing()
            let id = tableColumn.identifier.rawValue
            let l = cell.label
            cell.setNull(false, right: false)
            cell.isFK = false
            cell.hover = false
            if transpose {
                cell.tint = nil
                guard row < vis.count else { return cell }
                let ci = vis[row]
                if id == "f" {
                    l.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
                    l.textColor = .labelColor
                    l.alignment = .left
                    l.stringValue = columns[ci]
                    cell.toolTip = types[ci].isEmpty ? columns[ci] : types[ci]
                } else if let ri = rowIndex(of: id) {
                    style(cell, value: cellValue(ri, ci), column: ci, edited: tab?.isEdited(row: ri, column: columns[ci]) == true,
                          strike: tab?.deleted.contains(ri) == true)
                }
                return cell
            }
            let o = resultRow(row)
            if id == "#" {
                cell.tint = nil
                l.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                l.textColor = .tertiaryLabelColor
                l.stringValue = o.map { String(rowOffset + $0 + 1) } ?? "+"
                l.alignment = .right
                cell.toolTip = nil
                return cell
            }
            let ci = Int(id.dropFirst()) ?? 0
            cell.isFK = o.map { ci < columns.count && isLink(ci, cellValue($0, ci)) } ?? false
            cell.hover = row == (tableView as? GridTableView)?.hoverRow
            if let o {
                style(cell, value: ci < columns.count ? cellValue(o, ci) : nil, column: ci,
                      edited: ci < columns.count && tab?.isEdited(row: o, column: columns[ci]) == true,
                      strike: tab?.deleted.contains(o) == true)
            } else {
                let nv = ci < columns.count && row < (tab?.inserts.count ?? 0) ? tab?.inserts[row][columns[ci]] : nil
                style(cell, value: nv?.value, column: ci, blank: nv == nil)
            }
            return cell
        }

        // MARK: selection

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tv = table, let tab else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                var rs = Set<Int>(), ins = Set<Int>()
                if !self.transpose {
                    for r in tv.selectedRowIndexes {
                        if let o = self.resultRow(r) { rs.insert(o) } else if r < self.nIns { ins.insert(r) }
                    }
                }
                if tab.selectedRows != rs { tab.selectedRows = rs }
                if tab.selectedInserts != ins { tab.selectedInserts = ins }
            }
        }

        // MARK: interaction

        /// (row, column) behind a table cell, in either mode; `insert` rows index `WorkTab.inserts`. Nil for the "#" / "Field" columns.
        private func cellTarget(row r: Int, column c: Int) -> (row: Int, col: Int, insert: Bool)? {
            guard let tv = table, r >= 0, c >= 0, c < tv.tableColumns.count else { return nil }
            let id = tv.tableColumns[c].identifier.rawValue
            if transpose {
                guard r < vis.count, let ri = rowIndex(of: id) else { return nil }
                return (ri, vis[r], false)
            }
            guard id.hasPrefix("c"), let ci = Int(id.dropFirst()), ci < columns.count else { return nil }
            if let o = resultRow(r) { return (o, ci, false) }
            return r >= 0 && r < nIns ? (r, ci, true) : nil
        }

        private func value(of t: (row: Int, col: Int, insert: Bool)) -> String? {
            if t.insert { return tab?.inserts[t.row][columns[t.col]]?.value }
            return cellValue(t.row, t.col)
        }

        @objc func clicked(_ sender: NSTableView) {
            lastClickedColumn = sender.clickedColumn
            if (NSApp.currentEvent?.clickCount ?? 1) > 1 { fkToken += 1; return }
            guard let t = cellTarget(row: sender.clickedRow, column: sender.clickedColumn), !t.insert,
                  let v = cellValue(t.row, t.col), isLink(t.col, v) else { return }
            let col = columns[t.col]
            let hint = Refs.hintColumn(for: col, in: columns).flatMap { h in columns.firstIndex(of: h) }.flatMap { cellValue(t.row, $0) }
            if tab?.canEdit == true {
                // double-click edits the cell: follow the link only when no second click arrives
                fkToken += 1
                let tok = fkToken
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(Int(NSEvent.doubleClickInterval * 1000) + 40))
                    guard let self, self.fkToken == tok else { return }
                    self.onFollowFK?(col, v, hint)
                }
            } else {
                onFollowFK?(col, v, hint)
            }
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            fkToken += 1
            let r = sender.clickedRow, c = sender.clickedColumn
            if transpose {
                guard c >= 0, c < sender.tableColumns.count, let ri = rowIndex(of: sender.tableColumns[c].identifier.rawValue) else { return }
                onInspect?(ri)
                return
            }
            guard r >= 0, r < numberOfRows(in: sender) else { return }
            if let tab, tab.tableName != nil, cellTarget(row: r, column: c) != nil {
                if tab.canEdit { beginEdit(row: r, column: c); return }
                if let why = tab.editBlockReason { tab.flashHint(why) }
            }
            if let o = resultRow(r) { onInspect?(o) }
        }

        func inspectSelected() {
            guard let tv = table else { return }
            if transpose {
                if lastClickedColumn >= 0, lastClickedColumn < tv.tableColumns.count,
                   let ri = rowIndex(of: tv.tableColumns[lastClickedColumn].identifier.rawValue) { onInspect?(ri) }
                return
            }
            guard let r = tv.selectedRowIndexes.first, let o = resultRow(r) else { return }
            onInspect?(o)
        }

        // MARK: inline editing

        /// Return on a selected cell edits it (table tabs only).
        func beginEditSelected() -> Bool {
            guard let tv = table, let tab, tab.tableName != nil, !transpose, let r = tv.selectedRowIndexes.first else { return false }
            guard tab.canEdit else {
                if let why = tab.editBlockReason { tab.flashHint(why) }
                return false
            }
            var c = lastClickedColumn
            if c < 0 || c >= tv.tableColumns.count || cellTarget(row: r, column: c) == nil {
                c = tv.tableColumns.indices.first { cellTarget(row: r, column: $0) != nil } ?? -1
            }
            guard c >= 0 else { return false }
            beginEdit(row: r, column: c)
            return true
        }

        func beginEdit(row r: Int, column c: Int) {
            guard let tv = table, let tab, !transpose, let t = cellTarget(row: r, column: c) else { return }
            let name = columns[t.col]
            if !t.insert, tab.deleted.contains(t.row) { return }
            guard tab.isEditable(name) else {
                if tab.isBinary(name) { tab.flashHint("Binary column '\(name)' can't be edited") }
                return
            }
            let v = value(of: t)
            if let v, v.contains("\n") || v.count > 400 {
                tab.editSheet = CellRef(insert: t.insert, row: t.row, column: name)
                return
            }
            guard let cell = tv.view(atColumn: c, row: r, makeIfNecessary: true) as? GridCell else { return }
            editCancelled = false
            tv.scrollRowToVisible(r)
            cell.beginEditing(text: v ?? "", font: font)
            tv.editColumn(c, row: r, with: nil, select: true)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) { editCancelled = true }
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField, let tv = table, let cell = tf.superview as? GridCell else { return }
            let r = tv.row(for: cell), c = tv.column(for: cell)
            let text = tf.stringValue
            let cancelled = editCancelled
            editCancelled = false
            cell.endEditing()
            if !cancelled, r >= 0, c >= 0, let tab, let t = cellTarget(row: r, column: c) {
                let name = columns[t.col]
                let cur = value(of: t)
                let isBlankInsert = t.insert && tab.inserts[t.row][name] == nil
                if !((cur == nil || isBlankInsert) && text.isEmpty) && text != cur {
                    tab.setCell(CellRef(insert: t.insert, row: t.row, column: name), to: text)
                }
            }
            if r >= 0 { tv.reloadData(forRowIndexes: IndexSet(integer: r), columnIndexes: IndexSet(0..<tv.numberOfColumns)) }
        }

        // MARK: copy

        func copyRows(json: Bool) {
            guard let tv = table else { return }
            if transpose {
                let sel = tv.selectedRowIndexes.filter { $0 < vis.count }
                guard !sel.isEmpty else { return }
                let heads = ["Field"] + rows.indices.map { String(rowOffset + $0 + 1) }
                let lines: [[String?]] = sel.map { f in
                    let ci = vis[f]
                    return [columns[ci]] + rows.indices.map { cellValue($0, ci) }
                }
                copyToPasteboard(Export.tsv(columns: heads, rows: lines))
                return
            }
            let sel = tv.selectedRowIndexes.compactMap(resultRow)
            guard !sel.isEmpty else { return }
            let cols = vis.map { columns[$0] }
            let rs = sel.map { r in vis.map { cellValue(r, $0) } }
            copyToPasteboard(json ? Export.json(columns: cols, rows: rs) : Export.tsv(columns: cols, rows: rs))
        }

        func menu(at p: NSPoint) -> NSMenu? {
            guard let tv = table else { return nil }
            let r = tv.row(at: p)
            menuColumn = tv.column(at: p)
            menuRow = r
            guard r >= 0 else { return nil }
            if !tv.selectedRowIndexes.contains(r) { tv.selectRowIndexes([r], byExtendingSelection: false) }
            let m = NSMenu()
            m.autoenablesItems = false
            func add(_ title: String, _ sel: Selector, enabled: Bool = true) {
                let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
                item.target = self
                item.isEnabled = enabled
                m.addItem(item)
            }
            if let tab, tab.tableName != nil, filtered != nil, !transpose, let t = cellTarget(row: r, column: menuColumn), !t.insert {
                addFilterItems(m, column: columns[t.col], value: cellValue(t.row, t.col), row: r, col: menuColumn)
                m.addItem(.separator())
            }
            if let tab, tab.canEdit, !transpose {
                let t = cellTarget(row: r, column: menuColumn)
                let name = t.map { columns[$0.col] }
                let rowDeleted = t.map { !$0.insert && tab.deleted.contains($0.row) } ?? false
                let editable = name.map { tab.isEditable($0) } ?? false
                let nullable = name.flatMap { tab.columnInfo($0)?.nullable } ?? false
                add("Set NULL", #selector(setNull), enabled: editable && nullable && !rowDeleted)
                add("Edit…", #selector(editInSheet), enabled: editable && !rowDeleted)
                add("Revert Change", #selector(revertChange), enabled: t.map { revertible($0, tab) } ?? false)
                m.addItem(.separator())
                add(tv.selectedRowIndexes.count > 1 ? "Delete Rows" : "Delete Row", #selector(deleteRowsAction))
                add("Duplicate Row", #selector(duplicateRowAction), enabled: !rowDeleted)
                m.addItem(.separator())
            }
            if transpose {
                add("Copy Cell", #selector(copyCell)); add("Copy Fields as TSV", #selector(copyTSV))
            } else {
                add("Copy Cell", #selector(copyCell)); add("Copy Row as JSON", #selector(copyRowJSON))
                add("Copy Rows as TSV", #selector(copyTSV)); add("Copy Rows as JSON", #selector(copyJSON))
            }
            return m
        }

        /// Right-click → one-click filters by the cell's value (= ≠ > < is NULL); contains / more open the editor.
        private func addFilterItems(_ m: NSMenu, column: String, value v: String?, row: Int, col: Int) {
            m.addItem(.sectionHeader(title: "Filter \(column)"))
            func item(_ title: String, _ fn: @escaping () -> Void) {
                let a = MenuAction(fn)
                let it = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
                it.target = a
                it.representedObject = a
                m.addItem(it)
            }
            let set = { [weak self] (c: FilterCond) in self?.onFilterSet?(column, c) }
            let edit = { [weak self] (c: FilterCond?) in
                guard let self, let tv = self.table else { return }
                self.onFilterEdit?(column, c, tv, tv.frameOfCell(atColumn: col, row: row))
            }
            if let v {
                let s = FilterOps.short(v)
                item("= \(s)") { set(FilterCond(op: "eq", value: v)) }
                item("≠ \(s)") { set(FilterCond(op: "ne", value: v)) }
                item("contains \(s)…") { edit(FilterCond(op: "contains", value: v)) }
                item("> \(s)") { set(FilterCond(op: "gt", value: v)) }
                item("< \(s)") { set(FilterCond(op: "lt", value: v)) }
                item("is NULL") { set(FilterCond(op: "null")) }
            } else {
                item("is NULL") { set(FilterCond(op: "null")) }
                item("is not NULL") { set(FilterCond(op: "not_null")) }
            }
            item("More Filters…") { edit(nil) }
            if filtered?.contains(column) == true { item("Clear Filter") { [weak self] in self?.onFilterSet?(column, nil) } }
        }

        private func revertible(_ t: (row: Int, col: Int, insert: Bool), _ tab: WorkTab) -> Bool {
            if t.insert { return true }
            return tab.deleted.contains(t.row) || tab.isEdited(row: t.row, column: columns[t.col])
        }

        private func menuRef() -> CellRef? {
            guard let t = cellTarget(row: menuRow, column: menuColumn) else { return nil }
            return CellRef(insert: t.insert, row: t.row, column: columns[t.col])
        }

        @objc func setNull() { if let ref = menuRef() { tab?.setCell(ref, to: nil) } }
        @objc func editInSheet() { if let ref = menuRef() { tab?.editSheet = ref } }
        @objc func revertChange() { if let ref = menuRef() { tab?.revert(ref) } }
        @objc func deleteRowsAction() {
            guard let tv = table, let tab else { return }
            var rs = Set<Int>(), ins = Set<Int>()
            for r in tv.selectedRowIndexes { if let o = resultRow(r) { rs.insert(o) } else if r < nIns { ins.insert(r) } }
            tab.deleteRows(result: rs, inserts: ins)
        }
        @objc func duplicateRowAction() {
            guard let tab, menuRow >= 0 else { return }
            if let o = resultRow(menuRow) { tab.duplicate(row: o) } else if menuRow < nIns { tab.duplicate(insert: menuRow) }
        }

        @objc func copyCell() {
            guard let tv = table else { return }
            if let t = cellTarget(row: menuRow, column: menuColumn) {
                if t.insert { copyToPasteboard(value(of: t) ?? "NULL") }
                else if t.col < rows[t.row].count { copyToPasteboard(cellValue(t.row, t.col) ?? "NULL") }
            } else if transpose, menuRow >= 0, menuRow < vis.count, menuColumn >= 0, menuColumn < tv.tableColumns.count,
                      tv.tableColumns[menuColumn].identifier.rawValue == "f" {
                copyToPasteboard(columns[vis[menuRow]])
            }
        }
        @objc func copyRowJSON() {
            guard let tv = table, let r = tv.selectedRowIndexes.first, let o = resultRow(r) else { return }
            copyToPasteboard(Export.jsonObject(columns: vis.map { columns[$0] }, row: vis.map { cellValue(o, $0) }, indent: ""))
        }
        @objc func copyTSV() { copyRows(json: false) }
        @objc func copyJSON() { copyRows(json: true) }
    }
}
