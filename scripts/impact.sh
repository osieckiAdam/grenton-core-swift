#!/bin/sh
# Lists what a change touches and the questions it raises. Advisory; the
# gates are in scripts/check.sh.
#
#   scripts/impact.sh [base]    default base: origin/main
cd "$(dirname "$0")/.."
BASE=${1:-origin/main}
FILES=$( { git diff --name-only "$BASE"...HEAD 2>/dev/null; git diff --name-only HEAD; git ls-files --others --exclude-standard; } | sort -u)
[ -n "$FILES" ] || { echo "impact: no changes against $BASE"; exit 0; }

has() { echo "$FILES" | grep -qE "$1"; }
echo "Changed against $BASE:"
echo "$FILES" | sed 's/^/  /'
echo
has '^Sources/Grenton(Model|Runtime|Provisioning|Devices)/.*\.swift$' && cat <<'Q'
Library code changed:
  - Does it change protocol or mapping behaviour? Then the spec changes first
    (grenton-core-spec: rule text, conformance cases, CHANGELOG, version),
    and port.json follows the new suite version.
  - Does it add or change public API? Doc comments, the DocC articles and
    README examples must describe it; check Examples/ still show the best way.
Q
has '^vendor/grenton-core-spec$' && echo "Spec submodule moved: bump port.json if the suite version changed; re-read the spec CHANGELOG for rules the port must now follow."
has '\.docc/' && echo "Articles changed: their code is compiled by scripts/check-doc-snippets.py."
has '^Examples/' && echo "Examples changed: keep README's Examples table and quick start in step."
has '^Tests/GrentonConformanceTests/port\.json$' && echo "port.json changed: a skip needs a reason; a new profile needs every case of it passing."
exit 0
