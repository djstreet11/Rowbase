"""Implicit UUID references: shared heuristics vectors + resolution against real databases."""
import json
import os
import sqlite3
import unittest

from tests.test_engine import MY_URL, PG_URL, TMP, recreate  # first: points ROWBASE_HOME / secrets at a temp dir

from rowbase import engine, refs, store  # noqa: E402
from rowbase.guard import QueryError  # noqa: E402

V = json.load(open(os.path.join(os.path.dirname(__file__), "ref_vectors.json")))
ADDR = "7e6056b9-9582-11f1-a74c-005056bd6036"


class Vectors(unittest.TestCase):
    def test_vectors(self):
        for v, ok in V["uuid"]:
            self.assertEqual(refs.is_uuid(v), ok, v)
        for s, w in V["words"]:
            self.assertEqual(refs.words(s), w, s)
        for c in V["hint"]:
            self.assertEqual(refs.hint_column(c["column"], c["columns"]), c["expect"], c["column"])
        for c in V["candidates"]:
            self.assertEqual(refs.candidates(c["column"], c["hint"], c["tables"]), c["expect"], c["column"])


class Resolve(unittest.TestCase):
    DDL = {
        "sqlite": ["CREATE TABLE CatalogAddresses(Ref TEXT PRIMARY KEY, Description TEXT, Code TEXT)",
                   "CREATE TABLE Doc(Ref TEXT PRIMARY KEY, SenderAddress TEXT)", "CREATE TABLE Plain(id INTEGER PRIMARY KEY)",
                   f"INSERT INTO CatalogAddresses VALUES ('{ADDR}', '', 'K-7')"],
        "postgres": ['CREATE SCHEMA refs', 'CREATE TABLE refs."CatalogAddresses"("Ref" uuid PRIMARY KEY, "Description" text, "Code" int)',
                     "CREATE TABLE refs.plain(id serial PRIMARY KEY)",
                     f"INSERT INTO refs.\"CatalogAddresses\" VALUES ('{ADDR}', 'Kyiv, warehouse 4', 7)"],
        "mysql": ["CREATE TABLE CatalogAddresses(Ref char(36) PRIMARY KEY, Description varchar(100), Code varchar(9))",
                  "CREATE TABLE CatalogBins(Ref binary(16) PRIMARY KEY, Name varchar(20))",
                  "INSERT INTO CatalogBins VALUES (UNHEX('a0eebc999c0b4ef8bb6d6bb9bd380a11'), 'bin')",
                  "CREATE TABLE Plain(id int PRIMARY KEY)", f"INSERT INTO CatalogAddresses VALUES ('{ADDR}', '', 'K-7')"],
    }

    def run_on(self, driver):
        if driver == "sqlite":
            path = os.path.join(TMP, "refs.db")
            if os.path.exists(path):
                os.remove(path)
            sqlite3.connect(path).close()
            fields, pw = {"driver": "sqlite", "path": path}, None
        else:
            try:
                fields, pw = recreate(driver, PG_URL if driver == "postgres" else MY_URL)
            except Exception as e:
                self.skipTest(f"{driver} not available: {e}")
        rw = store.upsert({**fields, "name": f"refs-{driver}-rw", "readOnly": False}, pw or "")["id"]
        for sql in self.DDL[driver]:
            engine.execute(rw, sql)
        ro = store.upsert({**fields, "name": f"refs-{driver}-ro"}, pw or "")["id"]
        refs.clear()
        table = "refs.CatalogAddresses" if driver == "postgres" else "CatalogAddresses"
        allt = refs.ref_tables(ro)
        t = next(x for x in allt if x["name"] == table)
        self.assertEqual(t["labels"], ["Description", "Code"])
        self.assertFalse(any(x["name"].lower().endswith("plain") for x in allt))
        r = refs.resolve(ro, ADDR.upper(), table="Doc", column="SenderAddress")
        self.assertEqual(r["matches"], [{"table": table, "pk": "Ref", "label": "Kyiv, warehouse 4" if driver == "postgres" else "K-7"}])
        self.assertEqual(r["how"], "name")
        self.assertEqual(refs.resolve(ro, ADDR, table="Doc", column="SenderAddress")["how"], "learned")
        self.assertEqual(refs.resolve(ro, "00000000-0000-0000-0000-000000000001")["matches"], [])
        with self.assertRaises(QueryError):
            refs.resolve(ro, "x' OR 1=1 --")
        if driver == "mysql":
            self.assertEqual(refs.resolve(ro, "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11")["matches"],
                             [{"table": "CatalogBins", "pk": "Ref", "label": "bin"}])
        engine.reset_pool()

    def test_sqlite(self):
        self.run_on("sqlite")

    def test_postgres(self):
        self.run_on("postgres")

    def test_mysql(self):
        self.run_on("mysql")
