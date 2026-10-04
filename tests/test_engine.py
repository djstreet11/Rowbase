"""Engine/store/server tests against real databases.

SQLite always runs. Postgres/MySQL run when reachable; override with ROWBASE_TEST_PG / ROWBASE_TEST_MYSQL URLs
(default: local unix sockets, current user, database rowbase_test which is dropped and recreated).
"""
import json
import os
import sqlite3
import tempfile
import threading
import unittest
import urllib.request

TMP = tempfile.mkdtemp(prefix="rowbase-test-")
os.environ["ROWBASE_HOME"] = TMP
os.environ["ROWBASE_SECRETS"] = "file"

from rowbase import engine, server, store  # noqa: E402  (env must be set before import)
from rowbase.guard import QueryError  # noqa: E402

PG_URL = os.environ.get("ROWBASE_TEST_PG", "postgres://@/rowbase_test?socket=/tmp")
MY_URL = os.environ.get("ROWBASE_TEST_MYSQL", "mysql://@/rowbase_test?socket=/tmp/mysql.sock")

SCHEMA = {
    "sqlite": ["CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL)",
               "CREATE TABLE orders(id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users, total REAL, note TEXT)",
               "CREATE INDEX o_u ON orders(user_id)"],
    "postgres": ["CREATE TABLE users(id serial PRIMARY KEY, name text NOT NULL)",
                 "CREATE SCHEMA crm",
                 "CREATE TABLE crm.orders(id serial PRIMARY KEY, user_id int REFERENCES users(id), total numeric(10,2), note text)",
                 "CREATE INDEX o_u ON crm.orders(user_id)"],
    "mysql": ["CREATE TABLE users(id int AUTO_INCREMENT PRIMARY KEY, name varchar(50) NOT NULL)",
              "CREATE TABLE orders(id int AUTO_INCREMENT PRIMARY KEY, user_id int, total decimal(10,2), note text, "
              "INDEX o_u (user_id), FOREIGN KEY (user_id) REFERENCES users(id))"],
}
DATA = ["INSERT INTO users(name) VALUES ('ann'), ('bob')",
        "INSERT INTO {orders}(user_id, total, note) VALUES (1, 9.5, '50% off'), (1, 3, NULL), (2, 7, 'it''s')"]


def _user():
    import getpass
    return getpass.getuser()


def recreate(driver, url):
    fields, pw = store.parse_url(url)
    fields.setdefault("user", _user())
    if driver == "postgres":
        import psycopg
        admin = psycopg.connect(host=fields.get("socket") or fields.get("host"), port=fields.get("port") or 5432, user=fields["user"],
                                password=pw, dbname="postgres", autocommit=True, connect_timeout=3)
        admin.execute("DROP DATABASE IF EXISTS rowbase_test")
        admin.execute("CREATE DATABASE rowbase_test")
        admin.close()
    elif driver == "mysql":
        import pymysql
        kw = {"unix_socket": fields["socket"]} if fields.get("socket") else {"host": fields.get("host"), "port": fields.get("port") or 3306}
        admin = pymysql.connect(user=fields["user"], password=pw or "", connect_timeout=3, **kw)
        admin.cursor().execute("DROP DATABASE IF EXISTS rowbase_test")
        admin.cursor().execute("CREATE DATABASE rowbase_test")
        admin.close()
    return fields, pw


