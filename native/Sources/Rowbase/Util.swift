import SwiftUI
import AppKit
import RowbaseCore

func hexColor(_ hex: String?) -> Color? {
    guard var h = hex?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
    if h.hasPrefix("#") { h.removeFirst() }
    guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
    return Color(.sRGB, red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
}

func hexString(_ c: Color) -> String {
    let ns = NSColor(c).usingColorSpace(.sRGB) ?? .gray
    return String(format: "#%02x%02x%02x", Int(round(ns.redComponent * 255)), Int(round(ns.greenComponent * 255)), Int(round(ns.blueComponent * 255)))
}

struct ConnDot: View {
    let color: String?
    var size: CGFloat = 9
    var body: some View {
        Circle().fill(hexColor(color) ?? Color.gray.opacity(0.6)).frame(width: size, height: size)
    }
}

struct EnvPill: View {
    let env: String?
    var body: some View {
        if let env, !env.isEmpty {
            Text(env)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(env == "prod" ? Color.red.opacity(0.85) : Color.secondary.opacity(0.2), in: Capsule())
                .foregroundStyle(env == "prod" ? Color.white : Color.secondary)
        }
    }
}

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

func formatElapsed(_ e: Double) -> String { String(format: "%.3f s", e) }

enum Export {
    static func tsv(columns: [String], rows: [[String?]], header: Bool = true) -> String {
        func cell(_ v: String?) -> String { (v ?? "NULL").replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: "\\n") }
        var lines: [String] = []
        if header { lines.append(columns.joined(separator: "\t")) }
        for r in rows { lines.append(r.map(cell).joined(separator: "\t")) }
        return lines.joined(separator: "\n")
    }

    static func jsonString(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let out = String(data: d, encoding: .utf8) else { return "\"\"" }
        return out
    }

    static func jsonValue(_ v: String?) -> String {
        guard let v else { return "null" }
        if v.range(of: #"^-?(0|[1-9]\d{0,14})(\.\d+)?$"#, options: .regularExpression) != nil { return v }
        return jsonString(v)
    }

    static func jsonObject(columns: [String], row: [String?], indent: String = "  ") -> String {
        let body = columns.enumerated().map { "\(indent)  \(jsonString($0.element)): \(jsonValue($0.offset < row.count ? row[$0.offset] : nil))" }
        return "\(indent){\n" + body.joined(separator: ",\n") + "\n\(indent)}"
    }

    static func json(columns: [String], rows: [[String?]]) -> String {
        "[\n" + rows.map { jsonObject(columns: columns, row: $0) }.joined(separator: ",\n") + "\n]"
    }
}

enum SQLSplit {
    /// Segment ranges (UTF-16) split on ';' outside quotes/comments. Each range includes its trailing ';'.
    static func segments(_ s: [UInt16], _ d: Dialect) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var start = 0, i = 0
        let n = s.count
        while i < n {
            let c = s[i], nx: UInt16 = i + 1 < n ? s[i + 1] : 0
            if c == 39 || c == 34 || c == 96 {
                var j = i + 1
                while j < n {
                    if d == .mysql && s[j] == 92 { j += 2; continue }
                    if s[j] == c { if j + 1 < n && s[j + 1] == c { j += 2; continue }; break }
                    j += 1
                }
                i = min(j + 1, n); continue
            }
            if (c == 45 && nx == 45) || (c == 35 && d == .mysql) {
                while i < n && s[i] != 10 { i += 1 }
                continue
            }
            if c == 47 && nx == 42 {
                var j = i + 2
                while j + 1 < n && !(s[j] == 42 && s[j + 1] == 47) { j += 1 }
                i = min(j + 2, n); continue
            }
            if c == 59 { out.append((start, i + 1)); start = i + 1 }
            i += 1
        }
        if start < n { out.append((start, n)) }
        return out
    }

    static func statement(in text: String, selection: NSRange, dialect: Dialect) -> String {
        let ns = text as NSString
        if selection.length > 0, selection.location + selection.length <= ns.length {
            let sel = ns.substring(with: selection).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sel.isEmpty { return sel }
        }
        let u = Array(text.utf16)
        let segs = segments(u, dialect)
        func str(_ r: (Int, Int)) -> String { ns.substring(with: NSRange(location: r.0, length: r.1 - r.0)).trimmingCharacters(in: .whitespacesAndNewlines) }
        func blank(_ r: (Int, Int)) -> Bool {
            let t = str(r)
            return t.isEmpty || t == ";"
        }
        guard !segs.isEmpty else { return "" }
        let p = min(selection.location, u.count)
        var idx = segs.firstIndex(where: { p <= $0.1 }) ?? segs.count - 1
        if blank(segs[idx]) {
            if let prev = (0..<idx).reversed().first(where: { !blank(segs[$0]) }) { idx = prev }
            else if let next = (idx..<segs.count).first(where: { !blank(segs[$0]) }) { idx = next }
            else { return "" }
        }
        return str(segs[idx])
    }
}

/// True when the app was launched for an automated snapshot (ROWBASE_SNAPSHOT=…).
let isSnapshot = ProcessInfo.processInfo.environment["ROWBASE_SNAPSHOT"] != nil
