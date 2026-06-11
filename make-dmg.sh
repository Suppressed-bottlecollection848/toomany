#!/bin/bash
# Builds ProjectOpener.app and packs it into a drag-to-install DMG.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' packaging/Info.plist)
DMG="dist/ProjectOpener-$VERSION.dmg"
STAGING=$(mktemp -d)
RW="$STAGING/rw.dmg"
trap 'rm -rf "$STAGING"' EXIT

mkdir "$STAGING/root"
cp -R dist/ProjectOpener.app "$STAGING/root/"
ln -s /Applications "$STAGING/root/Applications"
cp packaging/AppIcon.icns "$STAGING/root/.VolumeIcon.icns"

hdiutil create -volname "ProjectOpener" -srcfolder "$STAGING/root" -ov -format UDRW "$RW" >/dev/null

# Set the custom-icon bit on the volume root so .VolumeIcon.icns shows.
MOUNT_DIR=$(hdiutil attach "$RW" -readwrite -noverify -nobrowse | grep -o '/Volumes/.*$' | head -1)
if command -v SetFile >/dev/null 2>&1 && [ -n "$MOUNT_DIR" ]; then
    SetFile -a C "$MOUNT_DIR" || true
fi
[ -n "$MOUNT_DIR" ] && hdiutil detach "$MOUNT_DIR" -quiet

rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -o "$DMG" >/dev/null

echo "Created $DMG"
echo "Note: the app is ad-hoc signed. On another Mac, right-click → Open the"
echo "first time (or: xattr -d com.apple.quarantine /Applications/ProjectOpener.app)."
