import Foundation
import Testing
@testable import RowbaseCore

/// Byte-identical with Python: both suites read tests/export_vectors.json.
@Suite struct ExportTests {
    struct Vectors: Decodable { let cols: [String]; let rows: [[String?]]; let expected: [String: String] }
    let v: Vectors = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../tests/export_vectors.json").standardizedFileURL
        return try! JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }()

    @Test func formats() throws {
        for f in [ExportFormat.csv, .tsv, .json, .md] {
            #expect(try Exporter.render(columns: v.cols, rows: v.rows, format: f) == v.expected[f.rawValue], "\(f)")
        }
        for (d, table) in [(Dialect.mysql, "orders"), (.postgres, "crm.orders"), (.sqlite, "orders")] {
            #expect(try Exporter.render(columns: v.cols, rows: v.rows, format: .sql, table: table, dialect: d) == v.expected["sql_\(d.rawValue)"], "\(d)")
        }
        #expect(throws: RowbaseError.self) { try Exporter.render(columns: ["a"], rows: [], format: .sql) }
    }
}
