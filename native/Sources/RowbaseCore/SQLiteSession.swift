import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite via the system library. Read-only connections open the file with mode=ro; timeout via progress handler.
final class SQLiteSession: DBSession, @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private final class Deadline { var at: Double = 0 }
    private let deadline = Deadline()

    init(path raw: String, readOnly: Bool) throws {
        let path = NSString(string: raw).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { throw RowbaseError("SQLite file not found: \(path)") }
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(db)
            throw RowbaseError("Connection error: \(msg)")
        }
        sqlite3_busy_timeout(db, 5000)
        let ctx = Unmanaged.passUnretained(deadline).toOpaque()
        sqlite3_progress_handler(db, 20000, { p in
            let d = Unmanaged<Deadline>.fromOpaque(p!).takeUnretainedValue()
            return d.at > 0 && Date().timeIntervalSince1970 > d.at ? 1 : 0
        }, ctx)
    }

    deinit { sqlite3_close(db) }

    var isAlive: Bool { db != nil }

    func close() async {
        lock.withLock { sqlite3_close(db); db = nil }
    }

    private func error(_ prefix: String = "SQL error") -> RowbaseError {
        RowbaseError("\(prefix): \(String(cString: sqlite3_errmsg(db)))")
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    func run(_ sql: String, readOnly: Bool, timeout: Int, maxRows: Int) async throws -> QueryResult {
        try lock.withLock {
            guard db != nil else { throw RowbaseError("Connection closed.") }
            deadline.at = Date().timeIntervalSince1970 + Double(timeout)
            defer { deadline.at = 0 }
            try exec("BEGIN")
            var committed = false
            defer { if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
            let started = Date()
            var stmt: OpaquePointer?, tail: UnsafePointer<CChar>?
            let bytes = Array(sql.utf8CString)
            let rc = bytes.withUnsafeBufferPointer { buf in sqlite3_prepare_v2(db, buf.baseAddress, -1, &stmt, &tail) }
            guard rc == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(stmt) }
            // one statement only: anything but whitespace/comments after the first statement is refused
            if let tail, tail.pointee != 0 {
                var next: OpaquePointer?
                sqlite3_prepare_v2(db, tail, -1, &next, nil)
                if next != nil { sqlite3_finalize(next); throw RowbaseError("SQL error: You can only execute one statement at a time.") }
            }
            guard let stmt else { throw RowbaseError("Empty query.") }
            let n = Int(sqlite3_column_count(stmt))
            let cols = (0..<n).map { String(cString: sqlite3_column_name(stmt, Int32($0))) }
            var rows: [[String?]] = [], truncated = false
            while true {
                let s = sqlite3_step(stmt)
                if s == SQLITE_DONE { break }
                guard s == SQLITE_ROW else {
                    throw s == SQLITE_INTERRUPT ? RowbaseError("SQL error: interrupted (timeout \(timeout)s)") : error()
                }
                if rows.count >= maxRows { truncated = true; break }
                rows.append((0..<n).map { i -> String? in
                    let c = Int32(i)
                    switch sqlite3_column_type(stmt, c) {
                    case SQLITE_NULL: return nil
                    case SQLITE_BLOB:
                        let len = Int(sqlite3_column_bytes(stmt, c))
                        guard let p = sqlite3_column_blob(stmt, c) else { return "" }
                        return Format.bytes(Array(UnsafeBufferPointer(start: p.assumingMemoryBound(to: UInt8.self), count: len)))
                    default: return String(cString: sqlite3_column_text(stmt, c))
                    }
                })
            }
            let elapsed = Date().timeIntervalSince(started)
            let affected: Int? = n == 0 ? Int(sqlite3_changes(db)) : nil
            if !readOnly { try exec("COMMIT"); committed = true }
            return QueryResult(columns: cols, rows: rows, truncated: truncated, elapsed: elapsed, affected: affected)
        }
    }
}