class Base:
    """Mixin; subclasses set driver and setUpClass creates 'rw' and 'ro' connections to a fresh fixture DB."""
    driver = orders = None

    @classmethod
    def make(cls, fields, pw):
        rw = store.upsert({**fields, "name": f"{cls.driver}-rw", "readOnly": False}, pw or "")
        for sql in SCHEMA[cls.driver] + DATA:
            engine.execute(rw["id"], sql.format(orders=cls.orders))
        cls.rw = rw["id"]
        cls.ro = store.upsert({**fields, "name": f"{cls.driver}-ro"}, pw or "")["id"]

    @classmethod
    def tearDownClass(cls):
        engine.reset_pool()

    def test_select_and_types(self):
        r = engine.execute(self.ro, f"SELECT id, total, note FROM {self.orders} ORDER BY id")
        self.assertEqual(r["cols"], ["id", "total", "note"])
        self.assertEqual(len(r["rows"]), 3)
        self.assertEqual(r["rows"][0][2], "50% off")
        self.assertIsNone(r["rows"][1][2])
        self.assertIsNone(r["affected"])

    def test_auto_limit_and_truncation(self):
        r = engine.execute(self.ro, f"SELECT * FROM {self.orders}", limit=2)
        self.assertEqual(len(r["rows"]), 2)
        self.assertTrue(r["truncated"])
        r = engine.execute(self.ro, f"SELECT * FROM {self.orders} LIMIT 1", limit=2)
        self.assertEqual(len(r["rows"]), 1)
        self.assertFalse(r["truncated"])

    def test_read_only_refuses_writes(self):
        for sql in ("DELETE FROM users", "SELECT 1; DELETE FROM users", "UPDATE users SET name = 'x'"):
            with self.assertRaises(QueryError):
                engine.execute(self.ro, sql)
        self.assertEqual(engine.execute(self.ro, "SELECT COUNT(*) FROM users")["rows"][0][0], 2)

    def test_driver_single_statement_even_when_trusted(self):
        with self.assertRaises(QueryError):
            engine.execute(self.ro, "SELECT 1; SELECT 2", trusted=True)

    def test_read_write_commits(self):
        r = engine.execute(self.rw, "UPDATE users SET name = 'bobby' WHERE id = 2")
        self.assertEqual(r["affected"], 1)
        self.assertEqual(engine.execute(self.ro, "SELECT name FROM users WHERE id = 2")["rows"][0][0], "bobby")
        engine.execute(self.rw, "UPDATE users SET name = 'bob' WHERE id = 2")

    def test_pool_reuse(self):
        for _ in range(3):
            engine.execute(self.ro, "SELECT 1", pooled=True)
        self.assertTrue(any(k[0] == self.ro and v for k, v in engine._pool.items()))

    def test_catalog(self):
        names = {t["name"]: t for t in engine.tables(self.ro)}
        self.assertIn("users", names)
        self.assertIn(self.orders, names)
        info = engine.table_info(self.ro, self.orders)
        cols = {c["name"]: c for c in info["columns"]}
        self.assertEqual(cols["id"]["key"], "PRI")
        self.assertEqual(cols["user_id"]["fk"], {"table": "users", "column": "id"})
        self.assertTrue(any(i["cols"] == "user_id" for i in info["indexes"]))
        refby = engine.table_info(self.ro, "users")["referencedBy"]
        self.assertEqual(refby, [{"table": self.orders, "column": "user_id", "refColumn": "id"}])
        with self.assertRaises(QueryError):
            engine.table_info(self.ro, "nope")

    def test_ping(self):
        self.assertTrue(engine.ping(self.ro)["version"])


class SQLiteTest(Base, unittest.TestCase):
    driver, orders = "sqlite", "orders"

    @classmethod
    def setUpClass(cls):
        path = os.path.join(TMP, "t.db")
        sqlite3.connect(path).close()
        cls.make({"driver": "sqlite", "path": path}, None)

    def test_ro_file_mode(self):
        with self.assertRaises(QueryError):  # even trusted writes fail: file opened with mode=ro
            engine.execute(self.ro, "DELETE FROM users", trusted=True)


class PostgresTest(Base, unittest.TestCase):
    driver, orders = "postgres", "crm.orders"

    @classmethod
    def setUpClass(cls):
        try:
            cls.make(*recreate("postgres", PG_URL))
        except Exception as e:
            raise unittest.SkipTest(f"Postgres not available: {e}")

    def test_ro_transaction_blocks_cte_write(self):
        with self.assertRaises(QueryError):
            engine.execute(self.ro, "WITH x AS (DELETE FROM users RETURNING *) SELECT * FROM x")

    def test_timeout(self):
        with self.assertRaises(QueryError):
            engine.execute(self.ro, "SELECT count(*) FROM generate_series(1, 100000000) a", timeout=1, trusted=True)


class MySQLTest(Base, unittest.TestCase):
    driver, orders = "mysql", "orders"

    @classmethod
    def setUpClass(cls):
        try:
            cls.make(*recreate("mysql", MY_URL))
        except Exception as e:
            raise unittest.SkipTest(f"MySQL not available: {e}")


class StoreTest(unittest.TestCase):
    def test_parse_url(self):
        f, pw = store.parse_url("postgresql://u%40x:p%3Ass@db.local:6432/app?sslmode=require")
        self.assertEqual(f, {"driver": "postgres", "host": "db.local", "port": 6432, "user": "u@x", "database": "app",
                             "options": {"sslmode": "require"}})
        self.assertEqual(pw, "p:ss")
        self.assertEqual(store.parse_url("sqlite:////abs/x.db")[0], {"driver": "sqlite", "path": "/abs/x.db"})
        self.assertEqual(store.parse_url("mariadb://u@h/db")[1], None)

    def test_crud_and_secrets(self):
        c = store.upsert({"name": "Tmp", "driver": "pg", "host": "h"}, "s3cret")
        self.assertTrue(c["readOnly"])
        self.assertEqual(c["driver"], "postgres")
        with open(store.CONNECTIONS) as f:
            self.assertNotIn("s3cret", f.read())
        self.assertEqual(store.password(store.get("tmp")), "s3cret")
        self.assertEqual(oct(os.stat(store.SECRETS).st_mode & 0o777), "0o600")
        store.upsert({**c, "host": "h2"})  # password None keeps it
        self.assertEqual(store.password(store.get(c["id"])), "s3cret")
        with self.assertRaises(QueryError):
            store.upsert({"name": "tmp", "driver": "mysql"})  # duplicate name
        store.delete("Tmp")
        with open(store.SECRETS) as f:
            self.assertNotIn(c["id"], json.load(f))
        with self.assertRaises(QueryError):
            store.get("Tmp")


class ServerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = os.path.join(TMP, "s.db")
        db = sqlite3.connect(path)
        db.execute("CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)")
        db.execute("INSERT INTO t(v) VALUES ('a')")
        db.commit()
        cls.cid = store.upsert({"name": "srv", "driver": "sqlite", "path": path})["id"]
        cls.srv = server.make_server(0)
        cls.url = f"http://127.0.0.1:{cls.srv.server_address[1]}"
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()

    def call(self, path, body=None, headers=None):
        h = {"X-Rowbase": "1", **(headers or {})}
        req = urllib.request.Request(self.url + path, data=json.dumps(body).encode() if body is not None else None, headers=h)
        try:
            with urllib.request.urlopen(req) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def test_flow(self):
        self.assertIn("srv", [c["name"] for c in self.call("/api/conns")[1]])
        self.assertEqual(self.call(f"/api/tables?conn={self.cid}")[1][0]["name"], "t")
        code, r = self.call("/api/query", {"conn": self.cid, "sql": "SELECT * FROM t"})
        self.assertEqual((code, r["rows"]), (200, [[1, "a"]]))
        code, r = self.call("/api/query", {"conn": self.cid, "sql": "DELETE FROM t"})
        self.assertEqual(code, 400)
        hist = self.call(f"/api/history?conn={self.cid}")[1]
        self.assertEqual(hist[0]["connName"], "srv")
        self.assertIn("error", hist[0])

    def test_security(self):
        self.assertEqual(self.call("/api/conns", headers={"X-Rowbase": "0"})[0], 403)
        self.assertEqual(self.call("/api/conns", headers={"Host": "evil.example"})[0], 403)

    def test_conn_save_test_delete(self):
        code, c = self.call("/api/conns/save", {"conn": {"name": "x", "driver": "sqlite", "path": os.path.join(TMP, "s.db")}, "password": None})
        self.assertEqual(code, 200)
        self.assertIn("SQLite", self.call("/api/conns/test", {"id": c["id"]})[1]["version"])
        self.assertEqual(self.call("/api/conns/test", {"conn": {"name": "y", "driver": "sqlite", "path": "/nope.db"}})[0], 400)
        self.assertEqual(self.call("/api/conns/delete", {"id": c["id"]})[0], 200)


if __name__ == "__main__":
    unittest.main()


class SSHTunnelTest(unittest.TestCase):
    """Tunnel plumbing end-to-end with tests/fixtures/fake_ssh.py standing in for ssh (no sshd needed)."""

    @classmethod
    def setUpClass(cls):
        cls.log = os.path.join(TMP, "ssh.log")
        os.environ["ROWBASE_SSH"] = os.path.join(os.path.dirname(__file__), "fixtures", "fake_ssh.py")
        os.environ["FAKE_SSH_LOG"] = cls.log
        try:
            import psycopg
            psycopg.connect(host="127.0.0.1", dbname="postgres", connect_timeout=2).close()
        except Exception as e:
            raise unittest.SkipTest(f"Postgres TCP not available: {e}")

    @classmethod
    def tearDownClass(cls):
        from rowbase import tunnel
        tunnel.close_all()
        os.environ.pop("ROWBASE_SSH", None)

    def test_query_through_tunnel(self):
        c = store.upsert({"name": "via-ssh", "driver": "postgres", "host": "127.0.0.1", "port": 5432, "database": "postgres",
                          "ssh": {"host": "bastion.example", "user": "deploy", "port": "2222", "identityFile": "~/.ssh/k"}})
        self.assertEqual(c["ssh"], {"host": "bastion.example", "user": "deploy", "port": 2222, "identityFile": "~/.ssh/k"})
        r = engine.execute(c["id"], "SELECT inet_server_port()")
        self.assertEqual(r["rows"][0][0], 5432)
        with open(self.log) as f:
            argv = f.read()
        self.assertIn("-p 2222", argv)
        self.assertIn("deploy@bastion.example", argv)
        self.assertIn(":127.0.0.1:5432", argv)
        self.assertIn(os.path.expanduser("~/.ssh/k"), argv)
        self.assertIn("BatchMode=yes", argv)

    def test_tunnel_failure_is_reported(self):
        c = store.upsert({"name": "bad-ssh", "driver": "postgres", "host": "db", "ssh": {"host": "fail.example"}})
        with self.assertRaises(QueryError) as e:
            engine.execute(c["id"], "SELECT 1")
        self.assertIn("Could not resolve hostname", str(e.exception))

    def test_url_and_validation(self):
        f, _ = store.parse_url("mysql://u@db.internal/app?ssh=deploy@bastion:2222")
        self.assertEqual(f["ssh"], {"host": "bastion", "port": 2222, "user": "deploy"})
        with self.assertRaises(QueryError):
            store.normalize({"name": "x", "driver": "mysql", "ssh": {"user": "a"}})
        self.assertNotIn("ssh", store.normalize({"name": "x", "driver": "sqlite", "path": "/a", "ssh": {"host": "h"}}))
