#!/bin/sh
# Prepares the release of the version the port already implements:
#
#   scripts/release.sh 0.11.2
#
# It is run on a branch, before the pull request. It checks that port.json
# and the vendored suite carry that version, turns the CHANGELOG's
# "## Unreleased" into the version and today's date, points every
# `from: "…"` in the documentation at it, and runs the quick gate. The
# merge into main then tags it (.github/workflows/release.yml); the
# release workflow checks the same things and refuses a version that is
# already tagged.
set -e
cd "$(dirname "$0")/.."
V=$1
[ -n "$V" ] || { echo "usage: scripts/release.sh X.Y.Z" >&2; exit 2; }
[ -z "$(git status --porcelain)" ] || { echo "release: commit or stash your changes first" >&2; exit 1; }
[ "$(git rev-parse --abbrev-ref HEAD)" != "main" ] || { echo "release: work on a branch, main takes pull requests only" >&2; exit 1; }

declared=$(python3 -c "import json;print(json.load(open('Tests/GrentonConformanceTests/port.json'))['suiteVersion'])")
vendored=$(python3 -c "import json;print(json.load(open('vendor/grenton-core-spec/conformance/manifest.json'))['suiteVersion'])")
[ "$declared" = "$V" ] && [ "$vendored" = "$V" ] || {
    echo "release: port.json declares $declared, vendored suite is $vendored, asked for $V — the port is not at that spec" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/$V" >/dev/null && { echo "release: $V is already tagged" >&2; exit 1; }
grep -q '^## Unreleased$' CHANGELOG.md || { echo "release: CHANGELOG.md has no '## Unreleased' section" >&2; exit 1; }

today=$(date +%Y-%m-%d)
sed -i '' "s/^## Unreleased$/## $V — $today/" CHANGELOG.md
for f in README.md site/index.html site/getting-started/index.html Sources/*/*.docc/*.md; do
    [ -f "$f" ] && sed -i '' -E "s/(grenton-core-swift(\.git)?\", from: \")[0-9.]+\"/\1$V\"/g" "$f"
done
scripts/check-release.py "$V"
scripts/check.sh quick
echo
echo "release $V prepared. Now:"
echo "  git add -A && git commit -m 'Release $V' && git push -u origin HEAD"
echo "  gh pr create --fill && gh pr merge --squash --delete-branch   # the merge tags $V"
