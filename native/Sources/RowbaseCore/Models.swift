import Foundation

/// A saved connection. JSON shape is the cross-track contract (SPEC §5) shared with the Python `rowbase` CLI.
public struct Connection: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var driver: String
    public var host: String?
    public var port: Int?
    public var socket: String?
    public var database: String?
    public var path: String?
    public var user: String?
    public var readOnly: Bool
    public var env: String?
    public var color: String?
    public var group: String?
    public var options: [String: String]?

    public init(id: String = UUID().uuidString.lowercased(), name: String = "", driver: String = "mysql", host: String? = nil,
                port: Int? = nil, socket: String? = nil, database: String? = nil, path: String? = nil, user: String? = nil,
                readOnly: Bool = true, env: String? = nil, color: String? = nil, group: String? = nil, options: [String: String]? = nil) {
        (self.id, self.name, self.driver, self.host, self.port, self.socket, self.database, self.path, self.user) =
            (id, name, driver, host, port, socket, database, path, user)
        (self.readOnly, self.env, self.color, self.group, self.options) = (readOnly, env, color, group, options)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        driver = try c.decodeIfPresent(String.self, forKey: .driver) ?? "mysql"
        host = try c.decodeIfPresent(String.self, forKey: .host)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        socket = try c.decodeIfPresent(String.self, forKey: .socket)
        database = try c.decodeIfPresent(String.self, forKey: .database)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        user = try c.decodeIfPresent(String.self, forKey: .user)
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? true  // missing flag = safe default
        env = try c.decodeIfPresent(String.self, forKey: .env)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        options = try c.decodeIfPresent([String: String].self, forKey: .options)
    }

    public var dialect: Dialect { Dialect(driver: driver) }

    /// Short human description: `user@host:port/db` or the SQLite path.
    public var target: String {
        if dialect == .sqlite { return path ?? database ?? "" }
        let at = socket ?? host ?? "localhost"
        return "\(user.map { "\($0)@" } ?? "")\(at)\(port.map { ":\($0)" } ?? "")/\(database ?? "")"
    }
}

public enum Dialect: String, Sendable, CaseIterable {
    case mysql, postgres, sqlite

    public init(driver: String) {
        switch driver.lowercased() {
        case "postgres", "postgresql", "pg": self = .postgres
        case "sqlite", "sqlite3": self = .sqlite
        default: self = .mysql
        }
    }

    public var title: String { ["mysql": "MySQL / MariaDB", "postgres": "PostgreSQL", "sqlite": "SQLite"][rawValue]! }
    public var defaultPort: Int? { self == .mysql ? 3306 : self == .postgres ? 5432 : nil }
    public var quote: Character { self == .mysql ? "`" : "\"" }

    public func ident(_ name: String) -> String {
        let q = String(quote)
        if self == .postgres {
            var parts = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if parts.count == 1 { parts.insert("public", at: 0) }
            return parts.map { q + $0.replacingOccurrences(of: q, with: q + q) + q }.joined(separator: ".")
        }
        return q + name.replacingOccurrences(of: q, with: q + q) + q
    }

    public func literal(_ s: String) -> String {
        var v = s.replacingOccurrences(of: "'", with: "''")
        if self == .mysql { v = v.replacingOccurrences(of: "\\", with: "\\\\") }
        return "'\(v)'"
    }
}

public struct QueryResult: Sendable {
    public var columns: [String]
    public var rows: [[String?]]
    public var truncated: Bool
    public var elapsed: Double
    public var affected: Int?

    public init(columns: [String] = [], rows: [[String?]] = [], truncated: Bool = false, elapsed: Double = 0, affected: Int? = nil) {
        (self.columns, self.rows, self.truncated, self.elapsed, self.affected) = (columns, rows, truncated, elapsed, affected)
    }
}

public struct TableEntry: Sendable, Hashable, Identifiable {
    public var name: String
    public var rows: Int?
    public var isView: Bool
    public var id: String { name }
}

public struct ColumnInfo: Sendable, Hashable {
    public var name, type: String
    public var nullable: Bool
    public var key: String
    public var defaultValue: String?
    public var fk: ForeignKey?
}

public struct ForeignKey: Sendable, Hashable {
    public var table, column: String
}

public struct IndexInfo: Sendable, Hashable {
    public var name: String
    public var unique: Bool
    public var columns: String
}

public struct Reference: Sendable, Hashable {
    public var table, column, refColumn: String
}

public struct TableInfo: Sendable {
    public var name: String
    public var quoted: String
    public var columns: [ColumnInfo]
    public var indexes: [IndexInfo]
    public var referencedBy: [Reference]
    public var primaryKey: [String] { columns.filter { $0.key == "PRI" }.map(\.name) }
}

public struct RowbaseError: LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
