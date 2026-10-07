import SwiftUI
import AppKit
import RowbaseCore

/// Visual query builder: from + joins, columns (with summaries), conditions, sort, limit → live SQL → normal result grid.
/// Contract: QueryBuilder.selectSQL (shared with rowbase/query.py and the web UI's builder).
struct BuilderTabView: View {
    let state: AppState
    @Bindable var tab: WorkTab
    @State private var tables: [TableEntry] = []
    @State private var infos: [String: TableInfo] = [:]
    @State private var pendingFrom: String?

    private var q: QBModel { tab.builder }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            VerticalSplit(top: HStack(spacing: 0) {
                ScrollView([.vertical, .horizontal]) { form.padding(14).frame(maxWidth: .infinity, alignment: .leading) }
                    .defaultScrollAnchor(.topLeading)  // 2-axis ScrollView centers narrower/wider content otherwise
                Divider()
                preview.frame(width: 320, alignment: .leading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity),
                          bottom: ResultPanel(state: state, tab: tab), topHeight: 400)
        }
        .task { await loadTables() }
        .task(id: q.sources.map(\.table)) { await loadInfos() }
        .confirmationDialog("Start over with another table?", isPresented: Binding(get: { pendingFrom != nil }, set: { if !$0 { pendingFrom = nil } })) {
            Button("Start Over", role: .destructive) { if let t = pendingFrom { resetFrom(t) }; pendingFrom = nil }
        } message: { Text("Joins, columns, conditions and sorting are cleared.") }
    }

    // MARK: toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            if tab.running {
                Button { state.cancel(tab) } label: { Label("Stop", systemImage: "stop.fill") }
                    .tint(.red).buttonStyle(.borderedProminent).help("Stop the running query (⌘.)")
            } else {
                Button { state.run(tab) } label: { Label("Run", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).disabled(q.from.table.isEmpty).help("Run the query (⌘↩)")
            }
            Button { if let s = sql.text { state.openQuery(sql: s, connection: tab.connection) } } label: {
                Label("Edit as SQL", systemImage: "terminal")
            }
            .disabled(sql.text == nil).help("Open the generated SQL in a new SQL tab")
            Spacer(minLength: 0)
            IconButton(symbol: "doc.on.doc", help: "Copy SQL") { if let s = sql.text { copyToPasteboard(s) } }
            IconButton(symbol: "rectangle.split.2x1", help: tab.transpose ? "Back to grid" : "Transpose: rows become columns",
                       active: tab.transpose) { tab.transpose.toggle() }
            ColumnsButton(tab: tab)
            ExportMenu(state: state, tab: tab)
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    // MARK: SQL preview

    private var sql: (text: String?, error: String?) {
        guard !q.from.table.isEmpty else { return (nil, nil) }
        do { return (try QueryBuilder.selectSQL(tab.connection.dialect, q.spec, types: q.types(infos)), nil) }
        catch { return (nil, error.localizedDescription) }
    }

    private var preview: some View {
        let s = sql
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "SQL")
            if let text = s.text {
                ScrollView {
                    SelectableText(attributed: Self.highlight(text, tab.connection.dialect))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(s.error ?? "Choose a table to start.").font(.callout)
                    .foregroundStyle(s.error == nil ? Color.secondary : Color.red)
                Spacer()
            }
            if let n = tab.note, tab.result == nil { Text(n).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .textBackgroundColor))
    }

    @MainActor static func highlight(_ sql: String, _ d: Dialect) -> NSAttributedString {
        let st = NSTextStorage(string: sql)
        SQLHighlighter.apply(to: st, dialect: d)
        return NSAttributedString(attributedString: st)
    }

    // MARK: form

    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Data from") {
                fromRow
                ForEach($tab.builder.joins) { $j in JoinRow(builder: self, join: $j) }
                addButton("Join a table", "plus") {
                    if tab.builder.from.alias.isEmpty { tab.builder.from.alias = q.nextAlias(for: q.from.table, excluding: q.from.id) }
                    tab.builder.joins.append(QBSource(id: "s" + String(UUID().uuidString.prefix(6)).lowercased()))
                }
            }
            section("Columns") {
                if q.columns.isEmpty {
                    hint("All columns (*) — add columns to pick only some, or count / sum / average per group.")
                }
                ForEach($tab.builder.columns) { $c in columnRow($c) }
                HStack(spacing: 12) {
                    addButton("Column", "plus") { tab.builder.columns.append(QBColumn(ref: QBRef(src: q.firstID, col: ""))) }
                    addButton("Count rows", "number") {
                        let named = q.columns.contains { $0.name == "count" }
                        tab.builder.columns.append(QBColumn(ref: QBRef(src: q.firstID, col: "*"), agg: "count", name: named ? "" : "count"))
                    }
                    Toggle("Distinct rows only", isOn: $tab.builder.distinct).toggleStyle(.checkbox)
                        .help("SELECT DISTINCT — drop duplicate result rows")
                }
                if q.columns.contains(where: { !$0.agg.isEmpty }) && q.columns.contains(where: { $0.agg.isEmpty && !$0.ref.col.isEmpty }) {
                    hint("Rows are grouped by the plain (value) columns.")
                }
            }
            section("Conditions") {
                if q.conds.count > 1 {
                    Picker("Rows must match", selection: $tab.builder.match) {
                        Text("all conditions").tag("all")
                        Text("any condition").tag("any")
                    }
                    .fixedSize()
                }
                ForEach($tab.builder.conds) { $c in CondRow(builder: self, cond: $c) }
                addButton("Condition", "plus") { tab.builder.conds.append(QBCond(ref: QBRef(src: q.firstID, col: ""))) }
            }
            section("Sort") {
                ForEach($tab.builder.order) { $o in orderRow($o) }
                HStack(spacing: 12) {
                    addButton("Sort", "plus") { tab.builder.order.append(QBOrder(ref: QBRef(src: q.firstID, col: ""))) }
                    Spacer().frame(width: 8, alignment: .leading)
                    Text("Limit").foregroundStyle(.secondary)
                    TextField("no limit", value: $tab.builder.limit, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 80, alignment: .leading)
                    Text("rows").foregroundStyle(.secondary)
                }
            }
        }
        .controlSize(.small)
        .disabled(tab.running)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: title)
            content()
        }
    }

    private func hint(_ s: String) -> some View { Text(s).font(.caption).foregroundStyle(.secondary) }

    private func addButton(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol) }
            .buttonStyle(.link).font(.callout)
            .disabled(q.from.table.isEmpty)
    }

    /// Actions must not read row Bindings: reading one inside `removeAll` on the same array is an exclusivity violation
    /// (crashed the app) — callers capture the row id while rendering.
    @MainActor static var lastRemove: (() -> Void)?   // snapshot hook ROWBASE_SNAPSHOT_PRESS_REMOVE
    fileprivate func removeButton(_ action: @escaping () -> Void) -> some View {
        if isSnapshot { Self.lastRemove = action }
        return Button(action: action) { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
            .buttonStyle(.plain).help("Remove")
    }

    private var fromRow: some View {
        HStack(spacing: 8) {
            Text("from").foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
            Picker("", selection: Binding(get: { q.from.table }, set: { t in
                if q.from.table.isEmpty || (q.joins.isEmpty && q.columns.isEmpty && q.conds.isEmpty && q.order.isEmpty) { resetFrom(t) }
                else if t != q.from.table { pendingFrom = t }
            })) {
                if q.from.table.isEmpty { Text("Choose a table…").tag("") }
                ForEach(tables) { Text($0.name).tag($0.name) }
            }
            .labelsHidden().fixedSize()
            if q.multi { Text("as \(q.from.alias)").foregroundStyle(.secondary).font(.system(size: 12, design: .monospaced)) }
        }
    }

    private func resetFrom(_ t: String) {
        var m = QBModel()
        m.from.table = t
        m.match = q.match
        m.limit = q.limit
        tab.builder = m
    }

    // MARK: column pickers

    struct Option: Hashable { let tag: String; let label: String }

    static func tag(_ r: QBRef) -> String { r.col.isEmpty ? "" : r.src + "\t" + r.col }
    static func ref(_ tag: String) -> QBRef? {
        guard let i = tag.firstIndex(of: "\t") else { return nil }
        return QBRef(src: String(tag[..<i]), col: String(tag[tag.index(after: i)...]))
    }

    /// Column choices grouped by source; `only` restricts to some sources (join pairs).
    func groups(only: Set<String>? = nil, except: String? = nil) -> [(title: String, options: [Option])] {
        q.sources.filter { s in (only.map { $0.contains(s.id) } ?? true) && s.id != except }.map { s in
            let cols = infos[s.table]?.columns.map(\.name) ?? []
            let prefix = q.multi ? (s.alias.isEmpty ? s.table : s.alias) + "." : ""
            return (q.multi ? "\(s.table) (\(s.alias))" : s.table, cols.map { Option(tag: s.id + "\t" + $0, label: prefix + $0) })
        }
    }

    func columnPicker(_ sel: Binding<String>, groups: [(title: String, options: [Option])], extra: [Option] = [], extraTitle: String = "",
                      width: CGFloat = 200) -> some View {
        Picker("", selection: sel) {
            if sel.wrappedValue.isEmpty { Text("column…").tag("") }
            if !extra.isEmpty { Section(extraTitle) { ForEach(extra, id: \.self) { Text($0.label).tag($0.tag) } } }
            ForEach(groups, id: \.title) { g in
                Section(g.title) { ForEach(g.options, id: \.self) { Text($0.label).tag($0.tag) } }
            }
        }
        .labelsHidden().fixedSize()
    }

    // MARK: rows

    private func columnRow(_ c: Binding<QBColumn>) -> some View {
        let star = c.wrappedValue.agg == "count"
        let id = c.wrappedValue.id
        return HStack(spacing: 8) {
            Picker("", selection: Binding(get: { c.wrappedValue.agg }, set: { a in
                c.wrappedValue.agg = a
                if c.wrappedValue.ref.col == "*" && a != "count" { c.wrappedValue.ref.col = "" }
            })) { ForEach(QBModel.aggs, id: \.key) { Text($0.label).tag($0.key) } }
            .labelsHidden().fixedSize().help("Value, or a summary per group")
            Text("of").foregroundStyle(.secondary).opacity(c.wrappedValue.agg.isEmpty ? 0 : 1)
            columnPicker(Binding(get: { Self.tag(c.wrappedValue.ref) }, set: { if let r = Self.ref($0) { c.wrappedValue.ref = r } }),
                         groups: groups(), extra: star ? [Option(tag: q.firstID + "\t*", label: "all rows (*)")] : [], extraTitle: "Rows")
            TextField("name in result (optional)", text: c.name).textFieldStyle(.roundedBorder).frame(width: 170, alignment: .leading)
            removeButton { tab.builder.columns.removeAll { $0.id == id } }
        }
    }

    private func orderRow(_ o: Binding<QBOrder>) -> some View {
        let aggCols = q.columns.enumerated().filter { !$0.element.agg.isEmpty && !$0.element.ref.col.isEmpty }
        let id = o.wrappedValue.id
        let results = aggCols.map { Option(tag: "agg\t\($0.offset)", label: q.columnLabel($0.element)) }
        let cur: String = {
            let v = o.wrappedValue
            if !v.agg.isEmpty, let i = q.columns.firstIndex(where: { $0.agg == v.agg && $0.ref == v.ref }) { return "agg\t\(i)" }
            return v.agg.isEmpty ? Self.tag(v.ref) : ""
        }()
        return HStack(spacing: 8) {
            Text("by").foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
            columnPicker(Binding(get: { cur }, set: { t in
                if t.hasPrefix("agg\t"), let i = Int(t.dropFirst(4)), i < q.columns.count {
                    o.wrappedValue.ref = q.columns[i].ref
                    o.wrappedValue.agg = q.columns[i].agg
                } else if let r = Self.ref(t) { o.wrappedValue.ref = r; o.wrappedValue.agg = "" }
            }), groups: groups(), extra: results, extraTitle: "Results")
            Picker("", selection: o.desc) {
                Text("A → Z, smallest first").tag(false)
                Text("Z → A, largest first").tag(true)
            }
            .labelsHidden().fixedSize()
            removeButton { tab.builder.order.removeAll { $0.id == id } }
        }
    }

    // MARK: data

    private func loadTables() async {
        if state.selectedConnection == tab.connection, !state.tables.isEmpty { tables = state.tables; return }
        tables = (try? await state.engine.tables(tab.connection)) ?? []
    }

    private func loadInfos() async {
        for s in q.sources where infos[s.table] == nil {
            if let i = try? await state.tableInfo(for: tab.connection, table: s.table) { infos[s.table] = i }
        }
    }

    func suggestPairs(for j: QBSource, table: String) async -> [QBPair] {
        await state.suggestJoinPairs(tab.connection, model: q, join: j.id, table: table)
    }

    /// Tables linked to the current sources by a foreign key (either direction) — offered first when joining.
    var related: Set<String> {
        Set(q.sources.flatMap { s in
            (infos[s.table]?.columns.compactMap { $0.fk?.table } ?? []) + (infos[s.table]?.referencedBy.map(\.table) ?? [])
        })
    }

    var allTables: [TableEntry] { tables }
    func columnType(_ r: QBRef) -> String {
        q.source(r.src).flatMap { infos[$0.table] }?.columns.first { $0.name == r.col }?.type ?? ""
    }
    var model: QBModel { q }
    var builderTab: WorkTab { tab }
    var appState: AppState { state }
}

