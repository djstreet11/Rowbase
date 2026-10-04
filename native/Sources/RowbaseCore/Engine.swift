import Foundation

/// Executes statements on saved connections: guard (read-only), auto LIMIT, pooled sessions, catalog helpers.
/// Mirrors rowbase/engine.py.
public actor Engine {
    public static let fetchCap = 50_000
    public let store: ConnectionStore
    private var idle: [String: [DBSession]] = [:]  // key: connection id + config fingerprint
    private var running: [UUID: (Connection, DBSession)] = [:]
    private var cancelled: Set<UUID> = []

    public init(store: ConnectionStore = ConnectionStore()) { self.store = store }

    private func key(_ c: Connection) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        return c.id + "|" + (String(data: (try? enc.encode(c)) ?? Data(), encoding: .utf8) ?? "")
    }

    static func open(_ c: Connection, password: String?) async throws -> DBSession {
        var c = c
        if let ssh = c.ssh, c.dialect != .sqlite {  // connect through a local forward: driver sees 127.0.0.1:<port>
            let target = c.socket ?? "\(c.host ?? "127.0.0.1"):\(c.port ?? c.dialect.defaultPort ?? 0)"
            let port = try await TunnelManager.shared.port(ssh, target: target)
            (c.host, c.port, c.socket, c.ssh) = ("127.0.0.1", port, nil, nil)
        }
        return switch c.dialect {
        case .sqlite: try SQLiteSession(path: c.path ?? c.database ?? "", readOnly: c.readOnly)
        case .postgres: try await PostgresSession(c, password: password)
        case .mysql: try await MySQLSession(c, password: password)
        }
    }

    private func take(_ c: Connection) async throws -> DBSession {
        let k = key(c)
        while var list = idle[k], let s = list.popLast() {
            idle[k] = list
            if s.isAlive { return s }
        }
        return try await Self.open(c, password: store.password(for: c))
    }

    private func give(_ c: Connection, _ s: DBSession) async {
        let k = key(c)
        if (idle[k]?.count ?? 0) < 4 { idle[k, default: []].append(s) } else { await s.close() }
    }

    public func reset(_ id: String? = nil) async {
        for (k, list) in idle where id == nil || k.hasPrefix(id! + "|") {
            idle[k] = nil
            for s in list { await s.close() }
        }
    }

    /// Run one statement. `trusted` skips the guard (internal catalog SQL) but keeps the read-only transaction.
    /// Cancel a statement started with `execute(…, runID:)`. Uses a separate session (KILL QUERY / pg_cancel_backend)
    /// or sqlite3_interrupt. The cancelled execute throws "Query cancelled."
    public func cancel(_ runID: UUID) async {
        guard let (c, s) = running[runID] else { return }
        cancelled.insert(runID)
        guard let sql = s.cancelSQL else { s.interrupt(); return }
        do {
            let killer = try await Self.open(c, password: store.password(for: c))
            _ = try? await killer.run(sql, readOnly: c.dialect == .postgres, timeout: 5, maxRows: 1)
            await killer.close()
        } catch {}
    }

    public func execute(_ c: Connection, _ sql: String, limit: Int = 100, timeout: Int = 30, trusted: Bool = false,
                        runID: UUID? = nil) async throws -> QueryResult {
        let d = c.dialect
        let a = c.readOnly && !trusted ? try SQLGuard.check(sql, d) : SQLGuard.analyze(sql, d)
        guard !a.clean.isEmpty else { throw RowbaseError("Empty query.") }
        let hasLimit = a.bare.range(of: #"\bLIMIT\s+\d+(\s*,\s*\d+)?(\s+OFFSET\s+\d+)?\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil
        let limited = (a.first == "SELECT" || (a.first == "WITH" && c.readOnly)) && !hasLimit
        let stmt = limited ? "\(a.clean)\nLIMIT \(limit + 1)" : a.clean
        var session = try await take(c)
        if let runID { running[runID] = (c, session) }
        defer { if let runID { running[runID] = nil; cancelled.remove(runID) } }
        var result: QueryResult
        do {
            result = try await session.run(stmt, readOnly: c.readOnly, timeout: timeout, maxRows: limited ? limit : Self.fetchCap)
        } catch let e as RowbaseError where !session.isAlive && !e.message.hasPrefix("SQL error") {
            session = try await Self.open(c, password: store.password(for: c))  // pooled session dropped by server: retry once
            result = try await session.run(stmt, readOnly: c.readOnly, timeout: timeout, maxRows: limited ? limit : Self.fetchCap)
        } catch {
            if session.isAlive { await give(c, session) } else { await session.close() }
            if let runID, cancelled.contains(runID) { throw RowbaseError("Query cancelled.") }
            throw error
        }
        await give(c, session)
        if let runID, cancelled.contains(runID) { throw RowbaseError("Query cancelled.") }  // e.g. MySQL SLEEP returns 1 when killed
        return result
    }

    private func meta(_ c: Connection, _ sql: String) async throws -> [[String?]] {
        try await execute(c, sql, limit: Self.fetchCap, timeout: 60, trusted: true).rows
    }

    public func ping(_ c: Connection) async throws -> String {
        let r = try await execute(c, Catalog.version(c.dialect), limit: 1, timeout: 10, trusted: true)
        return r.rows.first?.first.flatMap { $0 } ?? "?"
    }

    /// Databases on the server (empty for SQLite).
    public func databases(_ c: Connection) async throws -> [String] {
        guard let sql = Catalog.databases(c.dialect) else { return [] }
        return try await meta(c, sql).compactMap { $0.first ?? nil }
    }

    /// Database the session actually uses (nil when a MySQL connection has none selected).
    public func currentDatabase(_ c: Connection) async throws -> String? {
        try await execute(c, Catalog.currentDatabase(c.dialect), limit: 1, timeout: 10, trusted: true).rows.first?.first ?? nil
    }

    public func tables(_ c: Connection) async throws -> [TableEntry] {
        try await meta(c, Catalog.tables(c.dialect)).map { TableEntry(name: $0[0] ?? "", rows: $0[1].flatMap { Int($0) }, isView: $0[2] == "view") }
    }

    public func tableInfo(_ c: Connection, _ table: String) async throws -> TableInfo {
        let d = c.dialect
        let fks = Dictionary(try await meta(c, Catalog.foreignKeys(d, table)).map { ($0[0] ?? "", ForeignKey(table: $0[1] ?? "", column: $0[2] ?? "")) },
                             uniquingKeysWith: { a, _ in a })
        let truthy: (String?) -> Bool = { ["1", "t", "true"].contains(($0 ?? "").lowercased()) }
        let cols = try await meta(c, Catalog.columns(d, table)).map {
            // MariaDB reports a NULL default as the string "NULL" (string defaults are quoted)
            ColumnInfo(name: $0[0] ?? "", type: $0[1] ?? "", nullable: truthy($0[2]), key: $0[3] ?? "",
                       defaultValue: d == .mysql && $0[4] == "NULL" ? nil : $0[4], fk: fks[$0[0] ?? ""])
        }
        guard !cols.isEmpty else { throw RowbaseError("Table '\(table)' not found.") }
        let idx = try await meta(c, Catalog.indexes(d, table)).map { IndexInfo(name: $0[0] ?? "", unique: truthy($0[1]), columns: $0[2] ?? "") }
        let refs = try await meta(c, Catalog.referencedBy(d, table)).map { Reference(table: $0[0] ?? "", column: $0[1] ?? "", refColumn: $0[2] ?? "") }
        return TableInfo(name: table, quoted: d.ident(table), columns: cols, indexes: idx, referencedBy: refs)
    }
}

