import json
import os
import unittest

from rowbase import drivers, export

with open(os.path.join(os.path.dirname(__file__), "export_vectors.json"), encoding="utf-8") as f:
    VEC = json.load(f)  # shared with the Swift suite — change formats deliberately and regenerate both


class ExportTest(unittest.TestCase):
    def test_formats(self):
        for fmt in ("csv", "tsv", "json", "md"):
            self.assertEqual(export.render(VEC["cols"], VEC["rows"], fmt), VEC["expected"][fmt], fmt)
        for d, table in (("mysql", "orders"), ("postgres", "crm.orders"), ("sqlite", "orders")):
            self.assertEqual(export.render(VEC["cols"], VEC["rows"], "sql", table, drivers.get(d)), VEC["expected"]["sql_" + d], d)

    def test_errors(self):
        with self.assertRaises(ValueError):
            export.render(["a"], [], "xml")
        with self.assertRaises(ValueError):
            export.render(["a"], [], "sql")


if __name__ == "__main__":
    unittest.main()
