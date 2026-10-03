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
                } else if tab.isExplain && tab.connection.dialect == .postgres && r.columns.count == 1 {
                    PlanText(lines: r.rows.map { $0.first.flatMap { $0 } ?? "" })
                } else {
                    ResultGrid(result: r, version: tab.resultVersion, info: tab.isQuery ? nil : tab.info,
                               rowOffset: tab.isQuery ? 0 : tab.offset,
                               onFollowFK: tab.isQuery ? nil : { col, val in state.followFK(from: tab, column: col, value: val) },
                               onInspect: { state.inspect(tab, row: $0) })
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

struct ResultGrid: NSViewRepresentable {
    static let cellID = NSUserInterfaceItemIdentifier("rbcell")

    let result: QueryResult
    let version: Int
    var info: TableInfo?
    var rowOffset = 0
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
        c.update(result: result, version: version, info: info)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: GridTableView?
        var onFollowFK: ((String, String) -> Void)?
        var onInspect: ((Int) -> Void)?
        var rowOffset = 0
        private var columns: [String] = []
        private var rows: [[String?]] = []
        private var order: [Int]?
        private var version = -1
        private var colKey = ""
        private var fkCols: Set<Int> = []
        private var menuColumn = -1
        private var sorting = false
        private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        private let nullFont: NSFont = {
            let f = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            return NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask)
        }()

        func update(result: QueryResult, version v: Int, info: TableInfo?) {
            guard let tv = table else { return }
            var fk: Set<Int> = []
            var types: [String] = []
            for (i, name) in result.columns.enumerated() {
                let ci = info?.columns.first { $0.name == name }
                if ci?.fk != nil { fk.insert(i) }
                types.append(ci?.type ?? "")
            }
            let key = zip(result.columns, types).map { "\($0)\u{1}\($1)" }.joined(separator: "\u{2}") + "|\(fk.sorted())"
            let dataChanged = v != version
            guard dataChanged || key != colKey else { return }
            version = v
            columns = result.columns
            rows = result.rows
            fkCols = fk
            if key != colKey {
                colKey = key
                rebuildColumns(tv, types: types)
            }
            applySort()
            tv.reloadData()
            if dataChanged { tv.scrollRowToVisible(0) }
        }

        private func rebuildColumns(_ tv: GridTableView, types: [String]) {
            sorting = true
            tv.sortDescriptors = []
            sorting = false
            for c in tv.tableColumns { tv.removeTableColumn(c) }
            let num = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("#"))
            num.title = "#"
            num.width = 48; num.minWidth = 36; num.maxWidth = 100
            tv.addTableColumn(num)
            let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
            for (i, name) in columns.enumerated() {
                let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(i)"))
                c.title = name
                c.minWidth = 50
                c.sortDescriptorPrototype = NSSortDescriptor(key: "c\(i)", ascending: true)
                c.headerToolTip = types[i].isEmpty ? name : "\(name): \(types[i])"
                var w = (name as NSString).size(withAttributes: [.font: headerFont]).width + 28
                for r in rows.prefix(60) where i < r.count {
                    if let v = r[i] { w = max(w, (String(v.prefix(80)) as NSString).size(withAttributes: [.font: font]).width + 16) }
                }
                c.width = min(max(w, 60), 380)
                tv.addTableColumn(c)
            }
        }

        // sorting
        private func applySort() {
            guard let tv = table, let d = tv.sortDescriptors.first, let key = d.key, key.hasPrefix("c"),
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

        private func orig(_ row: Int) -> Int { order.map { row < $0.count ? $0[row] : row } ?? row }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn else { return nil }
            let cell = (tableView.makeView(withIdentifier: ResultGrid.cellID, owner: nil) as? GridCell) ?? GridCell(frame: .zero)
            let o = orig(row)
            let id = tableColumn.identifier.rawValue
            let l = cell.label
            if id == "#" {
                l.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                l.textColor = .secondaryLabelColor
                l.stringValue = String(rowOffset + o + 1)
                l.alignment = .right
                cell.toolTip = nil
                return cell
            }
            l.alignment = .left
            let ci = Int(id.dropFirst()) ?? 0
            let v: String? = ci < rows[o].count ? rows[o][ci] : nil
            if let v {
                l.font = font
                l.textColor = fkCols.contains(ci) ? .linkColor : .labelColor
                let shown = v.count > 2000 ? String(v.prefix(2000)) : v
                l.stringValue = shown.contains("\n") ? shown.replacingOccurrences(of: "\r\n", with: "↵").replacingOccurrences(of: "\n", with: "↵") : shown
                cell.toolTip = v.count > 500 ? String(v.prefix(500)) + "…" : v
            } else {
                l.font = nullFont
                l.textColor = .tertiaryLabelColor
                l.stringValue = "NULL"
                cell.toolTip = nil
            }
            return cell
        }

        // interaction
        @objc func clicked(_ sender: NSTableView) {
            let r = sender.clickedRow, c = sender.clickedColumn
            guard r >= 0, c > 0, r < rows.count else { return }
            let ci = c - 1
            guard fkCols.contains(ci), ci < columns.count, let v = rows[orig(r)][ci] else { return }
            onFollowFK?(columns[ci], v)
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            let r = sender.clickedRow
            guard r >= 0, r < rows.count else { return }
            onInspect?(orig(r))
        }

        func inspectSelected() {
            guard let tv = table, let r = tv.selectedRowIndexes.first, r < rows.count else { return }
            onInspect?(orig(r))
        }

        private func selectedOriginals() -> [Int] {
            guard let tv = table else { return [] }
            return tv.selectedRowIndexes.filter { $0 < rows.count }.map(orig)
        }

        func copyRows(json: Bool) {
            let sel = selectedOriginals()
            guard !sel.isEmpty else { return }
            let rs = sel.map { rows[$0] }
            copyToPasteboard(json ? Export.json(columns: columns, rows: rs) : Export.tsv(columns: columns, rows: rs))
        }

        func menu(at p: NSPoint) -> NSMenu? {
            guard let tv = table else { return nil }
            let r = tv.row(at: p)
            menuColumn = tv.column(at: p)
            guard r >= 0 else { return nil }
            if !tv.selectedRowIndexes.contains(r) { tv.selectRowIndexes([r], byExtendingSelection: false) }
            let m = NSMenu()
            for (title, sel) in [("Copy Cell", #selector(copyCell)), ("Copy Row as JSON", #selector(copyRowJSON)),
                                 ("Copy Rows as TSV", #selector(copyTSV)), ("Copy Rows as JSON", #selector(copyJSON))] {
                let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
                item.target = self
                m.addItem(item)
            }
            return m
        }

        @objc func copyCell() {
            guard let tv = table, let r = tv.selectedRowIndexes.first, menuColumn > 0, r < rows.count else { return }
            let ci = menuColumn - 1
            let o = orig(r)
            if ci < rows[o].count { copyToPasteboard(rows[o][ci] ?? "NULL") }
        }
        @objc func copyRowJSON() {
            guard let tv = table, let r = tv.selectedRowIndexes.first, r < rows.count else { return }
            copyToPasteboard(Export.jsonObject(columns: columns, row: rows[orig(r)], indent: ""))
        }
        @objc func copyTSV() { copyRows(json: false) }
        @objc func copyJSON() { copyRows(json: true) }
    }
}
