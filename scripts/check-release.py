#!/usr/bin/env python3
"""Gate: the tree is a release of the given version.

    scripts/check-release.py 0.11.2

The newest CHANGELOG heading is that version (no "## Unreleased" above it),
every `from: "…"` the documentation shows points at it, and port.json and
the vendored suite carry it. scripts/release.sh runs it after preparing a
release; the release workflow runs it on every merge into main.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
version = sys.argv[1] if len(sys.argv) > 1 else None
problems = []

changelog = (ROOT / "CHANGELOG.md").read_text()
newest = re.search(r"^## (\S+)", changelog, re.M).group(1)
if newest != version:
    problems.append(f"CHANGELOG.md: newest heading is '{newest}', expected '{version} — <date>'")

for path in [ROOT / "README.md", *ROOT.glob("site/**/*.html"), *ROOT.glob("Sources/*/*.docc/*.md")]:
    for found in re.findall(r'grenton-core-swift(?:\.git)?", from: "([0-9.]+)"', path.read_text()):
        if found != version:
            problems.append(f"{path.relative_to(ROOT)}: from: \"{found}\" should be \"{version}\"")

declared = json.load(open(ROOT / "Tests/GrentonConformanceTests/port.json"))["suiteVersion"]
vendored = json.load(open(ROOT / "vendor/grenton-core-spec/conformance/manifest.json"))["suiteVersion"]
if declared != version or vendored != version:
    problems.append(f"port.json declares suite {declared}, vendored suite is {vendored}, release is {version}")

for p in problems:
    print(p)
print(f"release {version}: {'OK' if not problems else 'FAILED'}")
sys.exit(1 if problems else 0)
