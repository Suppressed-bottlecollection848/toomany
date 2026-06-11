#!/bin/bash
# Builds ProjectOpener.app into dist/
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="dist/ProjectOpener.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp packaging/Info.plist "$APP/Contents/Info.plist"
cp packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/ProjectOpener "$APP/Contents/MacOS/ProjectOpener"
codesign --force -s - "$APP"

echo "Built $APP"
echo "Run with:  open $APP"
echo "Install:   cp -R $APP /Applications/"
