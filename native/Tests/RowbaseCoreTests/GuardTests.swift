import Foundation
import Testing
@testable import RowbaseCore

/// Conformance with the Python guard: both suites read tests/guard_vectors.json.
struct GuardVectors: Decodable {
    struct Clean: Decodable { let dialect, sql, clean, first: String }
    let ok: [String: [String]]
    let bad: [String: [String]]
    let clean: [Clean]

    static let shared: GuardVectors = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../tests/guard_vectors.json").standardizedFileURL
        return try! JSONDecoder().decode(GuardVectors.self, from: Data(contentsOf: url))
    }()
}

@Suite struct GuardTests {
    let v = GuardVectors.shared

    @Test func allowed() throws {
        for (d, qs) in v.ok { for q in qs { #expect(throws: Never.self, "\(d): \(q)") { try SQLGuard.check(q, Dialect(driver: d)) } } }
    }

    @Test func refused() {
        for (d, qs) in v.bad { for q in qs { #expect(throws: RowbaseError.self, "\(d): \(q)") { try SQLGuard.check(q, Dialect(driver: d)) } } }
    }

    @Test func scanPreservesLength() {
        for group in [v.ok, v.bad] { for (d, qs) in group { for q in qs { #expect(SQLGuard.scan(q, Dialect(driver: d)).count == q.utf8.count) } } }
    }

    @Test func clean() {
        for c in v.clean {
            let a = SQLGuard.analyze(c.sql, Dialect(driver: c.dialect))
            #expect(a.clean == c.clean && a.first == c.first, "\(c.sql)")
        }
    }

    @Test func multibyteInLiterals() throws {
        let a = try SQLGuard.check("SELECT 'привет;' -- коммент;", .postgres)
        #expect(a.clean == "SELECT 'привет;'")
    }
}

@Suite struct ModelTests {
    @Test func urlParsing() throws {
        let (c, pw) = try #require(ConnectionURL.parse("postgresql://u%40x:p%3Ass@db.local:6432/app?sslmode=require"))
        #expect(c.driver == "postgres" && c.host == "db.local" && c.port == 6432 && c.user == "u@x" && c.database == "app")
        #expect(c.options == ["sslmode": "require"] && pw == "p:ss")
        let (s, _) = try #require(ConnectionURL.parse("mysql://admin@/db?socket=/tmp/mysql.sock"))
        #expect(s.socket == "/tmp/mysql.sock" && s.host == nil && s.user == "admin" && s.database == "db" && s.options == nil)
        #expect(ConnectionURL.parse("sqlite:////abs/x.db")?.0.path == "/abs/x.db")
        #expect(ConnectionURL.parse("http://x") == nil)
    }

    @Test func idents() {
        #expect(Dialect.postgres.ident("crm.orders") == "\"crm\".\"orders\"")
        #expect(Dialect.postgres.ident("users") == "\"public\".\"users\"")
        #expect(Dialect.mysql.ident("we`ird") == "`we``ird`")
        #expect(Dialect.mysql.literal("a'\\") == "'a''\\\\'")
    }

    @Test func storeRoundTripAndSecrets() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("rowbase-swift-\(UUID().uuidString)")
        let store = ConnectionStore(home: home, fileSecretsOnly: true)
        let c = try store.upsert(Connection(name: "Tmp", driver: "pg", host: "h", readOnly: true), password: "s3cret")
        #expect(c.driver == "postgres")
        let text = try String(contentsOf: home.appendingPathComponent("connections.json"), encoding: .utf8)
        #expect(!text.contains("s3cret") && text.contains("\"version\" : 1"))
        #expect(store.password(for: try store.get("tmp")) == "s3cret")
        let attrs = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent("secrets.json").path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        var edited = c; edited.host = "h2"
        try store.upsert(edited)  // nil password keeps it
        #expect(store.password(for: try store.get(c.id)) == "s3cret")
        #expect(throws: RowbaseError.self) { try store.upsert(Connection(name: "TMP", driver: "mysql")) }
        try store.delete(c.id)
        #expect(throws: RowbaseError.self) { try store.get("Tmp") }
    }

    @Test func readsPythonWrittenFile() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("rowbase-swift-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let py = #"{"version": 1, "connections": [{"id": "x1", "name": "py", "driver": "mysql", "socket": "/tmp/mysql.sock", "options": {"a": "b"}}]}"#
        try py.write(to: home.appendingPathComponent("connections.json"), atomically: true, encoding: .utf8)
        let c = try ConnectionStore(home: home, fileSecretsOnly: true).get("py")
        #expect(c.readOnly && c.socket == "/tmp/mysql.sock" && c.options == ["a": "b"])  // missing readOnly → safe default
    }
}
