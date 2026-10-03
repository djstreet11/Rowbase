---
name: add-driver
description: Add support for a new database engine (e.g. ClickHouse, MS SQL) to Rowbase's Python track. Use when asked to support another DB type.
---

# add-driver — new database engine in Track A

1. **Driver class** in `rowbase/drivers.py` (copy the closest existing one). Required attributes/methods:
   `name, dialect, port, q` · `connect(c, password, timeout)` · `begin(db, read_only, timeout)` (open RO tx + set timeout) ·
   `run(db, sql)` → cursor (**must execute exactly one statement**; find the driver option that guarantees it) ·
   `alive(db)` · `ident(name)` · `lit(s)` · `version_sql, tables_sql, columns_sql(t), indexes_sql(t), fks_sql(t), refby_sql(t)`
   with the column order used by `engine.tables/table_info`. Register in `DRIVERS` (+ `ALIASES` for URL schemes).
2. **Guard** in `rowbase/guard.py`: `ALLOWED[dialect]`, `FORBIDDEN[dialect]`; extend `scan()` if the dialect has special
   comments/quotes (like PG `$$`, MySQL `#`/backslashes).
3. **Store**: `parse_url` usually works via `drivers.get(scheme)`; add query options if needed. Add the driver to `pyproject.toml` deps.
4. **Tests**: vectors in `tests/test_guard.py` (OK + BAD incl. comment/literal tricks); a `Base` subclass in
   `tests/test_engine.py` with `SCHEMA[...]`, `recreate()` branch, skip if server unavailable.
5. **UI**: driver option in the connection manager, dialect quote char and EXPLAIN variants in `static/app.js`.
6. Update SPEC §2/§3.2, run `learn`.
