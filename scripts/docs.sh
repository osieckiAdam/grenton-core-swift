#!/bin/sh
# Builds the combined DocC documentation of the library modules and serves
# it locally.
#
#   scripts/docs.sh          build, then serve on http://localhost:8000
#   scripts/docs.sh build    build only, into .build/docs
set -e
cd "$(dirname "$0")/.."

OUTPUT=.build/docs
swift package --allow-writing-to-directory "$OUTPUT" generate-documentation \
    --target GrentonModel --target GrentonRuntime \
    --target GrentonProvisioning --target GrentonDevices \
    --enable-experimental-combined-documentation \
    --transform-for-static-hosting \
    --output-path "$OUTPUT"

[ "$1" = "build" ] && exit 0

PORT=${PORT:-8000}
echo "Documentation: http://localhost:$PORT/documentation/grentondevices"
echo "Press Ctrl-C to stop."
python3 -m http.server "$PORT" --directory "$OUTPUT" --bind 127.0.0.1