/// Append-only query history, same JSONL format as the Python UI (SPEC §5).
public struct History: Sendable {
    public struct Entry: Codable, Sendable, Identifiable {
        public var ts: String
        public var conn: String
        public var connName: String?
        public var sql: String
        public var source: String?
        public var rows: Int?
        public var elapsed: Double?
        public var error: String?
        public var affected: Int?
        public var id: String { ts + sql }

        public init(ts: String = History.now(), conn: String, connName: String?, sql: String, source: String?,
                    rows: Int? = nil, elapsed: Double? = nil, error: String? = nil, affected: Int? = nil) {
            (self.ts, self.conn, self.connName, self.sql, self.source) = (ts, conn, connName, sql, source)
            (self.rows, self.elapsed, self.error, self.affected) = (rows, elapsed, error, affected)
        }
    }

    public let url: URL
    public init(store: ConnectionStore) { url = store.historyURL }

    public func add(_ e: Entry) {
        guard var line = try? JSONEncoder().encode(e) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line); try? h.close()
        } else {
            try? line.write(to: url)
        }
    }

    public func read(limit: Int = 500, conn: String? = nil) -> [Entry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [Entry] = []
        for line in text.split(separator: "\n").reversed() {
            guard let e = try? JSONDecoder().decode(Entry.self, from: Data(line.utf8)), conn == nil || e.conn == conn else { continue }
            out.append(e)
            if out.count >= limit { break }
        }
        return out
    }

    public static func now() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: Date())
    }
}
