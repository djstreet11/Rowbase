import json
import os
import unittest

from rowbase import toon

with open(os.path.join(os.path.dirname(__file__), "toon_vectors.json"), encoding="utf-8") as f:
    VEC = json.load(f)  # shared with the native port


class ToonTest(unittest.TestCase):
    def test_vectors(self):
        for c in VEC["cases"]:
            got = toon.table(c["name"], c["columns"], c["rows"]) if c["kind"] == "table" else toon.encode(c["value"])
            self.assertEqual(got, c["expected"], c["name"])

    def test_scalars(self):
        for v, want in [(None, "null"), (True, "true"), (3, "3"), (2.0, "2"), (float("nan"), "null"), ("ok", "ok"),
                        ("05", '"05"'), ("-1", "-1"), ("+1", '"+1"'), ("a,b", '"a,b"'), ("tab\there", '"tab\\there"'), ("é 世界", "é 世界")]:
            self.assertEqual(toon.scalar(v), want, repr(v))


if __name__ == "__main__":
    unittest.main()
