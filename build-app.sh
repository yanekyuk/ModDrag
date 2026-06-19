#!/usr/bin/env bash
#
# Build ModDrag.app — a self-contained menu-bar app bundle.
#
# Launching the bare `mod-drag` executable from Finder forces macOS to run it
# inside Terminal. Wrapping the same binary in a .app bundle (with LSUIElement
# set) makes double-clicking launch it as a background GUI app — no terminal.
#
# Usage: ./build-app.sh

set -euo pipefail

APP_NAME="ModDrag"
BUNDLE="${APP_NAME}.app"
BUNDLE_ID="com.yanek.moddrag"
VERSION="1.0"

cd "$(dirname "$0")"

echo "==> Cleaning previous bundle"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"

echo "==> Compiling Swift sources"
swiftc -O ModDrag.swift -o "$BUNDLE/Contents/MacOS/$APP_NAME"

echo "==> Installing app icon"
if [ ! -f scripts/AppIcon.icns ] || [ ! -f scripts/TrayIcon.pdf ]; then
    ./scripts/build-icon.sh
fi
cp scripts/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
cp scripts/TrayIcon.pdf "$BUNDLE/Contents/Resources/TrayIcon.pdf"

echo "==> Writing Info.plist"
cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Code signing (ad-hoc)"
codesign --force --deep --sign - "$BUNDLE"

echo "==> Done: $BUNDLE"
echo "    Launch with: open $BUNDLE"
