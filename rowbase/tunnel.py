"""SSH tunnels via the system `ssh` binary, so ~/.ssh/config, keys, agent and ProxyJump just work.

Connection field (shared contract): "ssh": {"host": "bastion", "port": 22, "user": "deploy", "identityFile": "~/.ssh/id_ed25519"}.
Only key/agent auth (BatchMode=yes) — no password prompts. ROWBASE_SSH overrides the ssh binary (tests use a fake one).
"""
import atexit
import os
import socket
import subprocess
import threading
import time

from .guard import QueryError

_tunnels, _lock = {}, threading.Lock()


def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def command(ssh, target, local_port):
    """argv for `ssh -N -L 127.0.0.1:<local>:<target> …`; target is 'host:port' or a remote unix socket path."""
    argv = [os.environ.get("ROWBASE_SSH", "ssh"), "-N", "-L", f"127.0.0.1:{local_port}:{target}",
            "-o", "ExitOnForwardFailure=yes", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=30",
            "-o", "ConnectTimeout=10"]
    if ssh.get("port"):
        argv += ["-p", str(int(ssh["port"]))]
    if ssh.get("identityFile"):
        argv += ["-i", os.path.expanduser(ssh["identityFile"])]
    host = ssh["host"]
    return argv + [f"{ssh['user']}@{host}" if ssh.get("user") else host]


def target_of(c, default_port):
    if c.get("socket"):
        return c["socket"]
    return f"{c.get('host') or '127.0.0.1'}:{int(c.get('port') or default_port)}"


def open_tunnel(ssh, target, timeout=15):
    """Start (or reuse) a tunnel; returns the local port."""
    key = (tuple(sorted(ssh.items())), target)
    with _lock:
        t = _tunnels.get(key)
        if t and t["proc"].poll() is None:
            return t["port"]
    port = _free_port()
    proc = subprocess.Popen(command(ssh, target, port), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=subprocess.PIPE, start_new_session=True)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            err = proc.stderr.read().decode(errors="replace").strip()
            raise QueryError(f"SSH tunnel failed: {err or f'ssh exited with {proc.returncode}'}")
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
            break
        except OSError:
            time.sleep(0.1)
    else:
        proc.kill()
        raise QueryError(f"SSH tunnel to {ssh['host']} timed out")
    with _lock:
        _tunnels[key] = {"proc": proc, "port": port}
    return port


def close_all():
    with _lock:
        procs = [t["proc"] for t in _tunnels.values()]
        _tunnels.clear()
    for p in procs:
        p.terminate()


atexit.register(close_all)
