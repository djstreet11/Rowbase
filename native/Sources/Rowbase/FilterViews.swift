import SwiftUI
import AppKit
import RowbaseCore

/// What a filter popover edits: one column of one table (value list from the server, loaded rows as fallback).
struct FilterTarget {
    let state: AppState
    let connection: Connection
    let table: String
    let column: String
    let type: String
    /// WHERE of the value list (raw WHERE + the other filters); throws → fall back to the loaded rows.
    var baseWhere: @MainActor () throws -> String = { "" }
    /// Fallback values (the loaded page) when the server query fails.
    var localValues: @MainActor (String) -> [(String?, Int)] = { _ in [] }
    /// Throws when the condition can't become SQL (e.g. regex on SQLite) — shown inline instead of applying.
    var validate: @MainActor (FilterCond) throws -> Void = { _ in }
}

/// Column filter editor: operator, searchable value list with counts ("is one of"), or value fields.
struct FilterPopover: View {
    let target: FilterTarget
    let initial: FilterCond?
    var showClear = true
    let onApply: (FilterCond?) -> Void
    let onClose: () -> Void

    @State private var op = "in"
    @State private var value = ""
    @State private var value2 = ""
    @State private var search = ""
    @State private var selected: [String?] = []
    @State private var list: [(String?, Int)] = []
    @State private var extra: [String] = []
    @State private var note = ""
    @State private var error = ""
    @State private var loading = false
    @State private var seeded = false

    private var arity: Int { QueryBuilder.arity(op) }
    private var items: [(String?, Int?)] {
        extra.filter { e in !list.contains { $0.0 == e } }.map { ($0, nil) } + list.map { ($0.0, $0.1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(target.column).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if !target.type.isEmpty { Text(target.type).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1) }
                Spacer(minLength: 0)
            }
            Picker("", selection: $op) {
                ForEach(FilterOps.groups, id: \.title) { g in
                    Section(g.title) { ForEach(g.ops, id: \.self) { Text(FilterOps.label($0)).tag($0) } }
                }
            }
            .labelsHidden().pickerStyle(.menu)
            if arity == -1 { valueList } else if arity > 0 { fields }
            if let h = FilterOps.hints[op] { Text(h).font(.caption).foregroundStyle(.secondary) }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if showClear { Button("Clear") { onApply(nil); onClose() }.help("Remove this filter") }
                Spacer()
                Button("Cancel") { onClose() }.keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.small)
        .padding(12)
        .frame(width: 320)
        .onAppear(perform: seed)
        .task(id: search) {
            if !list.isEmpty || !search.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    private var fields: some View {
        HStack(spacing: 6) {
            TextField(arity == 2 ? "from" : op == "like" || op == "not_like" ? "%pattern%" : "value", text: $value)
                .font(.system(size: 12, design: .monospaced)).textFieldStyle(.roundedBorder).onSubmit(apply)
            if arity == 2 {
                Text("and").foregroundStyle(.secondary)
                TextField("to", text: $value2).font(.system(size: 12, design: .monospaced)).textFieldStyle(.roundedBorder).onSubmit(apply)
            }
        }
    }

    private var valueList: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Search values · Return adds your own", text: $search)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addCustom)
            HStack {
                Toggle(isOn: Binding(get: { !items.isEmpty && items.allSatisfy { selected.contains($0.0) } }, set: { on in
                    for (v, _) in items {
                        if on { if !selected.contains(v) { selected.append(v) } } else { selected.removeAll { $0 == v } }
                    }
                })) { Text("Value").font(.caption).foregroundStyle(.secondary) }
                .toggleStyle(.checkbox)
                Spacer()
                Text("Count").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, it in row(it.0, it.1) }
                    if items.isEmpty && !loading { Text("No values").foregroundStyle(.tertiary).padding(6) }
                }
            }
            .frame(height: 220)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
            Text(loading ? "Loading…" : note).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ v: String?, _ n: Int?) -> some View {
        let on = selected.contains(v)
        return HStack(spacing: 6) {
            Image(systemName: on ? "checkmark.square.fill" : "square").foregroundStyle(on ? Color.accentColor : .secondary)
            Text(v == nil ? "NULL" : v!.isEmpty ? "(empty)" : String(v!.prefix(120)))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(v == nil || v == "" ? .secondary : .primary)
                .italic(v == nil || v == "")
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Text(n.map { $0.formatted() } ?? "custom").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 6).frame(height: 22)
        .contentShape(Rectangle())
        .onTapGesture { if on { selected.removeAll { $0 == v } } else { selected.append(v) } }
    }

    private func seed() {
        guard !seeded else { return }
        seeded = true
        let c = initial ?? FilterCond(op: "in", values: [])
        op = c.op ?? "in"
        value = c.value ?? ""
        value2 = c.value2 ?? ""
        selected = c.values ?? []
        extra = (c.values ?? []).compactMap { $0 }   // keep chosen values visible even when outside the top list
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let s = search.trimmingCharacters(in: .whitespaces)
        do {
            let w = try target.baseWhere()
            let r = try await target.state.columnValues(target.connection, table: target.table, column: target.column, where: w,
                                                        search: s, type: target.type)
            list = r.values
            note = r.truncated ? "Top 300 values — search to narrow" : ""
        } catch {
            list = target.localValues(s)  // timeout on a huge table etc.: values of the loaded page
            note = "Values from the loaded rows only"
        }
    }

    private func addCustom() {
        let v = search
        guard !v.isEmpty else { apply(); return }
        if !items.contains(where: { $0.0 == v }) { extra.insert(v, at: 0) }
        if !selected.contains(v) { selected.append(v) }
        search = ""
    }

    private func apply() {
        var c = FilterCond(op: op)
        switch arity {
        case -1:
            guard !selected.isEmpty else { onApply(nil); onClose(); return }
            c.values = selected
        case 1:
            if value.isEmpty && op != "eq" && op != "ne" { error = "Enter a value"; return }
            c.value = value
        case 2:
            if value.isEmpty && value2.isEmpty { error = "Enter at least one bound"; return }
            c.value = value
            c.value2 = value2
        default: break
        }
        c.col = target.column
        do { try target.validate(c) } catch { self.error = error.localizedDescription; return }
        onApply(c)
        onClose()
    }
}

