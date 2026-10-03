import Foundation
import Logging
import NIOCore
import PostgresNIO

/// PostgreSQL via PostgresNIO. Statements go through the extended protocol (one statement per call);
/// read-only = BEGIN READ ONLY + SET LOCAL statement_timeout, always rolled back.
final class PostgresSession: DBSession, @unchecked Sendable {
    private let conn: PostgresConnection
    private static let logger = Logger(label: "rowbase.postgres")
    private static let ids = ManagedAtomicCounter()

    init(_ c: Connection, password: String?) async throws {
        let user = c.user ?? NSUserName()
        var cfg: PostgresConnection.Configuration
        if let sock = c.socket {
            let path = sock.hasSuffix(".s.PGSQL.\(c.port ?? 5432)") || !FileManager.default.isDirectory(sock)
                ? sock : (sock as NSString).appendingPathComponent(".s.PGSQL.\(c.port ?? 5432)")
            cfg = .init(unixSocketPath: path, username: user, password: password, database: c.database)
        } else {
            let tls: PostgresConnection.Configuration.TLS
            switch c.options?["sslmode"] ?? "disable" {
            case "require", "verify-ca", "verify-full":
                var tc = TLSConfiguration.makeClientConfiguration()
                if c.options?["sslmode"] == "require" { tc.certificateVerification = .none }
                tls = .require(try NIOSSLContext(configuration: tc))
            case "prefer", "allow":
                var tc = TLSConfiguration.makeClientConfiguration()
                tc.certificateVerification = .none
                tls = .prefer(try NIOSSLContext(configuration: tc))
            default: tls = .disable
            }
            cfg = .init(host: c.host ?? "127.0.0.1", port: c.port ?? 5432, username: user, password: password, database: c.database, tls: tls)
        }
        cfg.options.connectTimeout = .seconds(10)
        do {
            conn = try await PostgresConnection.connect(configuration: cfg, id: Self.ids.next(), logger: Self.logger)
        } catch {
            throw RowbaseError("Connection error: \(Self.message(error))")
        }
    }

    static func message(_ e: Error) -> String {
        if let p = e as? PSQLError {
            if let m = p.serverInfo?[.message] { return m + (p.serverInfo?[.detail].map { " — \($0)" } ?? "") }
            return "\(p.code)"
        }
        return String(describing: e)
    }

    deinit { if !conn.isClosed { conn.close().whenComplete { _ in } } }

    var isAlive: Bool { !conn.isClosed }

    func close() async { try? await conn.close() }

    private func exec(_ sql: String) async throws -> PostgresQueryResult {
        do { return try await conn.query(sql, []).get() } catch { throw RowbaseError("SQL error: \(Self.message(error))") }
    }

    func run(_ sql: String, readOnly: Bool, timeout: Int, maxRows: Int) async throws -> QueryResult {
        _ = try await exec(readOnly ? "BEGIN READ ONLY" : "BEGIN")
        var done = false
        do {
            _ = try await exec("SET LOCAL statement_timeout = \(timeout * 1000)")
            let started = Date()
            let r = try await exec(sql)
            let elapsed = Date().timeIntervalSince(started)
            var cols: [String] = [], rows: [[String?]] = []
            for row in r.rows.prefix(maxRows) {
                let ra = row.makeRandomAccess()
                if cols.isEmpty { cols = (0..<ra.count).map { ra[$0].columnName } }
                rows.append((0..<ra.count).map { PGFormat.cell(ra[$0]) })
            }
            let isQuery = !r.rows.isEmpty || ["SELECT", "SHOW", "EXPLAIN", "VALUES", "TABLE", "FETCH"].contains(r.metadata.command.uppercased())
            if cols.isEmpty, isQuery { cols = [] }  // empty result set: column names unknown without rows
            let affected = isQuery ? nil : r.metadata.rows
            _ = try await exec(readOnly ? "ROLLBACK" : "COMMIT")
            done = true
            return QueryResult(columns: cols, rows: rows, truncated: r.rows.count > maxRows, elapsed: elapsed, affected: affected)
        } catch {
            if !done { _ = try? await conn.query("ROLLBACK", []).get() }
            throw error
        }
    }
}

final class ManagedAtomicCounter: @unchecked Sendable {
    private var v = 0
    private let lock = NSLock()
    func next() -> Int { lock.withLock { v += 1; return v } }
}

extension FileManager {
    func isDirectory(_ path: String) -> Bool {
        var d: ObjCBool = false
        return fileExists(atPath: path, isDirectory: &d) && d.boolValue
    }
}

/// Binary-format Postgres values → display strings for the common types; unknown types fall back to text/hex.
enum PGFormat {
    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {  // formatting only; thread-safe per Apple docs
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func cell(_ c: PostgresCell) -> String? {
        guard var buf = c.bytes else { return nil }
        switch c.dataType {
        case .bool: return (try? c.decode(Bool.self)).map { $0 ? "true" : "false" }
        case .int2: return (try? c.decode(Int16.self)).map(String.init)
        case .int4: return (try? c.decode(Int32.self)).map(String.init)
        case .int8: return (try? c.decode(Int64.self)).map(String.init)
        case .oid: return buf.readInteger(as: UInt32.self).map(String.init)
        case .float4: return (try? c.decode(Float.self)).map { "\($0)" }
        case .float8: return (try? c.decode(Double.self)).map { "\($0)" }
        case .numeric: return (try? c.decode(Decimal.self)).map { "\($0)" }
        case .uuid: return (try? c.decode(UUID.self)).map { $0.uuidString.lowercased() }
        case .timestamptz: return (try? c.decode(Date.self)).map { iso.string(from: $0) }
        case .timestamp: return (try? c.decode(Date.self)).map { iso.string(from: $0).replacingOccurrences(of: "Z", with: "") }
        case .date:
            guard let days = buf.readInteger(as: Int32.self) else { return nil }
            let d = Date(timeIntervalSince1970: (Double(days) + 10957) * 86400)
            return String(iso.string(from: d).prefix(10))
        case .jsonb:
            _ = buf.readInteger(as: UInt8.self)  // version byte
            return buf.readString(length: buf.readableBytes)
        case .bytea:
            return "\\x" + buf.readableBytesView.map { String(format: "%02x", $0) }.joined()
        default:
            if let s = try? c.decode(String.self) { return s }
            let bytes = Array(buf.readableBytesView)
            if let s = String(bytes: bytes, encoding: .utf8), !s.contains("\0") { return s }
            return "<\(c.dataType) \(bytes.count) bytes>"
        }
    }
}
