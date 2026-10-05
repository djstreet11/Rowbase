#!/usr/bin/env python3
"""Sparkle appcast for Rowbase.app (docs/UPDATES.md): prepend this release to the previous feed, keep the last N items.

  python packaging/appcast.py --version 0.3.0 --build 412 --archive native/dist/Rowbase-0.3.0.zip \
      --signature "$(sign_update … archive)" --notes notes.txt [--previous prev.xml] -o appcast.xml

--signature takes sign_update's output (`sparkle:edSignature="…" length="…"`) or the bare base64 signature.
--notes: one change per line (commit subjects); empty lines are ignored. Stdlib only.
"""
import argparse, html, os, re, sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
REPO = "https://github.com/djstreet11/Rowbase"
ET.register_namespace("sparkle", SPARKLE)
S = lambda tag: f"{{{SPARKLE}}}{tag}"


def parse_signature(s):
    m = re.search(r'edSignature="([^"]+)"', s)
    sig = (m.group(1) if m else s).strip()
    if not re.fullmatch(r"[A-Za-z0-9+/]+=*", sig):
        raise ValueError("not an EdDSA signature")
    return sig


def notes_html(version, lines):
    items = "".join(f"<li>{html.escape(x)}</li>" for x in (l.strip() for l in lines) if x)
    return (f"<h3>Rowbase {html.escape(version)}</h3>" + (f"<ul>{items}</ul>" if items else "")
            + f'<p><a href="{REPO}/releases/tag/v{html.escape(version)}">Full release notes</a></p>')


def make_item(version, build, url, length, signature, notes, min_os):
    it = ET.Element("item")
    ET.SubElement(it, "title").text = f"Rowbase {version}"
    ET.SubElement(it, S("version")).text = str(build)              # Sparkle compares this (CFBundleVersion)
    ET.SubElement(it, S("shortVersionString")).text = version
    ET.SubElement(it, S("minimumSystemVersion")).text = min_os
    ET.SubElement(it, "description").text = notes                   # HTML, escaped by ElementTree
    ET.SubElement(it, "enclosure", {"url": url, "length": str(length), "type": "application/octet-stream",
                                     S("edSignature"): signature})
    return it


def build_feed(item, previous=None, keep=10):
    """New feed with `item` first, then up to keep-1 previous items with a different build number."""
    rss = ET.Element("rss", {"version": "2.0"})
    ch = ET.SubElement(rss, "channel")
    ET.SubElement(ch, "title").text = "Rowbase"
    ET.SubElement(ch, "link").text = REPO
    ET.SubElement(ch, "language").text = "en"
    ch.append(item)
    build = item.findtext(S("version"))
    if previous:
        old = [i for i in ET.fromstring(previous).iter("item") if i.findtext(S("version")) != build]
        ch.extend(old[:keep - 1])
    ET.indent(rss)
    return b'<?xml version="1.0" encoding="utf-8"?>\n' + ET.tostring(rss, encoding="utf-8") + b"\n"


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--version", required=True)
    p.add_argument("--build", required=True, type=int)
    p.add_argument("--archive", required=True, help="the update payload (zipped Rowbase.app)")
    p.add_argument("--signature", required=True)
    p.add_argument("--url", help="download URL (default: GitHub release asset for v<version>)")
    p.add_argument("--notes", help="file with one change per line")
    p.add_argument("--previous", help="previous appcast.xml (missing/empty file = new feed)")
    p.add_argument("--min-os", default="14.0")
    p.add_argument("--keep", type=int, default=10)
    p.add_argument("-o", "--output", required=True)
    a = p.parse_args(argv)
    name = os.path.basename(a.archive)
    url = a.url or f"{REPO}/releases/download/v{a.version}/{name}"
    lines = open(a.notes, encoding="utf-8").read().splitlines() if a.notes else []
    prev = None
    if a.previous and os.path.exists(a.previous) and os.path.getsize(a.previous):
        prev = open(a.previous, "rb").read()
        try:
            ET.fromstring(prev)
        except ET.ParseError:
            print(f"warning: {a.previous} is not XML — starting a new feed", file=sys.stderr)
            prev = None
    item = make_item(a.version, a.build, url, os.path.getsize(a.archive), parse_signature(a.signature),
                     notes_html(a.version, lines), a.min_os)
    with open(a.output, "wb") as f:
        f.write(build_feed(item, prev, a.keep))
    print(a.output)


if __name__ == "__main__":
    main()
