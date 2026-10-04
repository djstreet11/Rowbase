"""MCP server end to end: a real `python -m rowbase mcp` subprocess speaking JSON-RPC over stdio."""
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class MCPTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.home = tempfile.mkdtemp(prefix="rowbase-mcp-")
        cls.env = {**os.environ, "ROWBASE_HOME": cls.home, "ROWBASE_SECRETS": "file", "PYTHONPATH": ROOT}
        db = os.path.join(cls.home, "shop.db")
        con = sqlite3.connect(db)
        con.executescript("""CREATE TABLE customers(id INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE invoices(id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers, total REAL, note TEXT);
            INSERT INTO customers VALUES (1, 'Smith, Bob'), (2, 'ann');
            INSERT INTO invoices VALUES (1, 1, 9.5, 'paid'), (2, 2, 3, NULL);""")
        con.close()
        run = lambda *a: subprocess.run([sys.executable, "-m", "rowbase", *a], env=cls.env, capture_output=True, text=True, check=True)
        run("add", "shop", f"sqlite:///{db}", "--rw")      # write-enabled connection…
        run("add", "hidden", f"sqlite:///{db}")

    def session(self, msgs, settings=None):
        if settings is not None:
            with open(os.path.join(self.home, "settings.json"), "w") as f:
                json.dump({"mcp": settings}, f)
        init = [{"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                 "clientInfo": {"name": "test", "version": "1"}}}, {"jsonrpc": "2.0", "method": "notifications/initialized"}]
        reqs = init + [{"jsonrpc": "2.0", "id": i + 1, **m} for i, m in enumerate(msgs)]
        p = subprocess.run([sys.executable, "-m", "rowbase", "mcp"], env=self.env, capture_output=True, text=True,
                           input="\n".join(json.dumps(r) for r in reqs) + "\n", timeout=60)
        out = [json.loads(l) for l in p.stdout.splitlines()]  # stdout must contain ONLY protocol messages
        self.assertEqual(out[0]["result"]["serverInfo"]["name"], "rowbase")
        return out[1:]

    def call(self, name, **args):
        return {"method": "tools/call", "params": {"name": name, "arguments": args}}

    def text(self, r):
        return r["result"]["content"][0]["text"]

    def test_read_only_by_default(self):
        tools, conns, q, bad, desc, search = self.session([
            {"method": "tools/list"}, self.call("connections"),
            self.call("query", connection="shop", sql="SELECT c.name, i.total FROM invoices i JOIN customers c ON c.id = i.customer_id ORDER BY i.id"),
            self.call("query", connection="shop", sql="DELETE FROM invoices"),
            self.call("describe", connection="shop", table="invoices"),
            self.call("search_schema", connection="shop", text="custom")], settings={"connections": ["shop"]})
        names = [t["name"] for t in tools["result"]["tools"]]
        self.assertIn("guide", names)
        self.assertNotIn("apply_changes", names)                       # writes disabled → no write tool
        self.assertIn("shop,sqlite,null,read-only", self.text(conns))       # RW connection forced read-only for MCP
        self.assertNotIn("hidden", self.text(conns))                    # not exposed
        self.assertTrue(self.text(q).startswith('rows[2]{name,total}:\n  "Smith, Bob",9.5\n  ann,3'))
        self.assertTrue(bad["result"]["isError"])
        self.assertIn("customer_id,INTEGER,yes,null,null,customers.id", self.text(desc))
        self.assertIn("customers,name,TEXT", self.text(search))

    def test_writes_when_allowed(self):
        tools, dry, real, check = self.session([
            {"method": "tools/list"},
            self.call("apply_changes", connection="shop", table="invoices", changes=[{"op": "update", "key": {"id": "2"}, "set": {"note": "due"}}]),
            self.call("apply_changes", connection="shop", table="invoices", dry_run=False,
                      changes=[{"op": "update", "key": {"id": "2"}, "set": {"note": "due"}}]),
            self.call("query", connection="shop", sql="SELECT note FROM invoices WHERE id = 2", format="json")],
            settings={"allowWrites": True})
        self.assertIn("apply_changes", [t["name"] for t in tools["result"]["tools"]])
        self.assertIn("dry_run: true", self.text(dry))
        self.assertIn("affected[1]: 1", self.text(real))
        self.assertIn('"note": "due"', self.text(check))

    def test_guide_resources_prompts_minimal(self):
        tools, guide, res, prompt = self.session([
            {"method": "tools/list"}, {"method": "resources/read", "params": {"uri": "rowbase://guide"}},
            {"method": "resources/list"}, {"method": "prompts/get", "params": {"name": "setup"}}], settings={"toolset": "minimal"})
        self.assertEqual(sorted(t["name"] for t in tools["result"]["tools"]), ["connections", "describe", "guide", "query", "tables"])
        self.assertIn("Safety model", guide["result"]["contents"][0]["text"])
        self.assertIn("rowbase://schema/shop", [r["uri"] for r in res["result"]["resources"]])
        self.assertIn("rowbase-db", prompt["result"]["messages"][0]["content"]["text"])

    def test_print_config(self):
        out = subprocess.run([sys.executable, "-m", "rowbase", "mcp", "--print-config"], env=self.env, capture_output=True, text=True).stdout
        self.assertIn("claude mcp add rowbase --", out)
        self.assertIn('"mcpServers"', out)
        js = subprocess.run([sys.executable, "-m", "rowbase", "mcp", "--print-config", "--json"], env=self.env, capture_output=True, text=True).stdout
        self.assertIn("rowbase-db", json.loads(js)["prompt"])


if __name__ == "__main__":
    unittest.main()
