"""Database drivers: connect, transaction/timeout control and catalog SQL per dialect.

Every driver executes exactly one statement per call (pymysql without MULTI_STATEMENTS, psycopg prepared,
sqlite3 refuses multiple) — the primary guarantee behind the read-only guard.
Catalog methods return SQL; the engine runs it as trusted inside the same read-only transaction.
"""
import os
import re
import time
from urllib.request import pathname2url


def lit(s, backslash=False):
    s = str(s).replace("'", "''")
    return "'" + (s.replace("\\", "\\\\") if backslash else s) + "'"


class MySQL:
    name, dialect, port, q = "mysql", "mysql", 3306, "`"

    def connect(self, c, password, timeout):
        import pymysql
        kw = dict(user=c.get("user") or None, password=password or "", database=c.get("database") or None, charset="utf8mb4",
                  connect_timeout=10, read_timeout=max(timeout, 60) + 5, write_timeout=60, autocommit=False)
        if c.get("socket"):
            kw["unix_socket"] = c["socket"]
        else:
            kw.update(host=c.get("host") or "127.0.0.1", port=int(c.get("port") or self.port))
        db = pymysql.connect(**kw)
        db.rb_timeout = None
        db.rb_mariadb = "mariadb" in (db.get_server_info() or "").lower()
        return db

    def begin(self, db, read_only, timeout):
        cur = db.cursor()
        if db.rb_timeout != timeout:
            for stmt in (f"SET SESSION max_execution_time={int(timeout) * 1000}",  # MySQL
                         f"SET SESSION max_statement_time={int(timeout)}"):     # MariaDB
                try:
                    cur.execute(stmt)
                except Exception:
                    pass
            db.rb_timeout = timeout
        cur.execute("START TRANSACTION READ ONLY" if read_only else "START TRANSACTION")

    _EXPLAIN_ANALYZE = re.compile(r"^\s*EXPLAIN\s+ANALYZE\s+", re.I)

    def run(self, db, sql):
        if getattr(db, "rb_mariadb", False):
            sql = self._EXPLAIN_ANALYZE.sub("ANALYZE ", sql, count=1)  # MariaDB spells EXPLAIN ANALYZE as ANALYZE <stmt>
        cur = db.cursor()
        cur.execute(sql)
        return cur

    def alive(self, db):
        return db.open

    def ident(self, name):
        return "`" + name.replace("`", "``") + "`"

    def lit(self, s):
        return lit(s, backslash=True)

    def version_sql(self):
        return "SELECT VERSION()"

    def databases_sql(self):
        return "SHOW DATABASES"

    def current_db_sql(self):
        return "SELECT DATABASE()"

    def tables_sql(self):
        return ("SELECT TABLE_NAME, TABLE_ROWS, CASE WHEN TABLE_TYPE LIKE '%VIEW%' THEN 'view' ELSE 'table' END "
                "FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() ORDER BY TABLE_NAME")

    def columns_sql(self, t):
        return ("SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE = 'YES', COLUMN_KEY, COLUMN_DEFAULT, COLUMN_COMMENT "
                f"FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = {self.lit(t)} ORDER BY ORDINAL_POSITION")

    def indexes_sql(self, t):
        return ("SELECT INDEX_NAME, NON_UNIQUE = 0, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) FROM information_schema.STATISTICS "
                f"WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = {self.lit(t)} GROUP BY INDEX_NAME, NON_UNIQUE ORDER BY INDEX_NAME")

    def fks_sql(self, t):
        return ("SELECT COLUMN_NAME, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE "
                f"WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = {self.lit(t)} AND REFERENCED_TABLE_NAME IS NOT NULL")

    def refby_sql(self, t):
        return ("SELECT TABLE_NAME, COLUMN_NAME, REFERENCED_COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE "
                f"WHERE REFERENCED_TABLE_SCHEMA = DATABASE() AND REFERENCED_TABLE_NAME = {self.lit(t)} ORDER BY TABLE_NAME, COLUMN_NAME")


