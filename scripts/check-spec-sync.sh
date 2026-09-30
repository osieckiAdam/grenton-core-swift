#!/bin/sh
# Gate: the port tests the spec it claims, and the vendored spec is current.
#
#   - vendor/grenton-core-spec is checked out and has no local edits;
#   - port.json declares the suite version the vendored manifest carries;
#   - when a sibling ../grenton-core-spec checkout exists, the submodule
#     points at the same commit (a spec change must reach the port).
set -e
cd "$(dirname "$0")/.."
SPEC=vendor/grenton-core-spec
fail() { echo "spec sync: $1" >&2; exit 1; }

[ -f "$SPEC/conformance/manifest.json" ] || fail "submodule missing — run: git submodule update --init"
[ -z "$(git -C "$SPEC" status --porcelain)" ] || fail "$SPEC has local edits — change the spec in its own repository"

vendored=$(python3 -c "import json;print(json.load(open('$SPEC/conformance/manifest.json'))['suiteVersion'])")
declared=$(python3 -c "import json;print(json.load(open('Tests/GrentonConformanceTests/port.json'))['suiteVersion'])")
[ "$vendored" = "$declared" ] || fail "port.json declares suite $declared, vendored suite is $vendored — update port.json"

if [ -d ../grenton-core-spec/.git ]; then
    local_head=$(git -C ../grenton-core-spec rev-parse HEAD)
    vendored_head=$(git -C "$SPEC" rev-parse HEAD)
    if [ "$local_head" != "$vendored_head" ]; then
        fail "vendored spec is at ${vendored_head%"${vendored_head#???????}"}, ../grenton-core-spec at ${local_head%"${local_head#???????}"} — push the spec, then: git -C $SPEC fetch && git -C $SPEC checkout origin/main"
    fi
fi
echo "spec sync: suite $declared, submodule current"
