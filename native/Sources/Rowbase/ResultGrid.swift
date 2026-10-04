import SwiftUI
import AppKit
import RowbaseCore

// MARK: - Result area (grid / plan / error / affected)

struct ResultArea: View {
    let state: AppState
    let tab: WorkTab

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
                    ResultGrid(result: r, version: tab.resultVersion, info: tab.isQuery ? nil : tab.info,
                               rowOffset: tab.isQuery ? 0 : tab.offset,
                               transpose: tab.transpose, hidden: tab.hidden,
                               explainMySQL: tab.isExplain && tab.connection.dialect == .mysql,
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

    @objc func copy(_ sender: Any?) { onCopy?() }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " && event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            onSpace?()
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
    override init(frame: NSRect) {
        super.init(frame: frame)
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
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if bad {
            NSColor.systemOrange.withAlphaComponent(0.16).setFill()
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
        c.update(result: result, version: version, info: info, transpose: transpose, hidden: hidden, explain: explainMySQL)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: GridTableView?
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
        private var colKey = ""
        private var fkCols: Set<Int> = []
        private var menuColumn = -1, menuRow = -1
        private var lastClickedColumn = -1
        private var sorting = false
        private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        private let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        private let nullFont: NSFont = {
            let f = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            return NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask)
        }()

        func update(result: QueryResult, version v: Int, info: TableInfo?, transpose tp: Bool, hidden: Set<String>, explain: Bool) {
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
            guard dataChanged || key != colKey else { return }
            version = v
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
            tv.reloadData()
            if dataChanged { tv.scrollRowToVisible(0); tv.scrollColumnToVisible(0) }
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

        /// "r12" → 12 (transpose row-column id)
        private func rowIndex(of id: String) -> Int? {
            guard id.hasPrefix("r"), let n = Int(id.dropFirst()), n < rows.count else { return nil }
            return n
        }

        private func isBad(_ ci: Int, _ v: String?) -> Bool {
            guard let v else { return false }
            return (ci == typeI && v == "ALL") || (ci == rowsI && (Double(v) ?? 0) > 100_000)
        }

        func numberOfRows(in tableView: NSTableView) -> Int { transpose ? vis.count : rows.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let v = (tableView.makeView(withIdentifier: GridRowView.id, owner: nil) as? GridRowView) ?? {
                let n = GridRowView(); n.identifier = GridRowView.id; return n
            }()
            v.bad = !transpose && typeI >= 0 && row < rows.count && typeI < rows[orig(row)].count && rows[orig(row)][typeI] == "ALL"
            return v
        }

        private func style(_ cell: GridCell, value v: String?, column ci: Int) {
            let l = cell.label
            l.alignment = .left
            if let v {
                let bad = isBad(ci, v)
                l.font = bad ? boldFont : font
                l.textColor = bad ? .systemOrange : (fkCols.contains(ci) ? .linkColor : .labelColor)
                let shown = v.count > 2000 ? String(v.prefix(2000)) : v
                l.stringValue = shown.contains("\n") ? shown.replacingOccurrences(of: "\r\n", with: "↵").replacingOccurrences(of: "\n", with: "↵") : shown
                cell.toolTip = v.count > 500 ? String(v.prefix(500)) + "…" : v
            } else {
                l.font = nullFont
                l.textColor = .tertiaryLabelColor
                l.stringValue = "NULL"
                cell.toolTip = nil
            }
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn else { return nil }
            let cell = (tableView.makeView(withIdentifier: ResultGrid.cellID, owner: nil) as? GridCell) ?? GridCell(frame: .zero)
            let id = tableColumn.identifier.rawValue
            let l = cell.label
            if transpose {
                guard row < vis.count else { return cell }
                let ci = vis[row]
                if id == "f" {
                    l.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
                    l.textColor = .labelColor
                    l.alignment = .left
                    l.stringValue = columns[ci]
                    cell.toolTip = types[ci].isEmpty ? columns[ci] : types[ci]
                } else if let ri = rowIndex(of: id) {
                    style(cell, value: ci < rows[ri].count ? rows[ri][ci] : nil, column: ci)
                }
                return cell
            }
            let o = orig(row)
            if id == "#" {
                l.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                l.textColor = .secondaryLabelColor
                l.stringValue = String(rowOffset + o + 1)
                l.alignment = .right
                cell.toolTip = nil
                return cell
            }
            let ci = Int(id.dropFirst()) ?? 0
            style(cell, value: ci < rows[o].count ? rows[o][ci] : nil, column: ci)
            return cell
        }

        // interaction

        /// (result row, result column) behind a table cell, in either mode; nil for the "#" / "Field" columns.
        private func cellTarget(row r: Int, column c: Int) -> (row: Int, col: Int)? {
            guard let tv = table, r >= 0, c >= 0, c < tv.tableColumns.count else { return nil }
            let id = tv.tableColumns[c].identifier.rawValue
            if transpose {
                guard r < vis.count, let ri = rowIndex(of: id) else { return nil }
                return (ri, vis[r])
            }
            guard id.hasPrefix("c"), let ci = Int(id.dropFirst()), ci < columns.count, r < rows.count else { return nil }
            return (orig(r), ci)
        }

        @objc func clicked(_ sender: NSTableView) {
            lastClickedColumn = sender.clickedColumn
            guard let t = cellTarget(row: sender.clickedRow, column: sender.clickedColumn),
                  fkCols.contains(t.col), let v = rows[t.row][t.col] else { return }
            onFollowFK?(columns[t.col], v)
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            let r = sender.clickedRow, c = sender.clickedColumn
            if transpose {
                guard c >= 0, c < sender.tableColumns.count, let ri = rowIndex(of: sender.tableColumns[c].identifier.rawValue) else { return }
                onInspect?(ri)
                return
            }
            guard r >= 0, r < rows.count else { return }
            onInspect?(orig(r))
        }

        func inspectSelected() {
            guard let tv = table else { return }
            if transpose {
                if lastClickedColumn >= 0, lastClickedColumn < tv.tableColumns.count,
                   let ri = rowIndex(of: tv.tableColumns[lastClickedColumn].identifier.rawValue) { onInspect?(ri) }
                return
            }
            guard let r = tv.selectedRowIndexes.first, r < rows.count else { return }
            onInspect?(orig(r))
        }

        func copyRows(json: Bool) {
            guard let tv = table else { return }
            if transpose {
                let sel = tv.selectedRowIndexes.filter { $0 < vis.count }
                guard !sel.isEmpty else { return }
                let heads = ["Field"] + rows.indices.map { String(rowOffset + $0 + 1) }
                let lines: [[String?]] = sel.map { f in
                    let ci = vis[f]
                    return [columns[ci]] + rows.map { r in ci < r.count ? r[ci] : nil }
                }
                copyToPasteboard(Export.tsv(columns: heads, rows: lines))
                return
            }
            let sel = tv.selectedRowIndexes.filter { $0 < rows.count }.map(orig)
            guard !sel.isEmpty else { return }
            let cols = vis.map { columns[$0] }
            let rs = sel.map { r in vis.map { $0 < rows[r].count ? rows[r][$0] : nil } }
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
            let items: [(String, Selector)] = transpose
                ? [("Copy Cell", #selector(copyCell)), ("Copy Fields as TSV", #selector(copyTSV))]
                : [("Copy Cell", #selector(copyCell)), ("Copy Row as JSON", #selector(copyRowJSON)),
                   ("Copy Rows as TSV", #selector(copyTSV)), ("Copy Rows as JSON", #selector(copyJSON))]
            for (title, sel) in items {
                let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
                item.target = self
                m.addItem(item)
            }
            return m
        }

        @objc func copyCell() {
            guard let tv = table else { return }
            if let t = cellTarget(row: menuRow, column: menuColumn) {
                if t.col < rows[t.row].count { copyToPasteboard(rows[t.row][t.col] ?? "NULL") }
            } else if transpose, menuRow >= 0, menuRow < vis.count, menuColumn >= 0, menuColumn < tv.tableColumns.count,
                      tv.tableColumns[menuColumn].identifier.rawValue == "f" {
                copyToPasteboard(columns[vis[menuRow]])
            }
        }
        @objc func copyRowJSON() {
            guard let tv = table, let r = tv.selectedRowIndexes.first, r < rows.count else { return }
            let o = orig(r)
            copyToPasteboard(Export.jsonObject(columns: vis.map { columns[$0] }, row: vis.map { $0 < rows[o].count ? rows[o][$0] : nil }, indent: ""))
        }
        @objc func copyTSV() { copyRows(json: false) }
        @objc func copyJSON() { copyRows(json: true) }
    }
}