extension FilterTarget {
    /// Filter target for a column of a table tab: other filters + raw WHERE narrow the value list.
    @MainActor static func table(_ state: AppState, _ tab: WorkTab, column: String) -> FilterTarget {
        FilterTarget(state: state, connection: tab.connection, table: tab.tableName ?? "", column: column,
                     type: tab.columnTypes[column] ?? "",
                     baseWhere: { try tab.effectiveWhere(without: column) },
                     localValues: { s in Self.count(tab.result, column: column, search: s) },
                     validate: { c in _ = try QueryBuilder.filterWhere(tab.connection.dialect, FilterGroup(match: "all", conds: [c]), types: tab.columnTypes) })
    }

    static func count(_ r: QueryResult?, column: String, search: String) -> [(String?, Int)] {
        guard let r, let ci = r.columns.firstIndex(of: column) else { return [] }
        var counts: [String?: Int] = [:], order: [String?] = []
        for row in r.rows {
            let v = ci < row.count ? row[ci] : nil
            if !search.isEmpty && !(v ?? "").localizedCaseInsensitiveContains(search) { continue }
            if counts[v] == nil { order.append(v) }
            counts[v, default: 0] += 1
        }
        return order.map { ($0, counts[$0]!) }.sorted { $0.1 > $1.1 }.prefix(300).map { $0 }
    }
}

/// AppKit presentation of the filter popover (grid header button, cell context menu).
@MainActor
enum FilterPopoverPresenter {
    static func show(_ target: FilterTarget, initial: FilterCond?, showClear: Bool, relativeTo rect: NSRect, of view: NSView,
                     onApply: @escaping (FilterCond?) -> Void) {
        let pop = NSPopover()
        pop.behavior = .transient
        let close: () -> Void = { [weak pop] in pop?.performClose(nil) }
        pop.contentViewController = NSHostingController(rootView: FilterPopover(target: target, initial: initial, showClear: showClear,
                                                                                onApply: onApply, onClose: close))
        pop.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        current = pop
    }
    /// Last shown popover (snapshot hook renders it).
    static weak var current: NSPopover?
}

/// Active column filters as removable chips above the grid, with the all/any switch.
struct FilterChips: View {
    let state: AppState
    let tab: WorkTab
    @State private var editing: Int?

    var body: some View {
        let conds = tab.filters.conds ?? []
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Text("Filters").font(.caption).foregroundStyle(.secondary)
                if conds.count > 1 {
                    Picker("", selection: Binding(get: { tab.filters.match ?? "all" }, set: { m in
                        var g = tab.filters; g.match = m; state.setFilters(tab, g)
                    })) {
                        Text("all").tag("all").help("Rows must match every filter")
                        Text("any").tag("any").help("Rows may match any filter")
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                ForEach(Array(conds.enumerated()), id: \.offset) { i, c in chip(i, c) }
                Button("Clear all") { state.setFilters(tab, FilterGroup(match: tab.filters.match, conds: [])) }
                    .buttonStyle(.link).font(.caption)
            }
            .padding(.horizontal, 10)
        }
        .controlSize(.small)
        .frame(height: 28)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func chip(_ i: Int, _ c: FilterCond) -> some View {
        HStack(spacing: 4) {
            Text(FilterOps.text(c)).font(.system(size: 11)).lineLimit(1)
            Button { state.setFilter(tab, column: c.col ?? "", nil) } label: {
                Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 12, height: 12).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Remove")
        }
        .padding(.leading, 8).padding(.trailing, 4).frame(height: 20)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(Color.accentColor.opacity(0.35), lineWidth: 0.5))
        .contentShape(Capsule())
        .onTapGesture { editing = i }
        .help("Edit filter")
        .popover(isPresented: Binding(get: { editing == i }, set: { if !$0 { editing = nil } }), arrowEdge: .bottom) {
            FilterPopover(target: .table(state, tab, column: c.col ?? ""), initial: c,
                          onApply: { state.setFilter(tab, column: c.col ?? "", $0) }, onClose: { editing = nil })
        }
    }
}
