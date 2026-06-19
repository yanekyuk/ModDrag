#!/usr/bin/env bash
#
# build-icon.sh — render the ModDrag master art and produce AppIcon.icns.
#
# Pipeline:
#   1. swift make-icon.swift  -> 1024x1024 master PNG
#   2. sips                   -> all required iconset sizes
#   3. iconutil               -> AppIcon.icns
#
# Output: scripts/AppIcon.icns (committed, consumed by build-app.sh)
#
set -euo pipefail
cd "$(dirname "$0")"

MASTER="icon-1024.png"
ICONSET="AppIcon.iconset"
ICNS="AppIcon.icns"

echo "==> Rendering master artwork"
swift make-icon.swift "$MASTER"

echo "==> Generating iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
gen() { sips -z "$2" "$2" "$MASTER" --out "$ICONSET/$1" >/dev/null; }
gen "icon_16x16.png"        16
gen "icon_16x16@2x.png"     32
gen "icon_32x32.png"        32
gen "icon_32x32@2x.png"     64
gen "icon_128x128.png"      128
gen "icon_128x128@2x.png"   256
gen "icon_256x256.png"      256
gen "icon_256x256@2x.png"   512
gen "icon_512x512.png"      512
gen "icon_512x512@2x.png"   1024

echo "==> Building $ICNS"
iconutil -c icns "$ICONSET" -o "$ICNS"

rm -rf "$ICONSET"
echo "==> Done: scripts/$ICNS"

echo "==> Rendering menu-bar template"
swift make-tray.swift TrayIcon.pdf
echo "==> Done: scripts/TrayIcon.pdf"
