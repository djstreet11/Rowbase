import json
import os
import unittest

from rowbase import drivers, query

with open(os.path.join(os.path.dirname(__file__), "query_vectors.json"), encoding="utf-8") as f:
    VEC = json.load(f)  # shared with the Swift suite — change the SQL deliberately and regenerate both


class QueryVectorsTest(unittest.TestCase):
    def test_filters(self):
        for v in VEC["filters"]:
            self.assertEqual(query.filter_where(drivers.get(v["dialect"]), v["group"], v["types"]), v["expected"], v)

    def test_queries(self):
        for v in VEC["queries"]:
            self.assertEqual(query.select_sql(drivers.get(v["dialect"]), v["spec"], v["types"]), v["expected"], v)

    def test_values(self):
        for v in VEC["values"]:
            self.assertEqual(query.values_sql(drivers.get(v["dialect"]), v["table"], v["col"], v["where"], v["search"], v["type"], v["limit"]),
                             v["expected"], v)

    def test_errors(self):
        for v in VEC["errors"]:
            drv = drivers.get(v["dialect"])
            with self.assertRaises(ValueError, msg=v):
                query.filter_where(drv, v["group"]) if v["kind"] == "filter" else query.select_sql(drv, v["spec"])


if __name__ == "__main__":
    unittest.main()
