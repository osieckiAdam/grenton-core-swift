#!/bin/zsh
# Builds GrentonWatch.app — a minimal app bundle around grenton-cli.
#
# Needed on macOS 15+: the Local Network privacy prompt fires reliably only
# for real .app bundles. Bare binaries run from a terminal are silently
# denied (errno 50 on NWConnection, errno 65 on BSD sendto) with no prompt,
# and the Settings list offers no way to add them manually.
#
# Usage: Examples/make-watch-app.sh [output-dir]   (default: ./dist)
# Run:   open -W --stdout out.log --stderr out.log dist/GrentonWatch.app \
#            --args <om-host> <pin> --watch 60 --any-source \
#            --save-interface "$PWD/dist/interface.zip"
# Later runs need no pin (paths must be absolute — `open` starts at /):
#        open -W --stdout out.log --stderr out.log dist/GrentonWatch.app \
#            --args --interface-file "$PWD/dist/interface.zip" --watch 60 \
#            --any-source
set -e
cd "$(dirname "$0")/.."

OUT="${1:-dist}"
APP="$OUT/GrentonWatch.app"

swift build
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.grentoncore.watch-test</string>
	<key>CFBundleName</key>
	<string>GrentonWatch</string>
	<key>CFBundleExecutable</key>
	<string>GrentonWatch</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSLocalNetworkUsageDescription</key>
	<string>GrentonWatch łączy się z modułami CLU Grenton w sieci lokalnej (UDP), aby odbierać stany urządzeń.</string>
</dict>
</plist>
PLIST

cp .build/debug/grenton-cli "$APP/Contents/MacOS/GrentonWatch"
# Ad-hoc signature changes on every build, which may invalidate the granted
# Local Network permission — expect a fresh prompt (or a short errno-65
# window the session recovery rides out) after each rebuild.
codesign --force -s - "$APP"
echo "built: $APP"
