# Contributing

Thanks for helping! Please:
1. Open an issue first for larger changes.
2. Keep the read-only guarantees intact: any change to the SQL guard needs cases in `tests/guard_vectors.json`
   (shared by the Python and Swift test suites); shared formats are pinned by `tests/export_vectors.json`
   and `tests/toon_vectors.json`.
3. Run the tests: `python -m unittest discover -s tests -t .` and `cd native && swift test`
   (PostgreSQL/MySQL tests run when a local server is available and skip otherwise).
4. By contributing you agree your contribution is licensed under Apache-2.0.
