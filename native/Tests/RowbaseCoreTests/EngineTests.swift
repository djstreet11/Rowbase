import Foundation
import SQLite3
import Testing
@testable import RowbaseCore

/// Engine tests against real databases. SQLite always runs; Postgres/MySQL use local sockets (current user) and
/// skip when unreachable. Postgres uses schema `rowbase_swift` inside database `rowbase_test`
/// (created by the Python suite or `createdb rowbase_test`); MySQL uses database `rowbase_swift`.
enum Fixture {
    static let home = FileManager.default.temporaryDirectory.appendingPathComponent("rowbase-swift-engine-\(UUID().uuidString)")
    static let store = ConnectionStore(home: home, fileSecretsOnly: true)

    static func sqlitePath() -> String {
        let path = home.appendingPathComponent("t.db").path
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            var db: OpaquePointer?
            sqlite3_open(path, &db)
            sqlite3_exec(db, """
                CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL);
                CREATE TABLE orders(id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users, total REAL, note TEXT, data BLOB);
                CREATE INDEX o_u ON orders(user_id);
                INSERT INTO users(name) VALUES ('ann'), ('bob');
                INSERT INTO orders(user_id, total, note, data) VALUES (1, 9.5, '50% off', NULL), (1, 3, NULL, x'00ff'), (2, 7, 'it''s', NULL);
                """, nil, nil, nil)
            sqlite3_close(db)
        }
        return path
    }

    /// (read-only, read-write) connections or nil when the server is unreachable.
    static func make(_ d: Dialect) async -> (Connection, Connection, String)? {
        let engine = Engine(store: store)
        defer { Task { await engine.reset() } }
        switch d {
        case .sqlite:
            let p = sqlitePath()
            return (Connection(name: "lite-ro", driver: "sqlite", path: p), Connection(name: "lite-rw", driver: "sqlite", path: p, readOnly: false), "orders")
        case .postgres:
            let rw = Connection(name: "pg-rw", driver: "postgres", socket: "/tmp", database: "rowbase_test", readOnly: false)
            do {
                for s in ["DROP SCHEMA IF EXISTS rowbase_swift CASCADE", "CREATE SCHEMA rowbase_swift",
                          "CREATE TABLE rowbase_swift.users(id serial PRIMARY KEY, name text NOT NULL)",
                          "CREATE TABLE rowbase_swift.orders(id serial PRIMARY KEY, user_id int REFERENCES rowbase_swift.users(id), total numeric(10,2), note text, data bytea, at timestamptz DEFAULT now(), meta jsonb, d date DEFAULT '2026-10-04', u uuid)",
                          "CREATE INDEX o_u ON rowbase_swift.orders(user_id)",
                          "INSERT INTO rowbase_swift.users(name) VALUES ('ann'), ('bob')",
                          "INSERT INTO rowbase_swift.orders(user_id, total, note, data, meta, u) VALUES (1, 9.5, '50% off', NULL, '{\"a\": 1}', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'), (1, 3, NULL, '\\x00ff', NULL, NULL), (2, 7, 'it''s', NULL, NULL, NULL)"] {
                    _ = try await engine.execute(rw, s)
                }
            } catch { return nil }
            var ro = rw; ro.readOnly = true; ro.name = "pg-ro"
            return (ro, rw, "rowbase_swift.orders")
        case .mysql:
            let boot = Connection(name: "my-boot", driver: "mysql", socket: "/tmp/mysql.sock", readOnly: false)
            let rw = Connection(name: "my-rw", driver: "mysql", socket: "/tmp/mysql.sock", database: "rowbase_swift", readOnly: false)
            do {
                _ = try await engine.execute(boot, "DROP DATABASE IF EXISTS rowbase_swift")
                _ = try await engine.execute(boot, "CREATE DATABASE rowbase_swift")
                for s in ["CREATE TABLE users(id int AUTO_INCREMENT PRIMARY KEY, name varchar(50) NOT NULL)",
                          "CREATE TABLE orders(id int AUTO_INCREMENT PRIMARY KEY, user_id int, total decimal(10,2), note text, data varbinary(16), INDEX o_u (user_id), FOREIGN KEY (user_id) REFERENCES users(id))",
                          "INSERT INTO users(name) VALUES ('ann'), ('bob')",
                          "INSERT INTO orders(user_id, total, note, data) VALUES (1, 9.5, '50% off', NULL), (1, 3, NULL, x'00ff'), (2, 7, 'it''s', NULL)"] {
                    _ = try await engine.execute(rw, s)
                }
            } catch { return nil }
            var ro = rw; ro.readOnly = true; ro.name = "my-ro"
            return (ro, rw, "orders")
        }
    }
}

