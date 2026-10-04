import Foundation
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL

/// MySQL/MariaDB via MySQLNIO text protocol. The client never sets CLIENT_MULTI_STATEMENTS → one statement per call.
final class MySQLSession: DBSession, @unchecked Sendable {
    private let conn: MySQLConnection
    private var timeoutSet: Int?
    private var connectionID: String?
    private var isMariaDB = false
    var cancelSQL: String? { connectionID.map { "KILL QUERY \($0)" } }

    init(_ c: Connection, password: String?) async throws {
        let el = MultiThreadedEventLoopGroup.singleton.next()
        do {
            let addr = try c.socket.map { try SocketAddress(unixDomainSocketPath: $0) }
                ?? SocketAddress.makeAddressResolvingHost(c.host ?? "127.0.0.1", port: c.port ?? 3306)
            var tls: TLSConfiguration?
            if let mode = c.options?["ssl-mode"] ?? c.options?["sslmode"], !["disable", "disabled"].contains(mode.lowercased()) {
                var t = TLSConfiguration.makeClientConfiguration()
                if !mode.lowercased().hasPrefix("verify") { t.certificateVerification = .none }
                tls = t
            }
            conn = try await MySQLConnection.connect(to: addr, username: c.user ?? NSUserName(), database: c.database ?? "",
                                                     password: password, tlsConfiguration: tls, on: el).get()
        } catch {
            throw RowbaseError("Connection error: \(Self.message(error))")
        }
        connectionID = try? await conn.simpleQuery("SELECT CONNECTION_ID()").get().first?.column("CONNECTION_ID()")?.string
        let version = try? await conn.simpleQuery("SELECT VERSION()").get().first?.column("VERSION()")?.string
        isMariaDB = version?.lowercased().contains("mariadb") ?? false
    }

    static func message(_ e: Error) -> String {
        if let m = e as? MySQLError { return m.description.replacingOccurrences(of: "MySQL error: ", with: "") }
        return String(describing: e)
    }

    deinit { if !conn.isClosed { _ = conn.close() } }  // MySQLNIO asserts on deinit of an open connection

    var isAlive: Bool { !conn.isClosed }

    func close() async { try? await conn.close().get() }

    @discardableResult
    private func exec(_ sql: String) async throws -> [MySQLRow] {
        do { return try await conn.simpleQuery(sql).get() } catch { throw RowbaseError("SQL error: \(Self.message(error))") }
    }

    func txBegin(timeout: Int) async throws {
        if timeoutSet != timeout {
            _ = try? await conn.simpleQuery("SET SESSION max_execution_time=\(timeout * 1000)").get()
            _ = try? await conn.simpleQuery("SET SESSION max_statement_time=\(timeout)").get()
            timeoutSet = timeout
        }
        try await exec("START TRANSACTION")
    }

    func txExec(_ sql: String) async throws -> (affected: Int, first: String?) {
        let rows = try await exec(sql)
        if let r = rows.first, let v = r.values.first {
            return (0, v.map { String(decoding: $0.readableBytesView, as: UTF8.self) })
        }
        let n = try await exec("SELECT ROW_COUNT()").first?.column("ROW_COUNT()")?.int ?? 0
        return (n, nil)
    }

    func txCommit() async throws { try await exec("COMMIT") }

    func txRollback() async { _ = try? await conn.simpleQuery("ROLLBACK").get() }

    func run(_ sql: String, readOnly: Bool, timeout: Int, maxRows: Int) async throws -> QueryResult {
        if timeoutSet != timeout {
            _ = try? await conn.simpleQuery("SET SESSION max_execution_time=\(timeout * 1000)").get()  // MySQL
            _ = try? await conn.simpleQuery("SET SESSION max_statement_time=\(timeout)").get()         // MariaDB
            timeoutSet = timeout
        }
        try await exec(readOnly ? "START TRANSACTION READ ONLY" : "START TRANSACTION")
        var sql = sql
        if isMariaDB, let r = sql.range(of: #"^\s*EXPLAIN\s+ANALYZE\s+"#, options: [.regularExpression, .caseInsensitive]) {
            sql.replaceSubrange(r, with: "ANALYZE ")  // MariaDB spells EXPLAIN ANALYZE as ANALYZE <stmt>
        }
        do {
            let started = Date()
            let rows = try await exec(sql)
            let elapsed = Date().timeIntervalSince(started)
            let cols = rows.first?.columnDefinitions.map(\.name) ?? []
            let out = rows.prefix(maxRows).map { r in
                zip(r.values, r.columnDefinitions).map { v, def -> String? in
                    guard let v else { return nil }
                    let b = Array(v.readableBytesView)
                    return def.characterSet == .binary ? Format.bytes(b) : String(decoding: b, as: UTF8.self)
                }
            }
            var affected: Int?
            if rows.isEmpty, !Self.isQuery(sql) {
                affected = try await exec("SELECT ROW_COUNT()").first?.column("ROW_COUNT()")?.int
            }
            try await exec(readOnly ? "ROLLBACK" : "COMMIT")
            return QueryResult(columns: cols, rows: Array(out), truncated: rows.count > maxRows, elapsed: elapsed, affected: affected)
        } catch {
            _ = try? await conn.simpleQuery("ROLLBACK").get()
            throw error
        }
    }

    static func isQuery(_ sql: String) -> Bool {
        let first = SQLGuard.analyze(sql, .mysql).first
        return ["SELECT", "SHOW", "DESC", "DESCRIBE", "EXPLAIN", "WITH", "VALUES", "TABLE"].contains(first)
    }
}