/// One joined table: table (related ones first), plain-language join type, ON column pairs.
private struct JoinRow: View {
    let builder: BuilderTabView
    @Binding var join: QBSource

    var body: some View {
        let q = builder.model
        let rel = builder.related
        let jid = join.id
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("join").foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                Picker("", selection: Binding(get: { join.table }, set: { t in pick(t) })) {
                    if join.table.isEmpty { Text("Choose a table…").tag("") }
                    let r = builder.allTables.filter { rel.contains($0.name) }
                    if !r.isEmpty { Section("Related (foreign keys)") { ForEach(r) { Text($0.name).tag($0.name) } } }
                    Section("All tables") { ForEach(builder.allTables.filter { !rel.contains($0.name) }) { Text($0.name).tag($0.name) } }
                }
                .labelsHidden().fixedSize()
                if !join.table.isEmpty { Text("as \(join.alias)").foregroundStyle(.secondary).font(.system(size: 12, design: .monospaced)) }
                Picker("", selection: $join.type) { ForEach(QBModel.joinTypes, id: \.key) { Text($0.label).tag($0.key) } }
                    .labelsHidden().fixedSize().help("Which rows to keep")
                builder.removeButton { builder.builderTab.builder = q.joinRemoved(jid) }
            }
            if !join.table.isEmpty {
                ForEach($join.on) { $p in
                    let pid = p.id
                    HStack(spacing: 8) {
                        Text("on").foregroundStyle(.secondary).frame(width: 34, alignment: .trailing).padding(.leading, 20)
                        builder.columnPicker(Binding(get: { BuilderTabView.tag(p.left) }, set: { if let r = BuilderTabView.ref($0) { p.left = r } }),
                                             groups: builder.groups(only: [join.id]), width: 170)
                        Text("=").foregroundStyle(.secondary)
                        builder.columnPicker(Binding(get: { BuilderTabView.tag(p.right) }, set: { if let r = BuilderTabView.ref($0) { p.right = r } }),
                                             groups: builder.groups(only: Set(q.sources.prefix { $0.id != join.id }.map(\.id))), width: 170)
                        if join.on.count > 1 { builder.removeButton { join.on.removeAll { $0.id == pid } } }
                    }
                }
                Button("+ match on another column") {
                    join.on.append(QBPair(left: QBRef(src: join.id, col: ""), right: QBRef(src: q.from.id, col: "")))
                }
                .buttonStyle(.link).font(.caption).padding(.leading, 62)
            }
        }
    }

    private func pick(_ t: String) {
        let id = join.id
        var j = join
        j.table = t
        j.alias = builder.model.nextAlias(for: t, excluding: id)
        join = j
        Task { @MainActor in
            let pairs = await builder.suggestPairs(for: j, table: t)
            if let i = builder.builderTab.builder.joins.firstIndex(where: { $0.id == id }) { builder.builderTab.builder.joins[i].on = pairs }
        }
    }
}

