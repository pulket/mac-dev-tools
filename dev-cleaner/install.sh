#!/bin/zsh
# Builds DevCleaner.app into ~/Applications and opens it (it adds itself to Login Items).
set -e
cd "$(dirname "$0")"
APP="$HOME/Applications/DevCleaner.app"

pkill -x DevCleaner 2>/dev/null || true
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 DevCleaner.swift -o "$APP/Contents/MacOS/DevCleaner"

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
  <key>CFBundleIdentifier</key><string>com.local.devcleaner</string>
  <key>CFBundleName</key><string>DevCleaner</string>
  <key>CFBundleExecutable</key><string>DevCleaner</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --sign - "$APP"
touch "$APP"
open "$APP"
echo "DevCleaner is running — look for the ✨ bubbles icon in your menu bar."
