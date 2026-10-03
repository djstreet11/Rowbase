import unittest

from rowbase.guard import QueryError, analyze, guard, scan

OK = {
    "mysql": ["SELECT 1", "select * from t;", "  (SELECT 1) UNION (SELECT 2)", "SHOW TABLES", "DESC t", "EXPLAIN SELECT 1",
              "WITH x AS (SELECT 1) SELECT * FROM x", "SELECT 'a;b'", "SELECT 1 -- ; drop\n", "SELECT 1 # ; drop",
              "SELECT 'it\\'s;'", "SELECT `we;ird` FROM t", "SELECT 'into outfile'",
              "SELECT 'a\\'; DELETE FROM t; SELECT '"],  # last one is a single literal in MySQL
    "postgres": ["SELECT 1", "SELECT $$;$$", "SELECT $tag$ ; $tag$", "SELECT 'it''s;'", "SELECT 1 /* ; */", "TABLE users",
                 "SELECT '50% off' LIKE '%off'", "SELECT data #> '{a}' FROM t", "SELECT \"we;ird\" FROM t", "EXPLAIN ANALYZE SELECT 1"],
    "sqlite": ["SELECT 1", "PRAGMA table_info('t')", "EXPLAIN QUERY PLAN SELECT 1", "VALUES (1)"],
}
BAD = {
    "mysql": ["DELETE FROM t", "select 1; delete from t", "SELECT * FROM t FOR UPDATE", "SELECT SLEEP(5)", "SELECT * INTO OUTFILE '/x' FROM t",
              "SELECT GET_LOCK('x', 1)", "SET @a = 1", "SELECT * FROM t LOCK IN SHARE MODE", ""],
    "postgres": ["UPDATE t SET a = 1", "SELECT pg_sleep(1)", "SELECT 1; COMMIT", "SELECT * INTO t2 FROM t", "SELECT * FROM t FOR SHARE",
                 "SELECT $$'$$; COMMIT; DELETE FROM t; SELECT '$$'", "SELECT 'a\\'; DELETE FROM t; SELECT 1", "SELECT set_config('a','b',false)",
                 "SELECT pg_read_file('/etc/passwd')", "SELECT 1 # 1; DELETE FROM t", "SET default_transaction_read_only = off", "COPY t TO '/tmp/x'"],
    "sqlite": ["INSERT INTO t VALUES (1)", "ATTACH 'x.db' AS x", "SELECT load_extension('x')", "SELECT 1; SELECT 2"],
}


class GuardTest(unittest.TestCase):
    def test_allowed(self):
        for d, qs in OK.items():
            for q in qs:
                with self.subTest(d=d, q=q):
                    guard(q, d)

    def test_refused(self):
        for d, qs in BAD.items():
            for q in qs:
                with self.subTest(d=d, q=q):
                    with self.assertRaises(QueryError):
                        guard(q, d)

    def test_scan_preserves_length(self):
        for d, qs in {**OK, **BAD}.items():
            for q in qs:
                self.assertEqual(len(scan(q, d)), len(q))

    def test_clean_drops_trailing_semicolon_and_comment(self):
        self.assertEqual(analyze("SELECT 1; -- bye\n", "mysql")[0], "SELECT 1")
        self.assertEqual(analyze("SELECT ';' ;;", "postgres")[0], "SELECT ';'")
        self.assertEqual(analyze("/* hi */ select 1", "mysql")[1], "SELECT")


if __name__ == "__main__":
    unittest.main()
