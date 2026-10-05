import Foundation
import SQLite3
import Testing
@testable import RowbaseCore

/// Implicit-reference heuristics, shared with Python via tests/ref_vectors.json.
@Suite struct RefsTests {
    struct Vectors: Decodable {
        struct Hint: Decodable { let column: String; let columns: [String]; let expect: String? }
        struct Cand: Decodable { let column: String; let hint: String?; let tables: [String]; let expect: [String] }
        let uuid: [[Value]]
        let words: [[Value]]
        let hint: [Hint]
        let candidates: [Cand]
    }
    enum Value: Decodable {
        case s(String), b(Bool), a([String])
        init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if let v = try? c.decode(Bool.self) { self = .b(v) } else if let v = try? c.decode(String.self) { self = .s(v) } else { self = .a(try c.decode([String].self)) }
        }
        var s: String { if case .s(let v) = self { v } else { "" } }
        var b: Bool { if case .b(let v) = self { v } else { false } }
        var a: [String] { if case .a(let v) = self { v } else { [] } }
    }
    let v: Vectors = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../tests/ref_vectors.json").standardizedFileURL
        return try! JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }()

    @Test func vectors() {
        for c in v.uuid { #expect(Refs.isUUID(c[0].s) == c[1].b, "\(c[0].s)") }
        for c in v.words { #expect(Refs.words(c[0].s) == c[1].a, "\(c[0].s)") }
        for c in v.hint { #expect(Refs.hintColumn(for: c.column, in: c.columns) == c.expect, "\(c.column)") }
        for c in v.candidates { #expect(Refs.candidates(column: c.column, hint: c.hint, tables: c.tables) == c.expect, "\(c.column)") }
    }

    @Test func lookupSQL() {
        let t = [RefTable(name: "CatalogAddresses", pk: "Ref", pkType: "char(36)", labels: ["Description", "Code"]),
                 RefTable(name: "Bin", pk: "id", pkType: "binary(16)", labels: [])]
        #expect(Refs.lookupSQL(.mysql, tables: t, value: "7E6056B9-9582-11F1-A74C-005056BD6036") ==
            "SELECT 'CatalogAddresses' AS t, COALESCE(NULLIF(CAST(`Description` AS CHAR), ''), NULLIF(CAST(`Code` AS CHAR), ''), '') AS label "
            + "FROM `CatalogAddresses` WHERE `Ref` = '7e6056b9-9582-11f1-a74c-005056bd6036' UNION ALL "
            + "SELECT 'Bin' AS t, '' AS label FROM `Bin` WHERE `id` = UNHEX('7e6056b9958211f1a74c005056bd6036')")
    }
}

/// Resolution against real databases (own database / schema / file so it can run in parallel with EngineTests).
@Suite struct RefsEngineTests {
    static let addr = "7e6056b9-9582-11f1-a74c-005056bd6036"

    static func setup(_ d: Dialect, _ engine: Engine) async -> (Connection, String)? {
        var c: Connection, ddl: [String], table: String
        switch d {
        case .sqlite:
            let p = Fixture.home.appendingPathComponent("refs.db").path
            try? FileManager.default.createDirectory(at: Fixture.home, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(atPath: p)
            var db: OpaquePointer?
            sqlite3_open(p, &db)  // the engine opens existing files only
            sqlite3_close(db)
            c = Connection(name: "refs-lite", driver: "sqlite", path: p, readOnly: false)
            table = "CatalogAddresses"
            ddl = ["CREATE TABLE CatalogAddresses(Ref TEXT PRIMARY KEY, Description TEXT, Code TEXT)",
                   "CREATE TABLE Doc(Ref TEXT PRIMARY KEY, SenderAddress TEXT)", "CREATE TABLE Plain(id INTEGER PRIMARY KEY)"]
        case .postgres:
            c = Connection(name: "refs-pg", driver: "postgres", socket: "/tmp", database: "rowbase_test", readOnly: false)
            table = "rowbase_refs.CatalogAddresses"
            ddl = ["DROP SCHEMA IF EXISTS rowbase_refs CASCADE", "CREATE SCHEMA rowbase_refs",
                   "CREATE TABLE rowbase_refs.\"CatalogAddresses\"(\"Ref\" uuid PRIMARY KEY, \"Description\" text, \"Code\" int)",
                   "CREATE TABLE rowbase_refs.plain(id serial PRIMARY KEY)"]
        case .mysql:
            let boot = Connection(name: "refs-boot", driver: "mysql", socket: "/tmp/mysql.sock", readOnly: false)
            do {
                _ = try await engine.execute(boot, "DROP DATABASE IF EXISTS rowbase_refs")
                _ = try await engine.execute(boot, "CREATE DATABASE rowbase_refs")
            } catch { return nil }
            c = Connection(name: "refs-my", driver: "mysql", socket: "/tmp/mysql.sock", database: "rowbase_refs", readOnly: false)
            table = "CatalogAddresses"
            ddl = ["CREATE TABLE CatalogAddresses(Ref char(36) PRIMARY KEY, Description varchar(100), Code varchar(9))",
                   "CREATE TABLE CatalogBins(Ref binary(16) PRIMARY KEY, Name varchar(20))",
                   "INSERT INTO CatalogBins VALUES (UNHEX('a0eebc999c0b4ef8bb6d6bb9bd380a11'), 'bin')",
                   "CREATE TABLE Plain(id int PRIMARY KEY)"]
        }
        let ins = d == .postgres ? "INSERT INTO rowbase_refs.\"CatalogAddresses\" VALUES ('\(addr)', 'Kyiv, warehouse 4', 7)"
            : "INSERT INTO CatalogAddresses VALUES ('\(addr)', '', 'K-7')"
        do { for s in ddl + [ins] { _ = try await engine.execute(c, s) } } catch { return nil }
        c.readOnly = true
        return (c, table)
    }

    @Test(arguments: Dialect.allCases) func resolve(_ d: Dialect) async throws {
        let engine = Engine(store: Fixture.store)
        guard let (c, table) = await Self.setup(d, engine) else { #expect(d != .sqlite); return }
        let all = try await engine.refTables(c)
        let t = try #require(all.first { $0.name == table })
        #expect(t.labels == ["Description", "Code"])
        #expect(!all.contains { $0.name.lowercased().hasSuffix("plain") })
        let m = try await engine.resolveRef(c, value: Self.addr.uppercased(), candidates: [], all: all)
        // an empty Description falls back to the next label column
        #expect(m == [RefMatch(table: table, label: d == .postgres ? "Kyiv, warehouse 4" : "K-7")])
        #expect(try await engine.resolveRef(c, value: "00000000-0000-0000-0000-000000000001", candidates: [t], all: all).isEmpty)
        if d == .mysql {
            #expect(try await engine.resolveRef(c, value: "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11", candidates: [], all: all)
                == [RefMatch(table: "CatalogBins", label: "bin")])
        }
        await engine.reset()
    }
}