class Postgres:
    """Tables outside the `public` schema are named `schema.table`."""
    name, dialect, port, q = "postgres", "postgres", 5432, '"'

    def connect(self, c, password, timeout):
        import psycopg
        kw = dict(user=c.get("user") or None, password=password or None, dbname=c.get("database") or None, connect_timeout=10,
                  autocommit=False, application_name="rowbase")
        host = c.get("socket") or c.get("host")
        if host:
            kw["host"] = host
        if not c.get("socket"):
            kw["port"] = int(c.get("port") or self.port)
        if (c.get("options") or {}).get("sslmode"):
            kw["sslmode"] = c["options"]["sslmode"]
        return psycopg.connect(**{k: v for k, v in kw.items() if v is not None})

    def begin(self, db, read_only, timeout):
        db.read_only = read_only  # psycopg opens the next transaction as BEGIN READ ONLY
        db.execute(f"SET LOCAL statement_timeout = {int(timeout) * 1000}")

    def run(self, db, sql):
        cur = db.cursor()
        cur.execute(sql.replace("%", "%%"), (), prepare=True)  # params + prepare => extended protocol, one statement only
        return cur

    def alive(self, db):
        return not db.closed

    def ident(self, name):
        return ".".join('"' + p.replace('"', '""') + '"' for p in self._split(name))

    def lit(self, s):
        return lit(s)

    @staticmethod
    def _split(name):
        schema, _, table = name.rpartition(".")
        return [schema or "public", table]

    def _reg(self, t):
        return f"{lit(self.ident(t))}::regclass"

    def version_sql(self):
        return "SELECT version()"

    def databases_sql(self):
        return "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY 1"

    def current_db_sql(self):
        return "SELECT current_database()"

    _NAME = "CASE WHEN {n}.nspname = 'public' THEN {c}.relname ELSE {n}.nspname || '.' || {c}.relname END"

    def tables_sql(self):
        return (f"SELECT {self._NAME.format(n='n', c='c')}, NULLIF(c.reltuples, -1)::bigint, "
                "CASE WHEN c.relkind IN ('v', 'm') THEN 'view' ELSE 'table' END "
                "FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f') "
                "AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg\\_%' ORDER BY 1")

    def columns_sql(self, t):
        return ("SELECT a.attname, format_type(a.atttypid, a.atttypmod), NOT a.attnotnull, "
                "CASE WHEN EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = a.attrelid AND i.indisprimary AND a.attnum = ANY (i.indkey)) "
                "THEN 'PRI' ELSE '' END, pg_get_expr(d.adbin, d.adrelid), col_description(a.attrelid, a.attnum) "
                "FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum "
                f"WHERE a.attrelid = {self._reg(t)} AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum")

    def indexes_sql(self, t):
        return ("SELECT ic.relname, i.indisunique, (SELECT string_agg(a.attname, ',' ORDER BY k.ord) "
                "FROM unnest(i.indkey::int2[]) WITH ORDINALITY k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum) "
                f"FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid WHERE i.indrelid = {self._reg(t)} ORDER BY 1")

    def _fk(self, side, t):
        src, dst = ("conrelid", "confrelid") if side == "out" else ("confrelid", "conrelid")
        skey, dkey = ("conkey", "confkey") if side == "out" else ("confkey", "conkey")
        other = self._NAME.format(n="tn", c="tc")
        return (f"SELECT {'a.attname, ' + other if side == 'out' else other + ', af.attname'}, {'af.attname' if side == 'out' else 'a.attname'} "
                f"FROM pg_constraint c CROSS JOIN LATERAL unnest(c.{skey}, c.{dkey}) AS k(s, d) "
                f"JOIN pg_attribute a ON a.attrelid = c.{src} AND a.attnum = k.s JOIN pg_attribute af ON af.attrelid = c.{dst} AND af.attnum = k.d "
                f"JOIN pg_class tc ON tc.oid = c.{dst} JOIN pg_namespace tn ON tn.oid = tc.relnamespace "
                f"WHERE c.contype = 'f' AND c.{src} = {self._reg(t)} ORDER BY 1, 2")

    def fks_sql(self, t):
        return self._fk("out", t)

    def refby_sql(self, t):
        return self._fk("in", t)


class SQLite:
    name, dialect, port, q = "sqlite", "sqlite", None, '"'

    def connect(self, c, password, timeout):
        import sqlite3
        path = os.path.expanduser(c.get("path") or c.get("database") or "")
        if not path:
            raise ValueError("SQLite connection needs a file path")
        if not os.path.exists(path):
            raise ValueError(f"SQLite file not found: {path}")
        mode = "ro" if c.get("readOnly", True) else "rw"
        conn_cls = type("Conn", (sqlite3.Connection,), {})  # plain sqlite3.Connection takes no attributes
        db = sqlite3.connect(f"file:{pathname2url(os.path.abspath(path))}?mode={mode}", uri=True, check_same_thread=False,
                             timeout=5, isolation_level=None, factory=conn_cls)
        db.rb_deadline = 0
        db.set_progress_handler(lambda: time.monotonic() > db.rb_deadline > 0, 20000)
        return db

    def begin(self, db, read_only, timeout):
        db.rb_deadline = time.monotonic() + timeout
        db.execute("BEGIN")

    def run(self, db, sql):
        return db.execute(sql)

    def alive(self, db):
        return True

    def ident(self, name):
        return '"' + name.replace('"', '""') + '"'

    def lit(self, s):
        return lit(s)

    def version_sql(self):
        return "SELECT 'SQLite ' || sqlite_version()"

    def databases_sql(self):
        return None  # one file = one database

    def current_db_sql(self):
        return "SELECT 'main'"

    def tables_sql(self):
        return "SELECT name, NULL, type FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name"

    def columns_sql(self, t):
        return (f"SELECT name, type, NOT \"notnull\", CASE WHEN pk THEN 'PRI' ELSE '' END, dflt_value, '' FROM pragma_table_info({lit(t)}) ORDER BY cid")

    def indexes_sql(self, t):
        return (f"SELECT il.name, il.\"unique\", (SELECT group_concat(name, ',') FROM pragma_index_info(il.name)) FROM pragma_index_list({lit(t)}) il ORDER BY 1")

    def fks_sql(self, t):
        # "to" is NULL when the FK targets the parent's primary key
        return (f"SELECT f.\"from\", f.\"table\", COALESCE(f.\"to\", (SELECT name FROM pragma_table_info(f.\"table\") WHERE pk = 1)) "
                f"FROM pragma_foreign_key_list({lit(t)}) f")

    def refby_sql(self, t):
        return ("SELECT m.name, f.\"from\", COALESCE(f.\"to\", (SELECT name FROM pragma_table_info(f.\"table\") WHERE pk = 1)) "
                f"FROM sqlite_master m, pragma_foreign_key_list(m.name) f WHERE m.type = 'table' AND lower(f.\"table\") = lower({lit(t)}) ORDER BY 1, 2")


DRIVERS = {d.name: d for d in (MySQL(), Postgres(), SQLite())}
ALIASES = {"mariadb": "mysql", "postgresql": "postgres", "pg": "postgres", "sqlite3": "sqlite"}


def get(name):
    d = DRIVERS.get(ALIASES.get(name, name))
    if not d:
        raise ValueError(f"Unknown driver '{name}'. Supported: {', '.join(DRIVERS)}")
    return d
