import Foundation
import Testing
@testable import RowbaseCore

/// Same SQL as rowbase/query.py: both suites read tests/query_vectors.json.
@Suite struct QueryBuilderTests {
    struct Filter: Decodable { let dialect: String; let group: FilterGroup; let types: [String: String]; let expected: String }
    struct Query: Decodable { let dialect: String; let spec: QuerySpec; let types: [String: [String: String]]; let expected: String }
    struct Values: Decodable { let dialect: String; let table: String; let col: String; let `where`: String; let search: String; let type: String; let limit: Int; let expected: String }
    struct Failure: Decodable { let dialect: String; let kind: String; let group: FilterGroup?; let spec: QuerySpec? }
    struct Vectors: Decodable { let filters: [Filter]; let queries: [Query]; let values: [Values]; let errors: [Failure] }
    let v: Vectors = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../tests/query_vectors.json").standardizedFileURL
        return try! JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }()

    @Test func filters() throws {
        for f in v.filters {
            #expect(try QueryBuilder.filterWhere(Dialect(driver: f.dialect), f.group, types: f.types) == f.expected, "\(f.dialect) \(f.group)")
        }
    }

    @Test func queries() throws {
        for q in v.queries {
            #expect(try QueryBuilder.selectSQL(Dialect(driver: q.dialect), q.spec, types: q.types) == q.expected, "\(q.dialect) \(q.expected)")
        }
    }

    @Test func values() throws {
        for x in v.values {
            let sql = try QueryBuilder.valuesSQL(Dialect(driver: x.dialect), table: x.table, column: x.col, where: x.where, search: x.search, type: x.type, limit: x.limit)
            #expect(sql == x.expected)
        }
    }

    @Test func errors() {
        for e in v.errors {
            let d = Dialect(driver: e.dialect)
            #expect(throws: RowbaseError.self, "\(e)") {
                if e.kind == "filter" { _ = try QueryBuilder.filterWhere(d, e.group) } else { _ = try QueryBuilder.selectSQL(d, e.spec!) }
            }
        }
    }
}
