"""TOON (Token-Oriented Object Notation) encoder — compact, LLM-friendly output for the MCP server.

Implements the subset Rowbase needs (https://toonformat.dev): objects (`key: value`, 2-space indent), primitive arrays
(`key[N]: a,b`), tabular arrays of uniform objects (`key[N]{f1,f2}:` + one indented row per item), list arrays (`- item`)
and empty arrays (`key[0]:`). Quoting follows the spec cheatsheet. One deliberate convenience: database values arrive
as strings, so strings that are canonical decimals (`42`, `-3.5`, `7.00`) are emitted unquoted like numbers.
Shared conformance cases: tests/toon_vectors.json.
"""
import math
import re

_NUMERIC = re.compile(r"-?(0|[1-9]\d*)(\.\d+)?$")
_LOOKS_NUMERIC = re.compile(r"[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$")
_SPECIAL = set(':"\\[]{}')
_ESC = {"\\": "\\\\", '"': '\\"', "\n": "\\n", "\r": "\\r", "\t": "\\t"}
_KEY = re.compile(r"[A-Za-z_][\w.]*$")


def _quote(s):
    return '"' + "".join(_ESC.get(ch) or (f"\\u{ord(ch):04x}" if ord(ch) < 0x20 else ch) for ch in s) + '"'


def scalar(v, delim=","):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        if not math.isfinite(v):
            return "null"
        return repr(v).rstrip("0").rstrip(".") if "." in repr(v) and "e" not in repr(v) else repr(v)
    s = str(v)
    if _NUMERIC.match(s):
        return s  # database numeric rendered as text (see module docstring)
    if (not s or s != s.strip() or s in ("true", "false", "null") or _LOOKS_NUMERIC.match(s)
            or s.startswith(("-", "#")) or delim in s or any(ch in _SPECIAL or ord(ch) < 0x20 for ch in s)
            or s.startswith("﻿")):
        return _quote(s)
    return s


def key(k):
    k = str(k)
    return k if _KEY.match(k) else _quote(k)


def table(name, columns, rows, delim=","):
    """Tabular array: `name[N]{c1,c2}:` then one row per line (2-space indent). Rows are sequences."""
    head = f"{key(name) if name else ''}[{len(rows)}{'' if delim == ',' else delim}]" + "{" + delim.join(key(c) for c in columns) + "}:"
    return "\n".join([head] + ["  " + delim.join(scalar(v, delim) for v in r) for r in rows])


def encode(value, indent=0):
    """Encode dict/list/scalar. Lists of uniform flat dicts become tables."""
    pad = "  " * indent
    if isinstance(value, dict):
        lines = []
        for k, v in value.items():
            if isinstance(v, dict):
                lines.append(f"{pad}{key(k)}:" if v else f"{pad}{key(k)}: {{}}")
                if v:
                    lines.append(encode(v, indent + 1))
            elif isinstance(v, (list, tuple)):
                lines.append(_array(k, list(v), indent))
            else:
                lines.append(f"{pad}{key(k)}: {scalar(v)}")
        return "\n".join(lines)
    if isinstance(value, (list, tuple)):
        return _array(None, list(value), indent)
    return pad + scalar(value)


def _array(k, items, indent):
    pad, name = "  " * indent, key(k) if k is not None else ""
    if not items:
        return f"{pad}{name}[0]:"
    if all(not isinstance(i, (dict, list, tuple)) for i in items):
        return f"{pad}{name}[{len(items)}]: " + ",".join(scalar(i) for i in items)
    if all(isinstance(i, dict) for i in items):
        cols = list(items[0].keys())
        flat = all(not isinstance(x, (dict, list, tuple)) for i in items for x in i.values())
        if flat and all(list(i.keys()) == cols for i in items):
            return "\n".join(pad + line if line else line for line in table(k, cols, [[i[c] for c in cols] for i in items]).split("\n"))
    out = [f"{pad}{name}[{len(items)}]:"]
    for i in items:
        if isinstance(i, dict):
            first, *rest = encode(i, indent + 2).split("\n")
            out.append(f"{pad}  - {first.strip()}")
            out.extend(rest)
        else:
            out.append(f"{pad}  - {encode(i, 0)}")
    return "\n".join(out)
