import importlib.util, os, tempfile, unittest
import xml.etree.ElementTree as ET

_spec = importlib.util.spec_from_file_location(
    "appcast", os.path.join(os.path.dirname(__file__), "..", "packaging", "appcast.py"))
appcast = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(appcast)
S = appcast.S
SIG = "Zm9vYmFyYmF6+/=="


class AppcastTest(unittest.TestCase):
    def run_main(self, d, version, build, previous=None, notes="Fix grid\n\n<b>bold</b> & co\n"):
        arc = os.path.join(d, f"Rowbase-{version}.zip")
        with open(arc, "wb") as f: f.write(b"x" * 123)
        nf = os.path.join(d, "notes.txt")
        with open(nf, "w") as f: f.write(notes)
        out = os.path.join(d, "appcast.xml")
        args = ["--version", version, "--build", str(build), "--archive", arc, "--notes", nf, "-o", out,
                "--signature", f'sparkle:edSignature="{SIG}" length="123"']
        if previous: args += ["--previous", previous]
        appcast.main(args)
        return out

    def test_signature_forms(self):
        self.assertEqual(appcast.parse_signature(f'sparkle:edSignature="{SIG}" length="9"'), SIG)
        self.assertEqual(appcast.parse_signature(SIG + "\n"), SIG)
        with self.assertRaises(ValueError): appcast.parse_signature("ERROR: no key")

    def test_new_feed_and_merge(self):
        with tempfile.TemporaryDirectory() as d:
            out = self.run_main(d, "0.3.0", 400, previous=os.path.join(d, "missing.xml"))
            items = list(ET.parse(out).iter("item"))
            self.assertEqual(len(items), 1)
            it = items[0]
            self.assertEqual(it.findtext(S("version")), "400")
            self.assertEqual(it.findtext(S("shortVersionString")), "0.3.0")
            enc = it.find("enclosure")
            self.assertEqual(enc.get("url"), "https://github.com/djstreet11/Rowbase/releases/download/v0.3.0/Rowbase-0.3.0.zip")
            self.assertEqual(enc.get("length"), "123")
            self.assertEqual(enc.get(S("edSignature")), SIG)
            desc = it.findtext("description")
            self.assertIn("<li>&lt;b&gt;bold&lt;/b&gt; &amp; co</li>", desc)   # commit text can't inject HTML
            self.assertEqual(desc.count("<li>"), 2)
            prev = os.path.join(d, "prev.xml"); os.replace(out, prev)
            out = self.run_main(d, "0.3.1", 405, previous=prev)
            self.assertEqual([i.findtext(S("version")) for i in ET.parse(out).iter("item")], ["405", "400"])
            os.replace(out, prev)   # re-running the same build replaces its item instead of duplicating it
            out = self.run_main(d, "0.3.1", 405, previous=prev)
            self.assertEqual([i.findtext(S("version")) for i in ET.parse(out).iter("item")], ["405", "400"])

    def test_keep_limit_and_bad_previous(self):
        item = lambda b: appcast.make_item("1.0", b, "u", 1, SIG, "", "14.0")
        feed = appcast.build_feed(item(1))
        for b in range(2, 15): feed = appcast.build_feed(item(b), feed, keep=10)
        builds = [i.findtext(S("version")) for i in ET.fromstring(feed).iter("item")]
        self.assertEqual(builds, [str(b) for b in range(14, 4, -1)])
        with tempfile.TemporaryDirectory() as d:
            bad = os.path.join(d, "bad.xml")
            with open(bad, "w") as f: f.write("Not Found")
            out = self.run_main(d, "0.3.0", 400, previous=bad)
            self.assertEqual(len(list(ET.parse(out).iter("item"))), 1)


if __name__ == "__main__":
    unittest.main()
