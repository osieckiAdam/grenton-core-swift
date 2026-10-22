#!/bin/sh
# Gate: this clone runs the repository hooks, and the installation-data gate
# is the same script the spec repository runs.
cd "$(dirname "$0")/.."
hooks=$(git config --get core.hooksPath)
if [ "$hooks" != "scripts/hooks" ]; then
    echo "git hooks: not enabled in this clone — run: git config core.hooksPath scripts/hooks" >&2
    exit 1
fi
if ! cmp -s scripts/check-no-installation-data.py vendor/grenton-core-spec/tools/check_no_installation_data.py; then
    echo "git hooks: scripts/check-no-installation-data.py differs from the spec repository's copy — copy it over" >&2
    exit 1
fi
echo "git hooks: enabled; installation-data gate identical to the spec's"
