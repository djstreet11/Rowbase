"""Connection store shared by the CLI, the web UI and (later) the native app.

~/.config/rowbase/connections.json holds connection metadata only; passwords live in the OS keychain
(service "rowbase", account = connection id) via `keyring`, or in secrets.json (0600) when no keychain
is available or ROWBASE_SECRETS=file. ROWBASE_PASSWORD_<NAME> env vars override both (CI/agents).
"""
import json
import os
import re
import uuid
from urllib.parse import parse_qs, unquote, urlparse

from . import drivers
from .guard import QueryError

HOME = os.path.expanduser(os.environ.get("ROWBASE_HOME", "~/.config/rowbase"))
CONNECTIONS = os.path.join(HOME, "connections.json")
SECRETS = os.path.join(HOME, "secrets.json")
HISTORY = os.path.join(HOME, "history.jsonl")
SERVICE = "rowbase"
FIELDS = ("id", "name", "driver", "host", "port", "socket", "database", "path", "user", "readOnly", "env", "color", "group", "options")
ENVS = ("local", "dev", "stage", "prod")


def _ensure_home():
    os.makedirs(HOME, mode=0o700, exist_ok=True)


def load():
    if not os.path.exists(CONNECTIONS):
        return []
    with open(CONNECTIONS, encoding="utf-8") as f:
        return json.load(f).get("connections", [])


def _write(conns):
    _ensure_home()
    tmp = CONNECTIONS + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"version": 1, "connections": conns}, f, ensure_ascii=False, indent=2)
    os.replace(tmp, CONNECTIONS)


def get(ref):
    """Find by id or (case-insensitive) name; with ref=None return the only/ROWBASE_CONN connection."""
    conns = load()
    ref = ref or os.environ.get("ROWBASE_CONN")
    if not ref:
        if len(conns) == 1:
            return conns[0]
        raise QueryError("Choose a connection with -c NAME (see `rowbase conns`)." if conns else
                         "No connections yet. Add one: rowbase add NAME URL")
    for c in conns:
        if c["id"] == ref:
            return c
    for c in conns:
        if c["name"].lower() == str(ref).lower():
            return c
    raise QueryError(f"Unknown connection '{ref}'. Known: {', '.join(c['name'] for c in conns) or '-'}")


def normalize(data):
    c = {k: data[k] for k in FIELDS if data.get(k) not in (None, "")}
    if not c.get("name"):
        raise QueryError("Connection name is required.")
    c["driver"] = drivers.get(c.get("driver") or "mysql").name
    if c.get("port") is not None:
        c["port"] = int(c["port"])
    c["readOnly"] = bool(data.get("readOnly", True))
    if c.get("env") and c["env"] not in ENVS:
        raise QueryError(f"env must be one of {', '.join(ENVS)}")
    if c["driver"] == "sqlite" and not (c.get("path") or c.get("database")):
        raise QueryError("SQLite connection needs a file path.")
    return c


def upsert(data, password=None):
    """Create or update (by id). password=None keeps the stored one, '' removes it."""
    c = normalize(data)
    conns = load()
    c["id"] = data.get("id") or str(uuid.uuid4())
    if any(x["name"].lower() == c["name"].lower() and x["id"] != c["id"] for x in conns):
        raise QueryError(f"A connection named '{c['name']}' already exists.")
    i = next((i for i, x in enumerate(conns) if x["id"] == c["id"]), None)
    if i is None:
        conns.append(c)
    else:
        conns[i] = c
    _write(conns)
    if password is not None:
        set_password(c["id"], password)
    return c


def delete(ref):
    c = get(ref)
    _write([x for x in load() if x["id"] != c["id"]])
    set_password(c["id"], "")
    return c


# ---------------------------------------------------------------- secrets

def _keyring():
    if os.environ.get("ROWBASE_SECRETS") == "file":
        return None
    try:
        import keyring
        from keyring.backends import fail
        kr = keyring.get_keyring()
        return None if isinstance(kr, fail.Keyring) else keyring
    except Exception:
        return None


def _file_secrets():
    if not os.path.exists(SECRETS):
        return {}
    with open(SECRETS, encoding="utf-8") as f:
        return json.load(f)


def _write_file_secrets(data):
    _ensure_home()
    fd = os.open(SECRETS, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f)


def env_key(name):
    return "ROWBASE_PASSWORD_" + re.sub(r"\W", "_", name).upper()


def password(c):
    if env_key(c["name"]) in os.environ:
        return os.environ[env_key(c["name"])]
    kr = _keyring()
    if kr:
        try:
            pw = kr.get_password(SERVICE, c["id"])
            if pw is not None:
                return pw
        except Exception:
            pass
    return _file_secrets().get(c["id"])


def set_password(conn_id, pw):
    kr = _keyring()
    if kr:
        try:
            if pw:
                kr.set_password(SERVICE, conn_id, pw)
            else:
                try:
                    kr.delete_password(SERVICE, conn_id)
                except Exception:
                    pass
            return
        except Exception:
            pass
    data = _file_secrets()
    if pw:
        data[conn_id] = pw
    else:
        data.pop(conn_id, None)
    if data or os.path.exists(SECRETS):
        _write_file_secrets(data)


# ---------------------------------------------------------------- URLs

def parse_url(url):
    """mysql://user:pw@host:3306/db, postgres://…?sslmode=require, sqlite:///abs/path.db -> (fields, password|None)."""
    u = urlparse(url)
    driver = drivers.get(u.scheme).name
    if driver == "sqlite":
        path = unquote(u.netloc + u.path)
        return {"driver": driver, "path": re.sub(r"^/{2,}", "/", path)}, None
    c = {"driver": driver, "host": u.hostname, "port": u.port, "user": unquote(u.username) if u.username else None,
         "database": unquote(u.path.lstrip("/")) or None}
    qs = {k: v[0] for k, v in parse_qs(u.query).items()}
    if "socket" in qs:
        c["socket"] = qs.pop("socket")
    if qs:
        c["options"] = qs
    return {k: v for k, v in c.items() if v is not None}, (unquote(u.password) if u.password is not None else None)


def public(c):
    """Connection as shown to clients (never includes secrets)."""
    return {k: c[k] for k in FIELDS if k in c}
