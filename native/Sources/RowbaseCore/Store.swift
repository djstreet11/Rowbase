import Foundation
import Security

/// ~/.config/rowbase/connections.json — same file the Python CLI uses (override dir: ROWBASE_HOME).
/// Secrets: env ROWBASE_PASSWORD_<NAME> → Keychain (service "rowbase", account = id) → secrets.json (0600).
public struct ConnectionStore: Sendable {
    public static let envs = ["local", "dev", "stage", "prod"]
    public let home: URL
    public let fileSecretsOnly: Bool

    public init(home: URL? = nil, fileSecretsOnly: Bool? = nil) {
        let env = ProcessInfo.processInfo.environment
        self.home = home ?? URL(fileURLWithPath: NSString(string: env["ROWBASE_HOME"] ?? "~/.config/rowbase").expandingTildeInPath)
        self.fileSecretsOnly = fileSecretsOnly ?? (env["ROWBASE_SECRETS"] == "file")
    }

    var connectionsURL: URL { home.appendingPathComponent("connections.json") }
    var secretsURL: URL { home.appendingPathComponent("secrets.json") }
    public var historyURL: URL { home.appendingPathComponent("history.jsonl") }

    private struct File: Codable { var version = 1; var connections: [Connection] }

    public func load() throws -> [Connection] {
        guard FileManager.default.fileExists(atPath: connectionsURL.path) else { return [] }
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: connectionsURL)).connections
    }

    private func write(_ conns: [Connection]) throws {
        try ensureHome()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(File(connections: conns)).write(to: connectionsURL, options: .atomic)
    }

    private func ensureHome() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    public func get(_ ref: String) throws -> Connection {
        let all = try load()
        if let c = all.first(where: { $0.id == ref }) ?? all.first(where: { $0.name.lowercased() == ref.lowercased() }) { return c }
        throw RowbaseError("Unknown connection '\(ref)'.")
    }

    /// Validates and saves. password nil = keep stored one, "" = remove.
    @discardableResult
    public func upsert(_ input: Connection, password: String? = nil) throws -> Connection {
        var c = input
        c.name = c.name.trimmingCharacters(in: .whitespaces)
        guard !c.name.isEmpty else { throw RowbaseError("Connection name is required.") }
        c.driver = c.dialect.rawValue
        if let e = c.env, !Self.envs.contains(e) { throw RowbaseError("env must be one of \(Self.envs.joined(separator: ", "))") }
        if c.dialect == .sqlite, (c.path ?? c.database ?? "").isEmpty { throw RowbaseError("SQLite connection needs a file path.") }
        func blank(_ s: String?) -> String? { s.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } }
        (c.host, c.socket, c.database, c.path, c.user) = (blank(c.host), blank(c.socket), blank(c.database), blank(c.path), blank(c.user))
        (c.env, c.color, c.group) = (blank(c.env), blank(c.color), blank(c.group))
        if c.options?.isEmpty == true { c.options = nil }
        var all = try load()
        if all.contains(where: { $0.name.lowercased() == c.name.lowercased() && $0.id != c.id }) {
            throw RowbaseError("A connection named '\(c.name)' already exists.")
        }
        if let i = all.firstIndex(where: { $0.id == c.id }) { all[i] = c } else { all.append(c) }
        try write(all)
        if let password { try setPassword(password, for: c.id) }
        return c
    }

    public func delete(_ id: String) throws {
        try write(try load().filter { $0.id != id })
        try setPassword("", for: id)
    }

    // MARK: secrets

    public func password(for c: Connection) -> String? {
        let key = "ROWBASE_PASSWORD_" + String(c.name.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
        if let v = ProcessInfo.processInfo.environment[key] { return v }
        if !fileSecretsOnly, let v = Keychain.get(account: c.id) { return v }
        return fileSecrets()[c.id]
    }

    public func setPassword(_ pw: String, for id: String) throws {
        if !fileSecretsOnly {
            if pw.isEmpty { Keychain.delete(account: id) } else { try Keychain.set(pw, account: id) }
            return
        }
        var s = fileSecrets()
        s[id] = pw.isEmpty ? nil : pw
        guard !s.isEmpty || FileManager.default.fileExists(atPath: secretsURL.path) else { return }
        try ensureHome()
        try JSONEncoder().encode(s).write(to: secretsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretsURL.path)
    }

    private func fileSecrets() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: secretsURL))) ?? [:]
    }
}

/// Generic passwords, service "rowbase" — the same items Python `keyring` writes on macOS.
enum Keychain {
    static let service = "rowbase"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func get(account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        var status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account)
            q[kSecValueData as String] = data
            q[kSecAttrLabel as String] = "Rowbase connection"
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw RowbaseError("Keychain error \(status)") }
    }

    static func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

// MARK: URL parsing (mirrors rowbase/store.py parse_url)

public enum ConnectionURL {
    /// mysql://u:p@host:3306/db, postgres://…?sslmode=require&socket=/tmp, sqlite:///abs/path.db → (fields, password)
    public static func parse(_ s: String) -> (Connection, String?)? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = t.range(of: "://") else { return nil }
        let scheme = t[..<r.lowerBound].lowercased(), rest = String(t[r.upperBound...])
        guard ["mysql", "mariadb", "postgres", "postgresql", "pg", "sqlite", "sqlite3"].contains(scheme) else { return nil }
        var c = Connection(driver: Dialect(driver: scheme).rawValue)
        let dec = { (x: Substring) in String(x).removingPercentEncoding ?? String(x) }
        if c.dialect == .sqlite {
            var p = dec(rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
            while p.hasPrefix("//") { p.removeFirst() }
            c.path = p
            return (c, nil)
        }
        let qsplit = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var main = qsplit[0], password: String?
        if let at = main.lastIndex(of: "@") {
            let cred = main[..<at]
            main = main[main.index(after: at)...]
            let up = cred.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            c.user = up[0].isEmpty ? nil : dec(up[0])
            if up.count > 1 { password = dec(up[1]) }
        }
        let hp = main.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        if hp.count > 1, !hp[1].isEmpty { c.database = dec(hp[1]) }
        let hostPort = hp[0].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if !hostPort[0].isEmpty { c.host = dec(hostPort[0]) }
        if hostPort.count > 1 { c.port = Int(hostPort[1]) }
        if qsplit.count > 1 {
            var opts: [String: String] = [:]
            for kv in qsplit[1].split(separator: "&") {
                let p = kv.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                opts[dec(p[0])] = p.count > 1 ? dec(p[1]) : ""
            }
            c.socket = opts.removeValue(forKey: "socket")
            c.options = opts.isEmpty ? nil : opts
        }
        return (c, password)
    }
}