/// One condition: column, operator, value field(s) and a value picker (searchable list with counts).
private struct CondRow: View {
    let builder: BuilderTabView
    @Binding var cond: QBCond
    @State private var picking = false

    private var arity: Int { QueryBuilder.arity(cond.cond.op ?? "eq") }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row
            if let h = FilterOps.hints[cond.cond.op ?? ""] { Text(h).font(.caption).foregroundStyle(.secondary).padding(.leading, 4) }
        }
    }

    private var row: some View {
        let id = cond.id
        return HStack(spacing: 8) {
            builder.columnPicker(Binding(get: { BuilderTabView.tag(cond.ref) }, set: { if let r = BuilderTabView.ref($0) { cond.ref = r } }),
                                 groups: builder.groups(), width: 170)
            Picker("", selection: Binding(get: { cond.cond.op ?? "eq" }, set: { setOp($0) })) {
                ForEach(FilterOps.groups, id: \.title) { g in
                    Section(g.title) { ForEach(g.ops, id: \.self) { Text(FilterOps.label($0)).tag($0) } }
                }
            }
            .labelsHidden().fixedSize()
            if arity != 0 {
                TextField(arity == -1 ? "values, comma separated" : arity == 2 ? "from" : "value", text: valueText)
                    .font(.system(size: 12, design: .monospaced)).textFieldStyle(.roundedBorder).frame(width: 160)
                if arity == 2 {
                    Text("and").foregroundStyle(.secondary)
                    TextField("to", text: Binding(get: { cond.cond.value2 ?? "" }, set: { cond.cond.value2 = $0 }))
                        .font(.system(size: 12, design: .monospaced)).textFieldStyle(.roundedBorder).frame(width: 120)
                }
                Button { picking = true } label: { Image(systemName: "list.bullet.below.rectangle") }
                    .buttonStyle(.borderless).help("Pick from the values in the table")
                    .disabled(cond.ref.col.isEmpty)
                    .popover(isPresented: $picking, arrowEdge: .bottom) { pickPopover }
            }
            builder.removeButton { builder.builderTab.builder.conds.removeAll { $0.id == id } }
        }
    }

    private var valueText: Binding<String> {
        Binding(get: {
            arity == -1 ? (cond.cond.values ?? []).map { $0 ?? "NULL" }.joined(separator: ", ") : cond.cond.value ?? ""
        }, set: { s in
            if arity == -1 {
                cond.cond.values = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    .map { $0 == "NULL" ? nil : $0 }
            } else { cond.cond.value = s }
        })
    }

    private func setOp(_ op: String) {
        let was = arity
        cond.cond.op = op
        let now = QueryBuilder.arity(op)
        if was == -1 && now != -1 { cond.cond.value = (cond.cond.values ?? []).first.flatMap { $0 } ?? "" }
        else if was != -1 && now == -1 { cond.cond.values = (cond.cond.value ?? "").isEmpty ? [] : [cond.cond.value] }
    }

    private var pickPopover: some View {
        let q = builder.model
        let s = q.source(cond.ref.src) ?? q.from
        let conn = builder.builderTab.connection
        return FilterPopover(
            target: FilterTarget(state: builder.appState, connection: conn, table: s.table, column: cond.ref.col,
                                 type: builder.columnType(cond.ref),
                                 validate: { c in _ = try QueryBuilder.filterWhere(conn.dialect, FilterGroup(match: "all", conds: [c])) }),
            initial: cond.cond, showClear: false,
            onApply: { c in if var c { c.col = nil; cond.cond = c } }, onClose: { picking = false })
    }
}
