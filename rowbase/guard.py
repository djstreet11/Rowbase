"""Read-only SQL guard: one statement, allowed leading keyword, no locking/sleeping/file functions.

Defense in depth only — the real protection is the driver (single statement per call) plus a READ ONLY
transaction/session that is always rolled back. The scanner is dialect-aware so comments and literals
cannot hide a ';' or a forbidden call.
"""
import re


class QueryError(Exception):
    pass


ALLOWED = {
    "mysql": {"SELECT", "SHOW", "DESC", "DESCRIBE", "EXPLAIN", "WITH", "VALUES", "TABLE"},
    "postgres": {"SELECT", "SHOW", "EXPLAIN", "WITH", "VALUES", "TABLE"},
    "sqlite": {"SELECT", "EXPLAIN", "WITH", "VALUES", "PRAGMA"},
}
FORBIDDEN = {
    "mysql": [r"\bINTO\s+(OUT|DUMP)FILE\b", r"\bFOR\s+UPDATE\b", r"\bLOCK\s+IN\s+SHARE\s+MODE\b", r"\bFOR\s+SHARE\b",
              r"\bGET_LOCK\s*\(", r"\bSLEEP\s*\(", r"\bBENCHMARK\s*\(", r"\bLOAD_FILE\s*\("],
    "postgres": [r"\bINTO\b", r"\bFOR\s+(NO\s+KEY\s+)?(UPDATE|SHARE)\b", r"\bFOR\s+KEY\s+SHARE\b", r"\bPG_SLEEP\w*\s*\(",
                 r"\bPG_ADVISORY\w*\s*\(", r"\bDBLINK\w*\s*\(", r"\bLO_\w+\s*\(", r"\bPG_(READ|WRITE|STAT)_\w*FILE\s*\(",
                 r"\bPG_LS_\w+\s*\(", r"\bSET_CONFIG\s*\(", r"\bPG_(CANCEL|TERMINATE)_BACKEND\s*\(", r"\bPG_RELOAD_CONF\s*\("],
    "sqlite": [r"\bLOAD_EXTENSION\s*\(", r"\bWRITEFILE\s*\(", r"\bREADFILE\s*\(", r"\bEDIT\s*\("],
}
_DOLLAR = re.compile(r"\$([A-Za-z_]\w*)?\$")


def scan(sql, dialect):
    """Same-length copy of sql with comments and literal/quoted-identifier contents blanked (positions map 1:1)."""
    out, i, n = [], 0, len(sql)
    while i < n:
        c, two = sql[i], sql[i:i + 2]
        if two == "--" or (c == "#" and dialect == "mysql"):
            j = sql.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
            continue
        if two == "/*":
            j = sql.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append(" " * (j - i))
            i = j
            continue
        if c in "'\"`":
            # backslash escapes: MySQL always, Postgres only in E'...' strings
            bs = dialect == "mysql" or (dialect == "postgres" and c == "'" and i and sql[i - 1] in "eE"
                                         and (i < 2 or not (sql[i - 2].isalnum() or sql[i - 2] == "_")))
            j = i + 1
            while j < n:
                if bs and sql[j] == "\\":
                    j += 2
                    continue
                if sql[j] == c:
                    if sql[j + 1:j + 2] == c:
                        j += 2
                        continue
                    break
                j += 1
            j = min(j + 1, n)
            out.append("'" + " " * max(j - i - 2, 0) + ("'" if j - i > 1 else ""))
            i = j
            continue
        if c == "$" and dialect == "postgres" and not (i and (sql[i - 1].isalnum() or sql[i - 1] == "_")):
            m = _DOLLAR.match(sql, i)
            if m:
                j = sql.find(m.group(0), m.end())
                j = n if j < 0 else j + len(m.group(0))
                out.append("'" + " " * max(j - i - 2, 0) + "'")
                i = j
                continue
        out.append(c)
        i += 1
    return "".join(out)


def analyze(sql, dialect):
    """(clean, first_word, bare): clean = sql without trailing ';', bare = scanned form used for checks."""
    clean = sql.strip()
    bare = scan(clean, dialect).rstrip()
    while bare.endswith(";"):
        bare = bare[:-1].rstrip()
    clean = clean[:len(bare)]  # drops trailing ';' and trailing comments
    m = re.match(r"[\s(]*([A-Za-z]+)", bare)
    return clean, (m.group(1).upper() if m else ""), bare


def guard(sql, dialect="mysql"):
    clean, first, bare = analyze(sql, dialect)
    if not bare:
        raise QueryError("Empty query.")
    if ";" in bare:
        raise QueryError("Refused: only one statement per call.")
    allowed = ALLOWED[dialect]
    if first not in allowed:
        raise QueryError(f"Refused: read-only connection, '{first}' is not allowed (allowed: {', '.join(sorted(allowed))}).")
    for p in FORBIDDEN[dialect]:
        if re.search(p, bare, flags=re.I):
            raise QueryError(f"Refused: pattern {p} is not allowed on a read-only connection.")
    return clean, first, bare
