#!/bin/zsh
# Builds ClaudeHere.app into ~/Applications and starts it at every login.
set -e
cd "$(dirname "$0")"
APP="$HOME/Applications/ClaudeHere.app"
LABEL="com.local.claudehere"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

mkdir -p "$APP/Contents/MacOS" "$HOME/Library/LaunchAgents"
swiftc -O -swift-version 5 ClaudeHere.swift -o "$APP/Contents/MacOS/ClaudeHere"

# App icon (drawn by make-icon.swift, converted with built-in sips + iconutil)
ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICONSET" "$APP/Contents/Resources"
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
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>ClaudeHere</string>
  <key>CFBundleExecutable</key><string>ClaudeHere</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>ClaudeHere reads the selected Finder folder and opens Claude in Terminal.</string>
</dict></plist>
EOF
codesign --force --sign - "$APP"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/ClaudeHere</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
EOF
touch "$APP"   # refresh Finder's icon cache
# A rebuilt app has a new signature, so old permission entries no longer match it.
tccutil reset Accessibility "$LABEL" >/dev/null 2>&1 || true
tccutil reset ListenEvent "$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "ClaudeHere installed and running. Grant Input Monitoring + Accessibility when asked."
