#!/bin/sh
# The gate every change passes before it is pushed.
#
#   scripts/check.sh          everything (the pre-push hook runs this)
#   scripts/check.sh quick    the fast checks only (the pre-commit hook)
#
# Spec compliance is the conformance suite inside `swift test`; the spec
# sync check makes sure it is the current spec. Documentation must build
# without warnings, its code must compile, and the user-facing API must be
# documented. See CLAUDE.md.
set -e
cd "$(dirname "$0")/.."
step() { printf '\n== %s\n' "$1"; }

step "Installation data";  scripts/check-no-installation-data.py --all
step "Public API docs";    scripts/check-public-docs.py
step "Spec sync";          scripts/check-spec-sync.sh
[ "$1" = "quick" ] && { echo; echo "Quick checks passed."; exit 0; }

step "Build";              swift build
step "Tests, including the conformance suite"
if swift test > .build/check-tests.log 2>&1; then
    grep -E "Test run with" .build/check-tests.log | tail -1
else
    grep -E "error:|recorded an issue|Test run" .build/check-tests.log | tail -20
    echo "tests failed — full log: .build/check-tests.log" >&2
    exit 1
fi
step "Documentation site (DocC warnings are errors)"
if scripts/docs.sh build > .build/check-docs.log 2>&1; then
    echo "documentation: built without warnings"
else
    grep -iE "error|warning" .build/check-docs.log | tail -20
    echo "documentation failed — full log: .build/check-docs.log" >&2
    exit 1
fi
step "Site links";         scripts/check-site-links.py
step "Doc snippets";       scripts/check-doc-snippets.py

echo
echo "All checks passed."
