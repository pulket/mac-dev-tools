#!/bin/zsh
# Builds T7Helper.app into ~/Applications and opens it (it adds itself to Login Items).
set -e
cd "$(dirname "$0")"
APP="$HOME/Applications/T7Helper.app"

pkill -x T7Helper 2>/dev/null || true
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 T7Helper.swift -o "$APP/Contents/MacOS/T7Helper"

ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICONSET"
swift make-icon.swift "$ICONSET/icon_512x512@2x.png" >/dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s*2)); [ $s -ne 512 ] && sips -z $d $d "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.local.t7helper</string>
  <key>CFBundleName</key><string>T7Helper</string>
  <key>CFBundleExecutable</key><string>T7Helper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>T7 Helper reads which files you selected in Finder so it can move or copy them to your drive.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>T7 Helper moves and copies files to and from your external drive.</string>
</dict></plist>
EOF
codesign --force --sign - "$APP"
touch "$APP"
open "$APP"
echo "T7 Helper is running — look for the drive icon in your menu bar."
