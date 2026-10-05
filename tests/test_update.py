import tests.test_engine  # noqa: F401  (sets ROWBASE_HOME/SECRETS before any rowbase import)
import hashlib, io, json, os, sys, tempfile, threading, unittest
from contextlib import redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock

from rowbase import cli, server, store, update

NEW = "9.9.9"
BIN = f'#!{sys.executable}\nprint("rowbase {NEW}")\n'.encode()


class Release(BaseHTTPRequestHandler):
    files = {}

    def log_message(self, *a):
        pass

    def do_GET(self):
        body = self.files.get(self.path)
        self.send_response(200 if body is not None else 404)
        self.end_headers()
        self.wfile.write(body or b"")


@unittest.skipIf(sys.platform == "win32", "fake binary is a shebang script")
class UpdateTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = ThreadingHTTPServer(("127.0.0.1", 0), Release)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.srv.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()

    def setUp(self):
        self.release(BIN)
        self.api = mock.patch.object(update, "API", self.base + "/latest")
        self.api.start()
        self.addCleanup(self.api.stop)
        update._rm(update._cache_path())
        os.environ.pop("ROWBASE_NO_UPDATE_CHECK", None)

    def release(self, binary, sums=None, with_sums=True):
        name = update.asset_name()
        assets = [{"name": name, "browser_download_url": self.base + "/bin"}]
        if with_sums:
            assets.append({"name": "SHA256SUMS", "browser_download_url": self.base + "/sums"})
        Release.files = {
            "/latest": json.dumps({"tag_name": "v" + NEW, "html_url": "https://example/rel", "assets": assets}).encode(),
            "/bin": binary,
            "/sums": (sums or f"{hashlib.sha256(binary).hexdigest()}  {name}\nabc  other-file\n").encode(),
        }

    def target(self):
        d = tempfile.mkdtemp()
        p = os.path.join(d, "rowbase")
        with open(p, "wb") as f:
            f.write(b"old")
        return p

    def test_versions_and_check(self):
        self.assertGreater(update.vtuple("v0.10.0"), update.vtuple("0.9.9"))
        self.assertEqual(update.vtuple("1.2"), (1, 2))
        st = update.check()
        self.assertEqual((st["latest"], st["available"], st["notes_url"]), (NEW, True, "https://example/rel"))
        self.assertIn(st["kind"], update.HOW)
        Release.files = {}  # offline / GitHub down → cached answer
        self.assertEqual(update.check(force=True)["latest"], NEW)
        update._rm(update._cache_path())
        st = update.check(force=True)
        self.assertEqual((st["latest"], st["available"]), (None, False))

    def test_opt_out(self):
        os.environ["ROWBASE_NO_UPDATE_CHECK"] = "1"
        self.addCleanup(os.environ.pop, "ROWBASE_NO_UPDATE_CHECK", None)
        self.assertTrue(update.disabled())
        self.assertTrue(server.version_info()["disabled"])
        del os.environ["ROWBASE_NO_UPDATE_CHECK"]
        with mock.patch.object(store, "settings", lambda: {"updates": {"check": False}}):
            self.assertTrue(update.disabled())
        self.assertFalse(update.disabled())

    def test_self_update(self):
        t = self.target()
        self.assertEqual(update.self_update(target=t), NEW)
        with open(t, "rb") as f:
            self.assertEqual(f.read(), BIN)
        self.assertTrue(os.access(t, os.X_OK))
        self.assertFalse(os.path.exists(t + ".new"))

    def test_refuses_bad_downloads(self):
        cases = [
            (dict(sums="0" * 64 + "  " + update.asset_name() + "\n"), "Checksum mismatch"),
            (dict(with_sums=False), "SHA256SUMS"),
            (dict(sums="abc  other-file\n"), "no entry"),
        ]
        for kw, msg in cases:
            self.release(BIN, **kw)
            t = self.target()
            with self.assertRaisesRegex(RuntimeError, msg):
                update.self_update(info=update.latest(force=True), target=t)
            with open(t, "rb") as f:
                self.assertEqual(f.read(), b"old")  # untouched
            self.assertFalse(os.path.exists(t + ".new"))
        broken = f'#!{sys.executable}\nprint("rowbase 0.0.1")\n'.encode()   # wrong/broken binary fails the self-test
        self.release(broken)
        t = self.target()
        with self.assertRaisesRegex(RuntimeError, "self-test"):
            update.self_update(info=update.latest(force=True), target=t)
        with open(t, "rb") as f:
            self.assertEqual(f.read(), b"old")

    def test_not_onefile(self):
        with self.assertRaisesRegex(RuntimeError, "Not a one-file binary"):
            update.self_update(info=update.latest(force=True))

    def test_cli(self):
        out = io.StringIO()
        with redirect_stdout(out), self.assertRaises(SystemExit) as e:
            cli.main(["update", "--check"])
        self.assertEqual(e.exception.code, 10)
        self.assertIn(f"Rowbase {NEW} is available", out.getvalue())
        out = io.StringIO()
        with redirect_stdout(out), mock.patch.object(update, "install_kind", lambda: "pipx"):
            cli.main(["update"])
        self.assertIn("pipx upgrade rowbase-db", out.getvalue())
        with redirect_stdout(io.StringIO()) as o, self.assertRaises(SystemExit):
            cli.main(["--version"])
        self.assertIn("rowbase ", o.getvalue())


if __name__ == "__main__":
    unittest.main()
