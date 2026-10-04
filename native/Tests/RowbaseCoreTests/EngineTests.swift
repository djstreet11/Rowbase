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

    static func sqlitePath(_ file: String = "t.db") -> String {
        let path = home.appendingPathComponent(file).path
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
    static func make(_ d: Dialect, sqliteFile: String = "t.db") async -> (Connection, Connection, String)? {
        let engine = Engine(store: store)
        defer { Task { await engine.reset() } }
        switch d {
        case .sqlite:
            let p = sqlitePath(sqliteFile)
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
        #expect(cols["note"]?.defaultValue == nil, "\(d): NULL default must be nil")
        let users = d == .postgres ? "rowbase_swift.users" : "users"
        #expect(cols["user_id"]?.fk == ForeignKey(table: users, column: "id"))
        #expect(info.indexes.contains { $0.columns == "user_id" })
        #expect(try await e.tableInfo(ro, users).referencedBy == [Reference(table: orders, column: "user_id", refColumn: "id")])
        await #expect(throws: RowbaseError.self) { try await e.tableInfo(ro, "nope") }
        #expect(!(try await e.ping(ro)).isEmpty)
        // database listing / switching (the picker for connections without a database)
        if d != .sqlite {
            let dbs = try await e.databases(ro)
            let expected = d == .mysql ? "rowbase_swift" : "rowbase_test"
            #expect(dbs.contains(expected), "\(d): \(dbs)")
            #expect(try await e.currentDatabase(ro) == expected)
            var none = ro; none.database = nil; none.name = "nodb"
            if d == .mysql {
                #expect(try await e.currentDatabase(none) == nil)
                #expect(try await e.tables(none).isEmpty)
            }
            var switched = none; switched.database = expected
            #expect(try await e.tables(switched).contains { $0.name == orders })
        } else {
            #expect(try await e.databases(ro).isEmpty)
        }

        if d != .sqlite {  // MySQL 8 syntax; the MariaDB session rewrites it to ANALYZE <stmt>
            #expect(!(try await e.execute(ro, "EXPLAIN ANALYZE SELECT * FROM \(qo) WHERE id = 2").rows.isEmpty))
        }
        if d == .postgres {
            let n = try await e.execute(ro, "SELECT 7::numeric(10,2), -0.05::numeric(6,3), 12345678.9::numeric, 0::numeric, 'NaN'::numeric, 10000::numeric(8,1)")
            #expect(n.rows[0] == ["7.00", "-0.050", "12345678.9", "0", "NaN", "10000.0"])
            let p = try await e.execute(ro, "SELECT meta, u, d, at FROM \(qo) WHERE id = 1")
            #expect(p.rows[0][0] == #"{"a": 1}"# && p.rows[0][1] == "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11" && p.rows[0][2] == "2026-10-04")
            #expect(p.rows[0][3]?.range(of: #"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d(\.\d+)?[+-]\d\d"#, options: .regularExpression) != nil, "\(p.rows[0][3] ?? "")")
            let t = try await e.execute(ro, "SELECT '2026-10-04 01:02:03.5'::timestamp, '2000-01-01'::timestamp, '1999-12-31 23:59:59.25'::timestamp, '13:05:00.000123'::time, '1 year 2 mons 3 days 04:05:06'::interval, '-00:00:01.5'::interval, '1969-07-20'::date, 'infinity'::timestamp")
            #expect(t.rows[0] == ["2026-10-04 01:02:03.5", "2000-01-01 00:00:00", "1999-12-31 23:59:59.25", "13:05:00.000123",
                                  "1 year 2 mons 3 days 04:05:06", "-00:00:01.5", "1969-07-20", "infinity"])
            await #expect(throws: RowbaseError.self) {
                try await e.execute(ro, "SELECT count(*) FROM generate_series(1, 200000000)", timeout: 1, trusted: true)
            }
            await #expect(throws: RowbaseError.self) { try await e.execute(ro, "WITH x AS (DELETE FROM \(qo) RETURNING *) SELECT * FROM x") }
        }
        // cancel a long statement from another task
        let slow = switch d {
        case .postgres: "SELECT pg_sleep(20)"
        case .mysql: "SELECT SLEEP(20)"
        case .sqlite: "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n) SELECT count(*) FROM n"
        }
        let id = UUID(), started = Date()
        let task = Task { try await e.execute(ro, slow, timeout: 30, trusted: true, runID: id) }
        try await Task.sleep(for: .milliseconds(700))
        await e.cancel(id)
        do { _ = try await task.value; Issue.record("\(d): cancelled query returned normally") }
        catch let err as RowbaseError { #expect(err.message == "Query cancelled.", "\(d): \(err.message)") }
        #expect(Date().timeIntervalSince(started) < 5, "\(d): cancel took too long")
        #expect(try await e.execute(ro, "SELECT 1").rows[0][0] == "1")  // session still usable
        await e.reset()
    }

    @Test(arguments: Dialect.allCases)
    func rowEditing(_ d: Dialect) async throws {
        guard let (ro, rw, t) = await Fixture.make(d, sqliteFile: "edit.db") else { print("skip edit \(d)"); return }
        let e = Engine(store: Fixture.store)
        let q = d.ident(t)
        func note(_ id: Int) async throws -> String? { try await e.execute(ro, "SELECT note FROM \(q) WHERE id = \(id)").rows.first?[0] ?? nil }
        let dry = try await e.apply(rw, table: t, changes: [.update(key: [.init("id", "1")], set: [.init("note", "x"), .init("total", nil)])], dryRun: true)
        #expect(dry.statements.count == 1 && dry.statements[0].hasPrefix("UPDATE") && dry.affected.isEmpty)
        #expect(try await note(1) == "50% off")
        let r = try await e.apply(rw, table: t, changes: [
            .insert([.init("user_id", "2"), .init("total", "1.5"), .init("note", "new")]),
            .update(key: [.init("id", "1")], set: [.init("note", "it's \\ edited")]),
            .update(key: [.init("id", "2")], set: [.init("total", "3")]),  // same value: MySQL reports 0 rows → verified
            .delete(key: [.init("id", "3")]),
        ])
        #expect(r.affected == [1, 1, 1, 1], "\(d)")
        #expect(try await note(1) == "it's \\ edited")
        #expect(try await e.execute(ro, "SELECT COUNT(*) FROM \(q) WHERE id = 3").rows[0][0] == "0")
        await #expect(throws: RowbaseError.self) {  // missing row → whole batch rolled back
            try await e.apply(rw, table: t, changes: [.update(key: [.init("id", "1")], set: [.init("note", "rolled back")]), .delete(key: [.init("id", "999")])])
        }
        #expect(try await note(1) == "it's \\ edited")
        for bad: [RowChange] in [[.update(key: [.init("user_id", "1")], set: [.init("note", "x")])],
                                 [.update(key: [.init("id", "1")], set: [.init("nope", "x")])],
                                 [.update(key: [.init("id", "1")], set: [.init("note; DROP", "x")])]] {
            await #expect(throws: RowbaseError.self) { try await e.apply(rw, table: t, changes: bad) }
        }
        await #expect(throws: RowbaseError.self) { try await e.apply(ro, table: t, changes: [.delete(key: [.init("id", "1")])]) }
        await e.reset()
    }

    @Test func sshTunnel() async throws {
        let fake = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../tests/fixtures/fake_ssh.py").standardizedFileURL.path
        let log = Fixture.home.appendingPathComponent("ssh.log").path
        setenv("ROWBASE_SSH", fake, 1); setenv("FAKE_SSH_LOG", log, 1)
        defer { unsetenv("ROWBASE_SSH"); TunnelManager.shutdown() }
        guard TunnelManager.canConnect(5432) else { print("skip ssh: no Postgres on TCP 5432"); return }
        let c = try Fixture.store.upsert(Connection(name: "via-ssh", driver: "postgres", host: "127.0.0.1", port: 5432, database: "postgres",
                                                    ssh: SSHConfig(host: "bastion.example", port: 2222, user: "deploy")))
        let e = Engine(store: Fixture.store)
        #expect(try await e.execute(c, "SELECT inet_server_port()").rows[0][0] == "5432")
        let argv = try String(contentsOfFile: log, encoding: .utf8)
        #expect(argv.contains("-p 2222") && argv.contains("deploy@bastion.example") && argv.contains(":127.0.0.1:5432") && argv.contains("BatchMode=yes"))
        let bad = Connection(name: "bad", driver: "postgres", host: "db", ssh: SSHConfig(host: "fail.example"))
        await #expect(throws: RowbaseError.self) { try await e.execute(bad, "SELECT 1") }
        #expect(ConnectionURL.parse("mysql://u@db/app?ssh=deploy@bastion:2222")?.0.ssh == SSHConfig(host: "bastion", port: 2222, user: "deploy"))
        #expect(ConnectionURL.parse("ssh://x@y") == nil)
        await e.reset()
    }
}