@Suite(.serialized) struct EngineTests {
    @Test(arguments: Dialect.allCases)
    func engineBehaviour(_ d: Dialect) async throws {
        guard let (ro, rw, orders) = await Fixture.make(d) else {
            print("skip \(d): server not reachable"); return
        }
        let e = Engine(store: Fixture.store)
        let qo = d.ident(orders)

        // select + types
        let r = try await e.execute(ro, "SELECT id, total, note FROM \(qo) ORDER BY id")
        #expect(r.columns == ["id", "total", "note"])
        #expect(r.rows.count == 3 && r.rows[0][2] == "50% off" && r.rows[1][2] == nil && r.affected == nil)
        #expect(Double(r.rows[0][1] ?? "") == 9.5)
        let bin = try await e.execute(ro, "SELECT data FROM \(qo) WHERE id = 2")
        #expect(["0x00FF", "\\x00ff"].contains(bin.rows[0][0] ?? ""), "\(d) binary: \(bin.rows)")

        // auto limit / truncation
        let t = try await e.execute(ro, "SELECT * FROM \(qo)", limit: 2)
        #expect(t.rows.count == 2 && t.truncated)
        let t1 = try await e.execute(ro, "SELECT * FROM \(qo) LIMIT 1", limit: 2)
        #expect(t1.rows.count == 1 && !t1.truncated)

        // read-only refuses writes (guard), and the driver refuses multiple statements even when trusted
        for sql in ["DELETE FROM \(d.ident(orders))", "SELECT 1; DELETE FROM \(qo)", "UPDATE \(qo) SET note = 'x'"] {
            await #expect(throws: RowbaseError.self) { try await e.execute(ro, sql) }
        }
        await #expect(throws: RowbaseError.self) { try await e.execute(ro, "SELECT 1; SELECT 2", trusted: true) }
        // the read-only transaction blocks writes even when the guard is bypassed
        await #expect(throws: RowbaseError.self) { try await e.execute(ro, "UPDATE \(qo) SET note = 'x' WHERE id = 1", trusted: true) }
        #expect(try await e.execute(ro, "SELECT note FROM \(qo) WHERE id = 1").rows[0][0] == "50% off")

        // read-write commits and reports affected rows
        let u = try await e.execute(rw, "UPDATE \(qo) SET note = 'changed' WHERE id = 3")
        #expect(u.affected == 1)
        #expect(try await e.execute(ro, "SELECT note FROM \(qo) WHERE id = 3").rows[0][0] == "changed")

        // catalog
        let names = Set(try await e.tables(ro).map(\.name))
        #expect(names.contains(orders))
        let info = try await e.tableInfo(ro, orders)
        let cols = Dictionary(uniqueKeysWithValues: info.columns.map { ($0.name, $0) })
        #expect(cols["id"]?.key == "PRI" && info.primaryKey == ["id"])
        let users = d == .postgres ? "rowbase_swift.users" : "users"
        #expect(cols["user_id"]?.fk == ForeignKey(table: users, column: "id"))
        #expect(info.indexes.contains { $0.columns == "user_id" })
        #expect(try await e.tableInfo(ro, users).referencedBy == [Reference(table: orders, column: "user_id", refColumn: "id")])
        await #expect(throws: RowbaseError.self) { try await e.tableInfo(ro, "nope") }
        #expect(!(try await e.ping(ro)).isEmpty)

        if d == .postgres {
            let p = try await e.execute(ro, "SELECT meta, u, d, at FROM \(qo) WHERE id = 1")
            #expect(p.rows[0][0] == #"{"a": 1}"# && p.rows[0][1] == "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11" && p.rows[0][2] == "2026-10-04")
            #expect(p.rows[0][3]?.contains("T") == true)
            await #expect(throws: RowbaseError.self) {
                try await e.execute(ro, "SELECT count(*) FROM generate_series(1, 200000000)", timeout: 1, trusted: true)
            }
            await #expect(throws: RowbaseError.self) { try await e.execute(ro, "WITH x AS (DELETE FROM \(qo) RETURNING *) SELECT * FROM x") }
        }
        await e.reset()
    }
}
