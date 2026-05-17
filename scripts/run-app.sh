#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Regenerate the Xcode project (idempotent — does nothing if up to date).
echo "==> xcodegen generate"
xcodegen generate

# Build the .app (Debug).
echo "==> xcodebuild VoicePOCApp Debug"
xcodebuild \
    -project VoicePOC.xcodeproj \
    -scheme VoicePOCApp \
    -configuration Debug \
    -derivedDataPath build/derived \
    build \
    | tail -20

APP="build/derived/Build/Products/Debug/VoicePOC.app"
if [[ ! -d "$APP" ]]; then
    echo "ERROR: .app not found at $APP" >&2
    exit 1
fi

echo
echo "Launching $APP …"
echo "  (this terminal will receive the app's stdout — Ctrl-C to terminate)"
echo

# Run the binary directly so we see stdout in this terminal.
exec "$APP/Contents/MacOS/VoicePOC"
