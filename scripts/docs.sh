#!/bin/sh
# Builds the documentation site and serves it locally.
#
#   scripts/docs.sh          build, then serve on http://localhost:8000/
#   scripts/docs.sh build    build only, into .build/site
#
# The site is the landing page and Getting Started from site/, plus the
# combined DocC reference of the library modules under api/. For hosting
# under a sub-path (GitHub Pages: /grenton-core-swift/), set
# BASE_PATH=grenton-core-swift/ when building.
set -e
cd "$(dirname "$0")/.."

SITE=.build/site
BASE_PATH=${BASE_PATH:-}

# The combined DocC archive refuses a non-empty output directory, so start clean.
# A file still in use (a running server, Finder) can make the first rm fail.
rm -rf "$SITE" 2>/dev/null || { sleep 1; rm -rf "$SITE"; }
mkdir -p "$SITE"
cp -R site/. "$SITE/"
cp docs/images/om-send-to-mobile.png "$SITE/assets/"

# The DocC plugin is a dependency only while GRENTON_DOCS=1 (Package.swift);
# SwiftPM then rewrites Package.resolved to include it. The working tree's
# own file — exactly as it was, staged or not, or absent — is put back as
# soon as the generation ends, not when this script exits: in serve mode
# that would leave the rewritten file in place for as long as the server
# runs. (Restoring from the index instead would discard unstaged edits.)
RESOLVED_BACKUP=$(mktemp)
HAD_RESOLVED=0
if [ -f Package.resolved ]; then cp Package.resolved "$RESOLVED_BACKUP"; HAD_RESOLVED=1; fi
GENERATOR=
restore_resolved() {
    # Idempotent: the generator must be gone first, or it rewrites the file
    # after the restore.
    if [ -n "$GENERATOR" ]; then kill "$GENERATOR" 2>/dev/null; wait "$GENERATOR" 2>/dev/null; GENERATOR=; fi
    if [ -f "$RESOLVED_BACKUP" ]; then
        if [ "$HAD_RESOLVED" = 1 ]; then cp "$RESOLVED_BACKUP" Package.resolved; else rm -f Package.resolved; fi
        rm -f "$RESOLVED_BACKUP"
    fi
}
# EXIT alone does not run on a signal; name them.
trap 'restore_resolved' EXIT
trap 'restore_resolved; exit 130' INT
trap 'restore_resolved; exit 143' TERM HUP
GRENTON_DOCS=1 swift package --allow-writing-to-directory "$SITE/api" generate-documentation \
    --target GrentonModel --target GrentonRuntime \
    --target GrentonProvisioning --target GrentonDevices \
    --target GrentonKit --target GrentonSimulation \
    --enable-experimental-combined-documentation --include-extended-types \
    --transform-for-static-hosting --warnings-as-errors \
    --experimental-enable-custom-templates \
    --hosting-base-path "${BASE_PATH}api" \
    --output-path "$SITE/api" &
GENERATOR=$!
if wait "$GENERATOR"; then GENERATOR=; else STATUS=$?; GENERATOR=; restore_resolved; exit $STATUS; fi
restore_resolved

# DocC can report an error and still exit 0; make sure the reference exists.
# The shared header (GrentonDevices.docc/header.html) links back to the site
# root, which depends on where the site is hosted.
find "$SITE/api" -name index.html -exec sed -i '' "s#__BASE__#/${BASE_PATH}#g" {} +

for page in index.html getting-started/index.html \
    api/documentation/grentondevices/index.html \
    api/documentation/grentonkit/index.html \
    api/documentation/grentonsimulation/simulatedgrentonsystem/index.html \
    "api/documentation/grentonkit/grentonsystem/init(interfacearchive:socketfactory:logger:pinginterval:registerinterval:responsetimeout:)/index.html"; do
    if [ ! -f "$SITE/$page" ]; then
        echo "error: $page was not generated (see the output above)" >&2
        exit 1
    fi
done

[ "$1" = "build" ] && exit 0

# Take the first free port from $PORT (default 8000) on; an earlier run may
# still be serving in another terminal.
PORT=$(python3 - "${PORT:-8000}" <<'PY'
import socket, sys
start = int(sys.argv[1])
for port in range(start, start + 20):
    with socket.socket() as s:
        try:
            s.bind(("127.0.0.1", port))
        except OSError:
            continue
        print(port)
        break
else:
    sys.exit(f"no free port in {start}-{start + 19}")
PY
)
echo "Documentation: http://localhost:$PORT/"
echo "Press Ctrl-C to stop."
# no-store: after a rebuild the browser must not show a cached older site.
python3 - "$PORT" "$SITE" <<'PY'
import functools, http.server, sys

class NoCache(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

port, root = int(sys.argv[1]), sys.argv[2]
handler = functools.partial(NoCache, directory=root)
with http.server.ThreadingHTTPServer(("127.0.0.1", port), handler) as server:
    print(f"Serving {root} on http://127.0.0.1:{port}/")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
PY
