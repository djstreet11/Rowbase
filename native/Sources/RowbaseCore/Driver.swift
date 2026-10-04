import Foundation

/// One open database session. Implementations must execute exactly ONE statement per `run` (driver-level guarantee),
/// wrap it in a READ ONLY transaction when `readOnly`, and always roll back unless writes are allowed.
public protocol DBSession: AnyObject, Sendable {
    func run(_ sql: String, readOnly: Bool, timeout: Int, maxRows: Int) async throws -> QueryResult
    var isAlive: Bool { get }
    func close() async
    /// Statement that cancels this session's running query when executed from ANOTHER session; nil → use interrupt().
    var cancelSQL: String? { get }
    /// In-process cancel (SQLite). Must be safe to call from any thread while `run` is executing.
    func interrupt()
}

public extension DBSession {
    var cancelSQL: String? { nil }
    func interrupt() {}
}

/// Catalog SQL per dialect — same queries and column order as rowbase/drivers.py.
public enum Catalog {
    public static func version(_ d: Dialect) -> String {
        switch d {
        case .mysql: "SELECT VERSION()"
        case .postgres: "SELECT version()"
        case .sqlite: "SELECT 'SQLite ' || sqlite_version()"
        }
    }

    static let pgName = "CASE WHEN %1$@.nspname = 'public' THEN %2$@.relname ELSE %1$@.nspname || '.' || %2$@.relname END"

    public static func tables(_ d: Dialect) -> String {
        switch d {
        case .mysql:
            "SELECT TABLE_NAME, TABLE_ROWS, CASE WHEN TABLE_TYPE LIKE '%VIEW%' THEN 'view' ELSE 'table' END "
                + "FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() ORDER BY TABLE_NAME"
        case .postgres:
            "SELECT \(String(format: pgName, "n", "c")), NULLIF(c.reltuples, -1)::bigint, "
                + "CASE WHEN c.relkind IN ('v', 'm') THEN 'view' ELSE 'table' END "
                + "FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f') "
                + "AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg\\_%' ORDER BY 1"
        case .sqlite:
            "SELECT name, NULL, type FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name"
        }
    }

    static func reg(_ t: String) -> String { "\(Dialect.postgres.literal(Dialect.postgres.ident(t)))::regclass" }

    public static func columns(_ d: Dialect, _ t: String) -> String {
        switch d {
        case .mysql:
            "SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE = 'YES', COLUMN_KEY, COLUMN_DEFAULT FROM information_schema.COLUMNS "
                + "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = \(d.literal(t)) ORDER BY ORDINAL_POSITION"
        case .postgres:
            "SELECT a.attname, format_type(a.atttypid, a.atttypmod), NOT a.attnotnull, "
                + "CASE WHEN EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = a.attrelid AND i.indisprimary AND a.attnum = ANY (i.indkey)) "
                + "THEN 'PRI' ELSE '' END, pg_get_expr(d.adbin, d.adrelid) "
                + "FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum "
                + "WHERE a.attrelid = \(reg(t)) AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum"
        case .sqlite:
            "SELECT name, type, NOT \"notnull\", CASE WHEN pk THEN 'PRI' ELSE '' END, dflt_value FROM pragma_table_info(\(d.literal(t))) ORDER BY cid"
        }
    }

    public static func indexes(_ d: Dialect, _ t: String) -> String {
        switch d {
        case .mysql:
            "SELECT INDEX_NAME, NON_UNIQUE = 0, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) FROM information_schema.STATISTICS "
                + "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = \(d.literal(t)) GROUP BY INDEX_NAME, NON_UNIQUE ORDER BY INDEX_NAME"
        case .postgres:
            "SELECT ic.relname, i.indisunique, (SELECT string_agg(a.attname, ',' ORDER BY k.ord) "
                + "FROM unnest(i.indkey::int2[]) WITH ORDINALITY k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum) "
                + "FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid WHERE i.indrelid = \(reg(t)) ORDER BY 1"
        case .sqlite:
            "SELECT il.name, il.\"unique\", (SELECT group_concat(name, ',') FROM pragma_index_info(il.name)) FROM pragma_index_list(\(d.literal(t))) il ORDER BY 1"
        }
    }

    /// Outgoing FKs: (column, target table, target column).
    public static func foreignKeys(_ d: Dialect, _ t: String) -> String {
        switch d {
        case .mysql:
            "SELECT COLUMN_NAME, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE "
                + "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = \(d.literal(t)) AND REFERENCED_TABLE_NAME IS NOT NULL"
        case .postgres: pgFK(out: true, t)
        case .sqlite:
            "SELECT f.\"from\", f.\"table\", COALESCE(f.\"to\", (SELECT name FROM pragma_table_info(f.\"table\") WHERE pk = 1)) "
                + "FROM pragma_foreign_key_list(\(d.literal(t))) f"
        }
    }

    /// Incoming FKs: (referencing table, its column, our column).
    public static func referencedBy(_ d: Dialect, _ t: String) -> String {
        switch d {
        case .mysql:
            "SELECT TABLE_NAME, COLUMN_NAME, REFERENCED_COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE "
                + "WHERE REFERENCED_TABLE_SCHEMA = DATABASE() AND REFERENCED_TABLE_NAME = \(d.literal(t)) ORDER BY TABLE_NAME, COLUMN_NAME"
        case .postgres: pgFK(out: false, t)
        case .sqlite:
            "SELECT m.name, f.\"from\", COALESCE(f.\"to\", (SELECT name FROM pragma_table_info(f.\"table\") WHERE pk = 1)) "
                + "FROM sqlite_master m, pragma_foreign_key_list(m.name) f WHERE m.type = 'table' AND lower(f.\"table\") = lower(\(d.literal(t))) ORDER BY 1, 2"
        }
    }

    static func pgFK(out: Bool, _ t: String) -> String {
        let (src, dst) = out ? ("conrelid", "confrelid") : ("confrelid", "conrelid")
        let (skey, dkey) = out ? ("conkey", "confkey") : ("confkey", "conkey")
        let other = String(format: pgName, "tn", "tc")
        let cols = out ? "a.attname, \(other), af.attname" : "\(other), af.attname, a.attname"
        return "SELECT \(cols) FROM pg_constraint c CROSS JOIN LATERAL unnest(c.\(skey), c.\(dkey)) AS k(s, d) "
            + "JOIN pg_attribute a ON a.attrelid = c.\(src) AND a.attnum = k.s JOIN pg_attribute af ON af.attrelid = c.\(dst) AND af.attnum = k.d "
            + "JOIN pg_class tc ON tc.oid = c.\(dst) JOIN pg_namespace tn ON tn.oid = tc.relnamespace "
            + "WHERE c.contype = 'f' AND c.\(src) = \(reg(t)) ORDER BY 1, 2"
    }
}

/// Display formatting shared by drivers: 16-byte binaries → UUID, other non-UTF-8 → 0xHEX.
enum Format {
    static func bytes(_ b: [UInt8]) -> String {
        if b.count == 16 {
            let u = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
            return u.uuidString.lowercased()
        }
        if let s = String(bytes: b, encoding: .utf8) { return s }
        return "0x" + b.map { String(format: "%02X", $0) }.joined()
    }
}
