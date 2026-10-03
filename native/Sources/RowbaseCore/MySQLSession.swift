import Foundation
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL

/// MySQL/MariaDB via MySQLNIO text protocol. The client never sets CLIENT_MULTI_STATEMENTS → one statement per call.
final class MySQLSession: DBSession, @unchecked Sendable {
    private let conn: MySQLConnection
    private var timeoutSet: Int?

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

    func run(_ sql: String, readOnly: Bool, timeout: Int, maxRows: Int) async throws -> QueryResult {
        if timeoutSet != timeout {
            _ = try? await conn.simpleQuery("SET SESSION max_execution_time=\(timeout * 1000)").get()  // MySQL
            _ = try? await conn.simpleQuery("SET SESSION max_statement_time=\(timeout)").get()         // MariaDB
            timeoutSet = timeout
        }
        try await exec(readOnly ? "START TRANSACTION READ ONLY" : "START TRANSACTION")
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
