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
                .background(env == "prod" ? Color.red.opacity(0.85) : Color.secondary.opacity(0.18), in: Capsule())
                .foregroundStyle(env == "prod" ? Color.white : Color.secondary)
        }
    }
}

/// "Read-only" (secondary) / "Read-write" (red) capsule.
struct AccessPill: View {
    let readOnly: Bool
    var short = false
    var body: some View {
        Text(readOnly ? (short ? "RO" : "Read-only") : (short ? "RW" : "Read-write"))
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(readOnly ? Color.secondary.opacity(0.18) : Color.red.opacity(0.85), in: Capsule())
            .foregroundStyle(readOnly ? Color.secondary : Color.white)
            .fixedSize()
    }
}

/// Small caps section header ("TABLES  12").
struct SectionLabel: View {
    let title: String
    var count: Int?
    var body: some View {
        HStack(spacing: 4) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6)
            if let count { Text("\(count)").font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary) }
        }
        .foregroundStyle(.secondary)
    }
}

/// Borderless 24×22 icon button with a tooltip (used by all toolbars).
struct IconButton: View {
    let symbol: String
    let help: String
    var active = false
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                .frame(width: 26, height: 22)
                .background(active ? Color.accentColor.opacity(0.14) : (hover ? Color.primary.opacity(0.07) : .clear), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Look of a menu used as an icon button in the tab toolbars.
struct IconMenuLabel: View {
    let symbol: String
    var active = false
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12))
            .foregroundStyle(active ? Color.accentColor : Color.secondary)
            .frame(width: 26, height: 22)
            .contentShape(Rectangle())
    }
}

/// 1234 → "1.2K", 3_400_000 → "3.4M".
func compactCount(_ n: Int) -> String {
    let a = Double(abs(n))
    func f(_ v: Double, _ suffix: String) -> String {
        let s = v < 10 ? String(format: "%.1f", v) : String(format: "%.0f", v)
        return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + suffix
    }
    if a < 1000 { return String(n) }
    if a < 1_000_000 { return f(a / 1000, "K") }
    if a < 1_000_000_000 { return f(a / 1_000_000, "M") }
    return f(a / 1_000_000_000, "B")
}

/// Numeric column types that get right-aligned monospaced digits in the grid.
func isNumericType(_ type: String) -> Bool {
    let t = type.lowercased().trimmingCharacters(in: .whitespaces)
    let base = t.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
    if base == "tinyint" {  // tinyint(1) is a boolean in MySQL
        guard let o = t.firstIndex(of: "("), let c = t.firstIndex(of: ")"), o < c else { return true }
        return (Int(t[t.index(after: o)..<c]) ?? 4) > 1
    }
    let nums: Set<Substring> = ["int", "integer", "bigint", "smallint", "mediumint", "decimal", "numeric", "float", "double", "real",
                                "serial", "bigserial", "smallserial", "int2", "int4", "int8", "float4", "float8", "money"]
    return nums.contains(base)
}

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

func formatElapsed(_ e: Double) -> String { String(format: "%.3f s", e) }

func formatMs(_ e: Double) -> String {
    e < 1 ? String(format: "%.0f ms", e * 1000) : String(format: "%.2f s", e)
}

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

/// UserDefaults used for UI state. With ROWBASE_HOME set (scratch/test homes) state goes to a per-home suite so
/// automated runs never touch the user's real saved tabs, hidden columns or selections.
enum AppDefaults {
    nonisolated(unsafe) static let store: UserDefaults = {
        if let home = ProcessInfo.processInfo.environment["ROWBASE_HOME"], !home.isEmpty {
            var h: UInt64 = 5381
            for b in home.utf8 { h = (h &* 33) &+ UInt64(b) }
            if let u = UserDefaults(suiteName: "rowbase.home.\(h)") { return u }
        }
        return .standard
    }()
}

// MARK: - Selectable text (AppKit)

/// Read-only, selectable text backed by an AppKit label. Replaces SwiftUI `Text(...).textSelection(.enabled)`:
/// on macOS 15.0 selectable SwiftUI text whose content changes crashed in CoreText (pointer-auth trap while
/// releasing the old string, see crash report 2026-10-05). AppKit labels take a different, stable rendering path.
struct SelectableText: NSViewRepresentable {
    var attributed: NSAttributedString
    var wraps = true
    var maxLines = 0

    init(_ text: String, font: NSFont = .systemFont(ofSize: NSFont.systemFontSize), color: NSColor = .labelColor,
         wraps: Bool = true, maxLines: Int = 0) {
        attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        (self.wraps, self.maxLines) = (wraps, maxLines)
    }

    init(attributed: NSAttributedString, wraps: Bool = true, maxLines: Int = 0) {
        (self.attributed, self.wraps, self.maxLines) = (attributed, wraps, maxLines)
    }

    func makeNSView(context: Context) -> NSTextField {
        let f = wraps ? NSTextField(wrappingLabelWithString: "") : NSTextField(labelWithString: "")
        f.isSelectable = true
        f.isEditable = false
        f.drawsBackground = false
        f.isBordered = false
        f.allowsEditingTextAttributes = true  // keep our attributes while selecting
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        if !f.attributedStringValue.isEqual(to: attributed) { f.attributedStringValue = attributed }
        f.maximumNumberOfLines = maxLines
        f.lineBreakMode = wraps ? .byWordWrapping : .byClipping
        f.cell?.truncatesLastVisibleLine = maxLines > 0
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView f: NSTextField, context: Context) -> CGSize? {
        let width = wraps ? (proposal.width ?? 480) : .greatestFiniteMagnitude
        let size = f.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)) ?? .zero
        return CGSize(width: wraps ? (proposal.width ?? ceil(size.width)) : ceil(size.width), height: ceil(size.height))
    }
}

extension NSFont {
    static func mono(_ size: CGFloat = 12) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
}
