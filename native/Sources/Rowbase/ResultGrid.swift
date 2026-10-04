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
                    Text(e).font(.system(size: 12, design: .monospaced)).foregroundStyle(.red)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
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
                               onFollowFK: tab.isQuery ? nil : { col, val in state.followFK(from: tab, column: col, value: val) },
                               onInspect: { state.inspect(tab, row: $0) })
                    }
                }
            } else if !tab.running {
                Text(tab.isQuery ? "Write a query and press ⌘↩" : "").foregroundStyle(.tertiary)
            }
            if tab.running {
                ProgressView().controlSize(.small).padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PlanText: View {
    let lines: [String]
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    Text(l.isEmpty ? " " : l)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(l.contains("Seq Scan") ? Color.orange : Color.primary)
                        .fixedSize()
                }
            }
            .textSelection(.enabled)
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

final class GridCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    /// Background tint for edited cells (re-resolved on appearance change).
    var tint: NSColor? { didSet { applyTint() } }

    private func applyTint() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = tint?.cgColor }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyTint() }

    func beginEditing(text: String, font: NSFont) {
        label.isEditable = true
        label.isSelectable = true
        label.drawsBackground = true
        label.backgroundColor = .textBackgroundColor
        label.font = font
        label.textColor = .labelColor
        label.alignment = .left
        label.stringValue = text
    }

    func endEditing() {
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        identifier = ResultGrid.cellID
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.cell?.truncatesLastVisibleLine = true
        label.maximumNumberOfLines = 1
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
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
    var onFollowFK: ((String, String) -> Void)?
    var onInspect: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator
        let tv = GridTableView()
        tv.usesAlternatingRowBackgroundColors = true
        tv.allowsMultipleSelection = true
        tv.allowsColumnResizing = true
        tv.allowsColumnReordering = true
        tv.columnAutoresizingStyle = .noColumnAutoresizing
        tv.rowHeight = 20
        tv.intercellSpacing = NSSize(width: 6, height: 0)
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
        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let c = context.coordinator
        c.onFollowFK = onFollowFK
        c.onInspect = onInspect
        c.rowOffset = rowOffset
        c.tab = editTab
        c.update(result: result, version: version, info: info, transpose: transpose, hidden: hidden, explain: explainMySQL,
                 pending: pendingVersion)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        weak var table: GridTableView?
        weak var tab: WorkTab?
        var onFollowFK: ((String, String) -> Void)?
        var onInspect: ((Int) -> Void)?
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

        func update(result: QueryResult, version v: Int, info: TableInfo?, transpose tp: Bool, hidden: Set<String>, explain: Bool, pending: Int) {
            guard let tv = table else { return }
            var fk: Set<Int> = []
            var tys: [String] = []
            for (i, name) in result.columns.enumerated() {
                let ci = info?.columns.first { $0.name == name }
                if ci?.fk != nil { fk.insert(i) }
                tys.append(ci?.type ?? "")
            }
            let visible = result.columns.indices.filter { !hidden.contains(result.columns[$0]) }
            let key = zip(result.columns, tys).map { "\($0)\u{1}\($1)" }.joined(separator: "\u{2}")
                + "|\(fk.sorted())|T\(tp)|V\(visible)|E\(explain)"
            let dataChanged = v != version
            let pendingChanged = pending != pendingV
            guard dataChanged || key != colKey || pendingChanged else { return }
            version = v
            pendingV = pending
            columns = result.columns
            types = tys
            rows = result.rows
            fkCols = fk
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
            num.width = 48; num.minWidth = 36; num.maxWidth = 100
            tv.addTableColumn(num)
            for i in vis {
                let name = columns[i]
                let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(i)"))
                c.title = name
                c.minWidth = 50
                c.sortDescriptorPrototype = NSSortDescriptor(key: "c\(i)", ascending: true)
                c.headerToolTip = types[i].isEmpty ? name : "\(name): \(types[i])"
                var w = textWidth(name, headerFont) + 28
                for r in rows.prefix(60) where i < r.count {
                    if let v = r[i] { w = max(w, textWidth(String(v.prefix(80)), font) + 16) }
                }
                c.width = min(max(w, 60), 380)
                tv.addTableColumn(c)
            }
        }

        /// Transpose: first column = field name, then one column per result row (header = row number).
        private func rebuildTransposed(_ tv: GridTableView, _ headerFont: NSFont) {
            let f = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("f"))
            f.title = "Field"
            f.minWidth = 80
            var fw: CGFloat = 60
            for i in vis { fw = max(fw, textWidth(columns[i], NSFont.systemFont(ofSize: 11, weight: .semibold)) + 16) }
            f.width = min(fw, 260)
            tv.addTableColumn(f)
            let sample = Array(vis.prefix(40))
            for (ri, row) in rows.enumerated() {
                let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("r\(ri)"))
                c.title = String(rowOffset + ri + 1)
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

        private func style(_ cell: GridCell, value v: String?, column ci: Int, edited: Bool = false, strike: Bool = false, blank: Bool = false) {
            let l = cell.label
            l.alignment = .left
            cell.tint = edited ? NSColor.systemYellow.withAlphaComponent(0.34) : nil
            if let v {
                let bad = isBad(ci, v)
                l.font = bad ? boldFont : font
                l.textColor = strike ? .secondaryLabelColor : (bad ? .systemOrange : (fkCols.contains(ci) ? .linkColor : .labelColor))
                let shown = v.count > 2000 ? String(v.prefix(2000)) : v
                l.stringValue = shown.contains("\n") ? shown.replacingOccurrences(of: "\r\n", with: "↵").replacingOccurrences(of: "\n", with: "↵") : shown
                cell.toolTip = v.count > 500 ? String(v.prefix(500)) + "…" : v
            } else if blank {
                l.font = font
                l.textColor = .tertiaryLabelColor
                l.stringValue = ""
                cell.toolTip = nil
            } else {
                l.font = nullFont
                l.textColor = strike ? .secondaryLabelColor : .tertiaryLabelColor
                l.stringValue = "NULL"
                cell.toolTip = nil
            }
            if strike {
                let ps = NSMutableParagraphStyle()
                ps.lineBreakMode = .byTruncatingTail
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
                l.textColor = .secondaryLabelColor
                l.stringValue = o.map { String(rowOffset + $0 + 1) } ?? "+"
                l.alignment = .right
                cell.toolTip = nil
                return cell
            }
            let ci = Int(id.dropFirst()) ?? 0
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
                  fkCols.contains(t.col), let v = cellValue(t.row, t.col) else { return }
            let col = columns[t.col]
            if tab?.canEdit == true {
                // double-click edits the cell: follow the link only when no second click arrives
                fkToken += 1
                let tok = fkToken
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(Int(NSEvent.doubleClickInterval * 1000) + 40))
                    guard let self, self.fkToken == tok else { return }
                    self.onFollowFK?(col, v)
                }
            } else {
                onFollowFK?(col, v)
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
