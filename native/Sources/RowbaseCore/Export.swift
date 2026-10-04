import Foundation

/// Result export — byte-identical with rowbase/export.py (vectors: tests/export_vectors.json).
public enum ExportFormat: String, CaseIterable, Sendable {
    case csv, tsv, json, md, sql

    public var title: String { ["csv": "CSV", "tsv": "TSV", "json": "JSON", "md": "Markdown", "sql": "SQL INSERT"][rawValue]! }
    public var fileExtension: String { rawValue }
}

public enum Exporter {
    public static func render(columns: [String], rows: [[String?]], format: ExportFormat, table: String? = nil, dialect: Dialect? = nil) throws -> String {
        switch format {
        case .csv:
            func cell(_ v: String?) -> String {
                let s = v ?? ""
                // unicodeScalars: "\r\n" is ONE Character in Swift, so a Character test would miss a bare "\n"
                return s.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
            }
            return ([columns.map(Optional.some)] + rows).map { $0.map(cell).joined(separator: ",") + "\r\n" }.joined()
        case .tsv:
            func clean(_ v: String?) -> String {
                (v ?? "").replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            }
            return ([columns.map(Optional.some)] + rows).map { $0.map(clean).joined(separator: "\t") }.joined(separator: "\n") + "\n"
        case .json:
            // matches Python json.dumps(indent=2, ensure_ascii=False)
            if rows.isEmpty { return "[]\n" }
            let objs = rows.map { r in
                "  {\n" + zip(columns, r).map { "    \(jsonString($0)): \($1.map(jsonString) ?? "null")" }.joined(separator: ",\n") + "\n  }"
            }
            return "[\n" + objs.joined(separator: ",\n") + "\n]\n"
        case .md:
            func clean(_ v: String?) -> String {
                guard let v else { return "NULL" }
                return v.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            }
            let head = ["| " + columns.map(clean).joined(separator: " | ") + " |", "|" + columns.map { _ in "---" }.joined(separator: "|") + "|"]
            return (head + rows.map { "| " + $0.map(clean).joined(separator: " | ") + " |" }).joined(separator: "\n") + "\n"
        case .sql:
            guard let table, let d = dialect else { throw RowbaseError("SQL export needs a table name") }
            let head = "INSERT INTO \(d.ident(table)) (" + columns.map(d.column).joined(separator: ", ") + ") VALUES ("
            return rows.map { head + $0.map { $0.map(d.literal) ?? "NULL" }.joined(separator: ", ") + ");\n" }.joined()
        }
    }

    static func jsonString(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
}
