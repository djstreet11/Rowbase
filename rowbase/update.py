"""Update check + self-update for one-file binaries (docs/UPDATES.md). Stdlib only.

Source of truth: the latest GitHub release. One anonymous GET, cached for a day in <config>/update.json; no telemetry.
Opt-out: ROWBASE_NO_UPDATE_CHECK=1 or settings.json {"updates": {"check": false}} (explicit `rowbase update` still works).
"""
import hashlib
import json
import os
import platform
import re
import subprocess
import sys
import time
import urllib.request

from . import __version__, store

REPO = "djstreet11/Rowbase"
API = os.environ.get("ROWBASE_UPDATE_URL", f"https://api.github.com/repos/{REPO}/releases/latest")
TTL = 24 * 3600


def vtuple(v):
    return tuple(int(x) for x in re.findall(r"\d+", str(v))[:3])


def disabled():
    return bool(os.environ.get("ROWBASE_NO_UPDATE_CHECK")) or (store.settings().get("updates") or {}).get("check") is False


def asset_name():
    """Same naming as packaging/build.py."""
    os_ = {"darwin": "macos", "win32": "windows"}.get(sys.platform, "linux")
    arch = {"x86_64": "x64", "amd64": "x64", "arm64": "arm64", "aarch64": "arm64"}.get(platform.machine().lower(), platform.machine())
    return f"rowbase-{os_}-{arch}" + (".exe" if os_ == "windows" else "")


def executable():
    """Path of the running one-file binary, or None when running from Python (pip/pipx/uv/source)."""
    if "__compiled__" not in globals():
        return None
    argv0 = getattr(globals()["__compiled__"], "original_argv0", None) or sys.argv[0]
    return os.path.realpath(argv0)


def install_kind():
    exe = executable()
    if exe:
        if re.search(r"\.app/Contents/Resources/", exe):
            return "app"
        return "deb" if exe.startswith("/usr/") and os.path.exists("/var/lib/dpkg/info/rowbase.list") else "onefile"
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if os.path.isdir(os.path.join(here, ".git")):
        return "source"
    prefix = sys.prefix.replace("\\", "/").lower()
    return "pipx" if "/pipx/" in prefix else "uv" if "/uv/tools/" in prefix else "pip"


HOW = {
    "app": "Rowbase.app updates itself: Rowbase → Check for Updates…",
    "pipx": "pipx upgrade rowbase-db",
    "uv": "uv tool upgrade rowbase-db",
    "pip": "python -m pip install -U rowbase-db",
    "source": "git pull && pip install -e .",
    "onefile": "rowbase update",
    "deb": "download the new rowbase_<version>_<arch>.deb from the release page and open it (or: sudo apt install ./rowbase_*.deb)",
}


def _cache_path():
    return os.path.join(store.HOME, "update.json")


def _fetch(url, timeout):
    req = urllib.request.Request(url, headers={"User-Agent": f"rowbase/{__version__}", "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def latest(force=False, timeout=3):
    """{version, notes_url, assets{name: url}, checked_at} of the newest release; cached; None when unreachable."""
    try:
        with open(_cache_path(), encoding="utf-8") as f:
            cached = json.load(f)
        if not force and time.time() - cached.get("checked_at", 0) < TTL:
            return cached
    except (OSError, ValueError):
        cached = None
    try:
        rel = json.loads(_fetch(API, timeout))
        info = {"version": rel["tag_name"].lstrip("v"), "notes_url": rel.get("html_url"), "checked_at": time.time(),
                "assets": {a["name"]: a["browser_download_url"] for a in rel.get("assets", [])}}
    except Exception:
        return cached  # offline / rate-limited: keep the last known answer
    try:
        os.makedirs(store.HOME, mode=0o700, exist_ok=True)
        tmp = _cache_path() + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(info, f)
        os.replace(tmp, _cache_path())
    except OSError:
        pass
    return info


def check(force=False, timeout=3):
    """Status for CLI/web: {current, latest, available, kind, how, notes_url} (latest None = unknown)."""
    kind = install_kind()
    info = latest(force, timeout)
    v = info and info.get("version")
    return {"current": __version__, "latest": v, "available": bool(v) and vtuple(v) > vtuple(__version__),
            "kind": kind, "how": HOW[kind], "notes_url": info and info.get("notes_url"),
            "canSelfUpdate": kind == "onefile" and bool(info and asset_name() in info.get("assets", {}))}


def self_update(info=None, target=None, log=lambda s: None):
    """Replace the one-file binary with the latest release asset (SHA-256 verified, smoke-tested). Returns the new version."""
    info = info or latest(force=True, timeout=10)
    if not info:
        raise RuntimeError("Could not reach GitHub to check for updates.")
    target = target or executable()
    if not target:
        raise RuntimeError(f"Not a one-file binary — update with: {HOW[install_kind()]}")
    name, assets = asset_name(), info.get("assets", {})
    if name not in assets or "SHA256SUMS" not in assets:
        raise RuntimeError(f"Release {info['version']} has no {name} (or SHA256SUMS) — download it manually: {info.get('notes_url')}")
    sums = dict(reversed(l.split(None, 1)) for l in _fetch(assets["SHA256SUMS"], 30).decode().splitlines() if l.strip())
    want = (sums.get(name) or sums.get("*" + name) or "").lower()
    if not want:
        raise RuntimeError(f"SHA256SUMS has no entry for {name}")
    new = target + ".new"
    log(f"Downloading {name} {info['version']}…")
    h = hashlib.sha256()
    try:
        req = urllib.request.Request(assets[name], headers={"User-Agent": f"rowbase/{__version__}"})
        with urllib.request.urlopen(req, timeout=60) as r, open(new, "wb") as f:
            while chunk := r.read(1 << 16):
                h.update(chunk)
                f.write(chunk)
        if h.hexdigest() != want:
            raise RuntimeError(f"Checksum mismatch for {name} — update aborted, nothing changed.")
        os.chmod(new, 0o755)
        out = subprocess.run([new, "--version"], capture_output=True, text=True, timeout=120)
        if info["version"] not in out.stdout + out.stderr:
            raise RuntimeError(f"Downloaded binary failed its self-test: {(out.stdout + out.stderr).strip()[:200]}")
    except PermissionError:
        _rm(new)
        raise RuntimeError(f"No write access to {os.path.dirname(target)} — download {name} manually: {info.get('notes_url')}")
    except BaseException:
        _rm(new)
        raise
    if sys.platform == "win32":  # a running .exe can't be overwritten, but it can be renamed
        _rm(target + ".old")
        os.replace(target, target + ".old")
    os.replace(new, target)
    return info["version"]


def cleanup():
    """Windows: remove the previous binary left behind by self_update (it was running at the time)."""
    exe = executable()
    if exe and sys.platform == "win32":
        _rm(exe + ".old")


def _rm(path):
    try:
        os.remove(path)
    except OSError:
        pass
