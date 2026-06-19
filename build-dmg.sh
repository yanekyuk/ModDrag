#!/usr/bin/env bash
#
# Build ModDrag.dmg — a drag-to-install disk image.
#
# Produces the classic macOS installer window: the app icon on the left and an
# /Applications shortcut on the right, so the user just drags one onto the
# other. Uses only built-in tools (hdiutil + osascript) — no Homebrew needed.
#
# Usage: ./build-dmg.sh

set -euo pipefail

APP_NAME="ModDrag"
APP="${APP_NAME}.app"
VOL_NAME="${APP_NAME}"
DMG_FINAL="${APP_NAME}.dmg"
DMG_TMP="${APP_NAME}-tmp.dmg"
STAGING="dmg-staging"

cd "$(dirname "$0")"

# Make sure the app bundle exists / is current.
echo "==> Building app bundle"
./build-app.sh

echo "==> Preparing staging folder"
rm -rf "$STAGING" "$DMG_TMP" "$DMG_FINAL"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# Window background image (regenerated if missing).
if [ ! -f scripts/dmg-background.png ]; then
    swift scripts/make-dmg-background.swift scripts/dmg-background.png
fi
mkdir -p "$STAGING/.background"
cp scripts/dmg-background.png "$STAGING/.background/dmg-background.png"

echo "==> Creating writable disk image"
hdiutil create \
    -srcfolder "$STAGING" \
    -volname "$VOL_NAME" \
    -fs HFS+ \
    -format UDRW \
    -ov "$DMG_TMP" >/dev/null

echo "==> Mounting image"
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_TMP" \
    | egrep '^/dev/' | sed 1q | awk '{print $1}')
MOUNT="/Volumes/$VOL_NAME"
sleep 2

echo "==> Arranging icon layout"
osascript <<EOF
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {300, 150, 900, 530}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set background picture of theViewOptions to file ".background:dmg-background.png"
        set position of item "$APP" of container window to {150, 190}
        set position of item "Applications" of container window to {450, 190}
        close
        open
        update without registering applications
        delay 2
    end tell
end tell
EOF

sync

echo "==> Unmounting"
hdiutil detach "$DEVICE" >/dev/null

echo "==> Converting to compressed read-only image"
hdiutil convert "$DMG_TMP" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_FINAL" >/dev/null

rm -f "$DMG_TMP"
rm -rf "$STAGING"

echo "==> Done: $DMG_FINAL"
echo "    Open with: open $DMG_FINAL"
