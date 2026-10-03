import json
import os
import unittest

from rowbase.guard import QueryError, analyze, guard, scan

# Shared with the native app's Swift tests — add new cases to the JSON, not here.
with open(os.path.join(os.path.dirname(__file__), "guard_vectors.json"), encoding="utf-8") as f:
    VEC = json.load(f)


class GuardTest(unittest.TestCase):
    def test_allowed(self):
        for d, qs in VEC["ok"].items():
            for q in qs:
                with self.subTest(d=d, q=q):
                    guard(q, d)

    def test_refused(self):
        for d, qs in VEC["bad"].items():
            for q in qs:
                with self.subTest(d=d, q=q):
                    with self.assertRaises(QueryError):
                        guard(q, d)

    def test_scan_preserves_length(self):
        for group in (VEC["ok"], VEC["bad"]):
            for d, qs in group.items():
                for q in qs:
                    self.assertEqual(len(scan(q, d)), len(q))

    def test_clean(self):
        for v in VEC["clean"]:
            with self.subTest(v=v):
                clean, first, _ = analyze(v["sql"], v["dialect"])
                self.assertEqual((clean, first), (v["clean"], v["first"]))


if __name__ == "__main__":
    unittest.main()
