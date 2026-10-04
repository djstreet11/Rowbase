"""Result export formats — byte-identical with the native app (vectors: tests/export_vectors.json).

csv (RFC 4180, CRLF, NULL = empty), tsv (tabs/newlines in values -> space), json (array of objects),
md (GitHub table, | escaped, newlines -> space), sql (one INSERT per row, values as quoted literals, NULL).
"""
import json

FORMATS = {"csv": "text/csv", "tsv": "text/tab-separated-values", "json": "application/json", "md": "text/markdown",
           "sql": "application/sql"}


def _s(v):
    return "" if v is None else str(v)


def render(cols, rows, fmt, table=None, drv=None):
    if fmt == "csv":
        def cell(v):
            s = _s(v)
            return '"' + s.replace('"', '""') + '"' if any(ch in s for ch in ',"\r\n') else s
        return "".join(",".join(cell(v) for v in r) + "\r\n" for r in [cols, *rows])
    if fmt == "tsv":
        clean = lambda v: _s(v).replace("\t", " ").replace("\r", " ").replace("\n", " ")
        return "\n".join("\t".join(clean(v) for v in r) for r in [cols, *rows]) + "\n"
    if fmt == "json":
        return json.dumps([dict(zip(cols, r)) for r in rows], ensure_ascii=False, indent=2) + "\n"
    if fmt == "md":
        clean = lambda v: "NULL" if v is None else str(v).replace("|", "\\|").replace("\r", " ").replace("\n", " ")
        out = ["| " + " | ".join(clean(c) for c in cols) + " |", "|" + "|".join("---" for _ in cols) + "|"]
        return "\n".join(out + ["| " + " | ".join(clean(v) for v in r) + " |" for r in rows]) + "\n"
    if fmt == "sql":
        if not table or not drv:
            raise ValueError("SQL export needs a table name")
        col = drv.ident if drv.name != "postgres" else (lambda n: '"' + n.replace('"', '""') + '"')
        head = f"INSERT INTO {drv.ident(table)} (" + ", ".join(col(c) for c in cols) + ") VALUES ("
        return "".join(head + ", ".join("NULL" if v is None else drv.lit(str(v)) for v in r) + ");\n" for r in rows)
    raise ValueError(f"Unknown export format '{fmt}' (use {', '.join(FORMATS)})")
