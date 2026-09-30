#!/usr/bin/env python3
"""Gate: every public declaration of the user-facing modules has a doc comment.

    scripts/check-public-docs.py

Checks GrentonDevices and GrentonProvisioning, the modules apps use. Enum
cases, members of protocol-conformance extensions (their docs come from the
protocol) and declarations marked `// docs: internal` are exempt.
GrentonModel and GrentonRuntime are not checked yet: most of their public
symbols are plumbing between modules (see CLAUDE.md).
"""
import pathlib
import re
import sys

MODULES = ["GrentonDevices", "GrentonProvisioning"]
DECL = re.compile(r"^\s*(public|open)\s+(?!extension)(static |final |nonisolated |indirect |override )*"
                  r"(func|var|let|struct|enum|class|actor|protocol|init|typealias|subscript)\b")
ROOT = pathlib.Path(__file__).resolve().parent.parent

missing = []
for module in MODULES:
    for path in sorted((ROOT / "Sources" / module).rglob("*.swift")):
        lines = path.read_text().split("\n")
        extension_depth = None   # brace depth while inside `extension X: Protocol {`
        depth = 0
        for number, line in enumerate(lines, 1):
            stripped = line.strip()
            if re.match(r"^extension \w+\s*:\s*\w", stripped) and extension_depth is None:
                extension_depth = depth
            if DECL.match(line) and extension_depth is None and "// docs: internal" not in line:
                above = number - 2
                while above >= 0 and lines[above].strip().startswith("@"):
                    above -= 1
                if above < 0 or not lines[above].strip().startswith("///"):
                    missing.append(f"{path.relative_to(ROOT)}:{number}: {stripped[:90]}")
            depth += line.count("{") - line.count("}")
            if extension_depth is not None and depth <= extension_depth:
                extension_depth = None

for m in missing:
    print("undocumented:", m)
print(f"public docs: {len(missing)} undocumented declaration(s) in {', '.join(MODULES)}")
sys.exit(1 if missing else 0)
