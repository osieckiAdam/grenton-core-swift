#!/bin/sh
# Builds the combined DocC documentation of the library modules and serves
# it locally.
#
#   scripts/docs.sh          build, then serve on http://localhost:8000
#   scripts/docs.sh build    build only, into .build/docs
set -e
cd "$(dirname "$0")/.."

OUTPUT=.build/docs
# The combined archive refuses a non-empty output directory, so start clean.
rm -rf .build/docs
swift package --allow-writing-to-directory "$OUTPUT" generate-documentation \
    --target GrentonModel --target GrentonRuntime \
    --target GrentonProvisioning --target GrentonDevices \
    --enable-experimental-combined-documentation \
    --transform-for-static-hosting --warnings-as-errors \
    --output-path "$OUTPUT"

# DocC can report an error and still exit 0; make sure the site exists.
if [ ! -f "$OUTPUT/documentation/grentondevices/index.html" ]; then
    echo "error: documentation was not generated (see the output above)" >&2
    exit 1
fi

[ "$1" = "build" ] && exit 0

PORT=${PORT:-8000}
echo "Documentation: http://localhost:$PORT/documentation/grentondevices/"
echo "Press Ctrl-C to stop."
python3 -m http.server "$PORT" --directory "$OUTPUT" --bind 127.0.0.1
