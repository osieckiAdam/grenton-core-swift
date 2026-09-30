#!/usr/bin/env python3
"""Gate: every internal link of the built site points at a file that exists.

    scripts/check-site-links.py      (after scripts/docs.sh build)

Checks the hand-written pages and the shared header in .build/site: href and
src values that are relative or root-relative. The DocC reference's own
links are DocC's business (it runs with warnings as errors).
"""
import pathlib
import re
import sys
from urllib.parse import urldefrag, urlparse

SITE = pathlib.Path(__file__).resolve().parent.parent / ".build" / "site"
if not (SITE / "index.html").is_file():
    sys.exit("site links: no built site — run scripts/docs.sh build first")

pages = [p for p in SITE.rglob("*.html") if "api" not in p.relative_to(SITE).parts[:1]]
pages.append(SITE / "api/documentation/grentondevices/index.html")   # carries the shared header
broken = []
for page in pages:
    for link in re.findall(r'(?:href|src)="([^"]+)"', page.read_text()):
        target = urldefrag(link)[0]
        if not target or urlparse(target).scheme or target.startswith(("//", "mailto:")):
            continue
        base = SITE if target.startswith("/") else page.parent
        resolved = (base / target.lstrip("/")).resolve()
        if resolved.is_dir():
            resolved = resolved / "index.html"
        if not resolved.is_file():
            broken.append(f"{page.relative_to(SITE)}: {link}")
for b in broken:
    print("broken link:", b)
print(f"site links: {len(pages)} page(s), {len(broken)} broken")
sys.exit(1 if broken else 0)
