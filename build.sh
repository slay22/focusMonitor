#!/bin/sh
# Builds focusMonitor.app (menu bar app). Run: ./build.sh && open focusMonitor.app
set -e
cd "$(dirname "$0")"
APP=focusMonitor.app
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
if [ ! -f AppIcon.icns ]; then # delete AppIcon.icns to regenerate from icon.swift
  T=$(mktemp -d); swift icon.swift $T/icon.png; mkdir $T/AppIcon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s $T/icon.png --out $T/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) $T/icon.png --out $T/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns $T/AppIcon.iconset -o AppIcon.icns
fi
cp AppIcon.icns $APP/Contents/Resources/
# macOS 14 = LSMinimumSystemVersion below; also makes the compiler reject newer APIs.
swiftc -O -swift-version 5 -target arm64-apple-macos14 focusMonitor.swift -o $APP/Contents/MacOS/focusMonitor
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.focusMonitor</string>
  <key>CFBundleName</key><string>focusMonitor</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>focusMonitor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>$(git describe --always --dirty 2>/dev/null || echo dev)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSCameraUsageDescription</key><string>Tracks which monitor you are facing to focus its window. Video never leaves your Mac.</string>
</dict></plist>
PLIST
# Stable identity from ./make-cert.sh if present (permissions survive rebuilds), else ad-hoc.
ID="focusMonitor Self-Signed"
security find-identity -p codesigning | grep -q "$ID" || ID=-
codesign --force --sign "${SIGN_ID:-$ID}" $APP
