import Foundation

/// Read-only SQL guard — port of rowbase/guard.py; conformance vectors: tests/guard_vectors.json.
/// Defense in depth only: drivers already execute one statement per call inside a READ ONLY transaction.
public enum SQLGuard {
    public static let allowed: [Dialect: Set<String>] = [
        .mysql: ["SELECT", "SHOW", "DESC", "DESCRIBE", "EXPLAIN", "WITH", "VALUES", "TABLE"],
        .postgres: ["SELECT", "SHOW", "EXPLAIN", "WITH", "VALUES", "TABLE"],
        .sqlite: ["SELECT", "EXPLAIN", "WITH", "VALUES", "PRAGMA"],
    ]
    static let forbidden: [Dialect: [NSRegularExpression]] = {
        let src: [Dialect: [String]] = [
            .mysql: [#"\bINTO\s+(OUT|DUMP)FILE\b"#, #"\bFOR\s+UPDATE\b"#, #"\bLOCK\s+IN\s+SHARE\s+MODE\b"#, #"\bFOR\s+SHARE\b"#,
                     #"\bGET_LOCK\s*\("#, #"\bSLEEP\s*\("#, #"\bBENCHMARK\s*\("#, #"\bLOAD_FILE\s*\("#],
            .postgres: [#"\bINTO\b"#, #"\bFOR\s+(NO\s+KEY\s+)?(UPDATE|SHARE)\b"#, #"\bFOR\s+KEY\s+SHARE\b"#, #"\bPG_SLEEP\w*\s*\("#,
                        #"\bPG_ADVISORY\w*\s*\("#, #"\bDBLINK\w*\s*\("#, #"\bLO_\w+\s*\("#, #"\bPG_(READ|WRITE|STAT)_\w*FILE\s*\("#,
                        #"\bPG_LS_\w+\s*\("#, #"\bSET_CONFIG\s*\("#, #"\bPG_(CANCEL|TERMINATE)_BACKEND\s*\("#, #"\bPG_RELOAD_CONF\s*\("#],
            .sqlite: [#"\bLOAD_EXTENSION\s*\("#, #"\bWRITEFILE\s*\("#, #"\bREADFILE\s*\("#, #"\bEDIT\s*\("#],
        ]
        return src.mapValues { $0.map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) } }
    }()

    /// Same-length (in UTF-8 bytes) copy with comments and literal/quoted-identifier contents blanked.
    public static func scan(_ sql: String, _ d: Dialect) -> [UInt8] {
        let s = Array(sql.utf8), n = s.count
        var out = s, i = 0
        func blank(_ a: Int, _ b: Int) { for k in a..<b { out[k] = 0x20 } }
        func isWord(_ c: UInt8) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c >= 0x80 }
        while i < n {
            let c = s[i], nx: UInt8 = i + 1 < n ? s[i + 1] : 0
            if (c == 0x2D && nx == 0x2D) || (c == 0x23 && d == .mysql) {                  // -- or # comment
                var j = i; while j < n && s[j] != 0x0A { j += 1 }
                blank(i, j); i = j; continue
            }
            if c == 0x2F && nx == 0x2A {                                                   // /* comment */
                var j = i + 2; while j + 1 < n && !(s[j] == 0x2A && s[j + 1] == 0x2F) { j += 1 }
                j = j + 1 < n ? j + 2 : n
                blank(i, j); i = j; continue
            }
            if c == 0x27 || c == 0x22 || c == 0x60 {                                       // ' " `
                let bs = d == .mysql || (d == .postgres && c == 0x27 && i > 0 && (s[i - 1] == 0x45 || s[i - 1] == 0x65)
                                         && (i < 2 || !isWord(s[i - 2])))
                var j = i + 1
                while j < n {
                    if bs && s[j] == 0x5C { j += 2; continue }
                    if s[j] == c { if j + 1 < n && s[j + 1] == c { j += 2; continue }; break }
                    j += 1
                }
                j = min(j + 1, n)
                blank(i, j); out[i] = 0x27; if j - i > 1 { out[j - 1] = 0x27 }
                i = j; continue
            }
            if c == 0x24 && d == .postgres && !(i > 0 && isWord(s[i - 1])) {                // $tag$ … $tag$
                var j = i + 1
                while j < n && isWord(s[j]) && s[j] < 0x80 { j += 1 }
                if j < n && s[j] == 0x24 && (j == i + 1 || !(s[i + 1] >= 0x30 && s[i + 1] <= 0x39)) {
                    let tag = Array(s[i...j]); var k = j + 1, end = n
                    while k + tag.count <= n { if Array(s[k..<k + tag.count]) == tag { end = k + tag.count; break }; k += 1 }
                    blank(i, end); out[i] = 0x27; if end - i > 1 { out[end - 1] = 0x27 }
                    i = end; continue
                }
            }
            i += 1
        }
        return out
    }

    /// (clean, firstWord, bare): clean = original SQL minus trailing ';' and trailing comments.
    public static func analyze(_ sql: String, _ d: Dialect) -> (clean: String, first: String, bare: String) {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        var b = scan(trimmed, d)
        func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0B || c == 0x0C }
        while let l = b.last, isSpace(l) || l == 0x3B { b.removeLast() }
        let clean = String(decoding: Array(trimmed.utf8).prefix(b.count), as: UTF8.self)
        let bare = String(decoding: b, as: UTF8.self)
        var first = ""
        for ch in bare.unicodeScalars {
            if ch.properties.isAlphabetic && ch.isASCII { first.unicodeScalars.append(ch) }
            else if first.isEmpty && (ch == "(" || CharacterSet.whitespacesAndNewlines.contains(ch)) { continue }
            else { break }
        }
        return (clean, first.uppercased(), bare)
    }

    @discardableResult
    public static func check(_ sql: String, _ d: Dialect) throws -> (clean: String, first: String, bare: String) {
        let r = analyze(sql, d)
        guard !r.bare.isEmpty else { throw RowbaseError("Empty query.") }
        guard !r.bare.contains(";") else { throw RowbaseError("Refused: only one statement per call.") }
        let ok = allowed[d]!
        guard ok.contains(r.first) else {
            throw RowbaseError("Refused: read-only connection, '\(r.first)' is not allowed (allowed: \(ok.sorted().joined(separator: ", "))).")
        }
        let range = NSRange(r.bare.startIndex..., in: r.bare)
        for re in forbidden[d]! where re.firstMatch(in: r.bare, range: range) != nil {
            throw RowbaseError("Refused: pattern \(re.pattern) is not allowed on a read-only connection.")
        }
        return r
    }
}
