import Foundation
import Logging
import NIOCore
import PostgresNIO

/// PostgreSQL via PostgresNIO. Statements go through the extended protocol (one statement per call);
/// read-only = BEGIN READ ONLY + SET LOCAL statement_timeout, always rolled back.
final class PostgresSession: DBSession, @unchecked Sendable {
    private let conn: PostgresConnection
    private var pid: String?
    var cancelSQL: String? { pid.map { "SELECT pg_cancel_backend(\($0))" } }
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
        if let r = try? await conn.query("SELECT pg_backend_pid()", []).get(), let row = r.rows.first {
            pid = PGFormat.cell(row.makeRandomAccess()[0])
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

    /// psql-like rendering: "2026-10-03 22:44:24.577+03" (timestamptz in local zone), exact microseconds.
    static func timestamp(_ usSince2000: Int64, local: Bool) -> String {
        if usSince2000 == .max { return "infinity" }
        if usSince2000 == .min { return "-infinity" }
        var secs = usSince2000.quotientAndRemainder(dividingBy: 1_000_000)
        if secs.remainder < 0 { secs = (secs.quotient - 1, secs.remainder + 1_000_000) }
        let date = Date(timeIntervalSince1970: Double(secs.quotient) + 946_684_800)
        var cal = Calendar(identifier: .gregorian)
        let tz = local ? TimeZone.current : TimeZone(identifier: "UTC")!
        cal.timeZone = tz
        let d = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        var out = String(format: "%04d-%02d-%02d %02d:%02d:%02d", d.year!, d.month!, d.day!, d.hour!, d.minute!, d.second!)
        out += fraction(secs.remainder)
        if local {
            let off = tz.secondsFromGMT(for: date), a = abs(off)
            out += (off < 0 ? "-" : "+") + String(format: "%02d", a / 3600) + (a % 3600 == 0 ? "" : String(format: ":%02d", a % 3600 / 60))
        }
        return out
    }

    static func fraction(_ us: Int64) -> String {
        guard us != 0 else { return "" }
        var f = String(format: "%06lld", us)
        while f.hasSuffix("0") { f.removeLast() }
        return "." + f
    }

    static func clock(_ us: Int64) -> String {
        let (s, frac) = us.quotientAndRemainder(dividingBy: 1_000_000)
        return String(format: "%02lld:%02lld:%02lld", s / 3600, s % 3600 / 60, s % 60) + fraction(frac)
    }

    static func interval(_ us: Int64, days: Int32, months: Int32) -> String {
        var parts: [String] = []
        let (y, m) = (months / 12, months % 12)
        if y != 0 { parts.append("\(y) year\(abs(y) == 1 ? "" : "s")") }
        if m != 0 { parts.append("\(m) mon\(abs(m) == 1 ? "" : "s")") }
        if days != 0 { parts.append("\(days) day\(abs(days) == 1 ? "" : "s")") }
        if us != 0 || parts.isEmpty { parts.append((us < 0 ? "-" : "") + clock(abs(us))) }
        return parts.joined(separator: " ")
    }

    /// Binary NUMERIC: ndigits, weight, sign, dscale (int16 each) + base-10000 digits. Honors dscale (7.00, not 7).
    static func numeric(_ buf: inout ByteBuffer) -> String? {
        guard let nd = buf.readInteger(as: Int16.self), let weight = buf.readInteger(as: Int16.self),
              let sign = buf.readInteger(as: UInt16.self), let dscale = buf.readInteger(as: Int16.self) else { return nil }
        if sign == 0xC000 { return "NaN" }
        if sign == 0xD000 { return "Infinity" }
        if sign == 0xF000 { return "-Infinity" }
        var digits: [Int16] = []
        for _ in 0..<nd { guard let d = buf.readInteger(as: Int16.self) else { return nil }; digits.append(d) }
        var intPart = ""
        if weight < 0 { intPart = "0" } else {
            for i in 0...Int(weight) {
                let d = i < digits.count ? digits[i] : 0
                intPart += i == 0 ? String(d) : String(format: "%04d", d)
            }
        }
        var frac = ""
        if dscale > 0 {
            var i = Int(weight) + 1
            while frac.count < Int(dscale) {
                let d = i >= 0 && i < digits.count ? digits[i] : 0
                frac += String(format: "%04d", d)
                i += 1
            }
            frac = "." + frac.prefix(Int(dscale))
        }
        return (sign == 0x4000 ? "-" : "") + intPart + frac
    }

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
        case .numeric: return numeric(&buf)
        case .uuid: return (try? c.decode(UUID.self)).map { $0.uuidString.lowercased() }
        case .timestamptz: return buf.readInteger(as: Int64.self).map { timestamp($0, local: true) }
        case .timestamp: return buf.readInteger(as: Int64.self).map { timestamp($0, local: false) }
        case .time: return buf.readInteger(as: Int64.self).map { clock($0) }
        case .interval:
            guard let us = buf.readInteger(as: Int64.self), let days = buf.readInteger(as: Int32.self),
                  let months = buf.readInteger(as: Int32.self) else { return nil }
            return interval(us, days: days, months: months)
        case .date:
            guard let days = buf.readInteger(as: Int32.self) else { return nil }
            return String(timestamp(Int64(days) * 86_400_000_000, local: false).prefix(10))
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
