#!/usr/bin/env python3
"""Stand-in for `ssh -N -L 127.0.0.1:LPORT:HOST:PORT … user@host` in tests: forwards TCP locally, ignores the remote host.
Writes its argv to $FAKE_SSH_LOG so tests can assert on the command line."""
import os
import socket
import sys
import threading

args = sys.argv[1:]
if os.environ.get("FAKE_SSH_LOG"):
    with open(os.environ["FAKE_SSH_LOG"], "a") as f:
        f.write(" ".join(args) + "\n")
if "fail.example" in args[-1]:
    sys.exit("ssh: Could not resolve hostname fail.example")
spec = args[args.index("-L") + 1]
_, lport, rest = spec.split(":", 2)
thost, tport = rest.rsplit(":", 1)


def pipe(a, b):
    try:
        while (d := a.recv(65536)):
            b.sendall(d)
    except OSError:
        pass
    finally:
        for s in (a, b):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", int(lport)))
srv.listen()
while True:
    c, _ = srv.accept()
    u = socket.create_connection((thost, int(tport)))
    threading.Thread(target=pipe, args=(c, u), daemon=True).start()
    threading.Thread(target=pipe, args=(u, c), daemon=True).start()
