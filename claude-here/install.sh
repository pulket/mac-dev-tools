#!/bin/zsh
# Builds ClaudeHere.app into ~/Applications and starts it at every login.
set -e
cd "$(dirname "$0")"
APP="$HOME/Applications/ClaudeHere.app"
LABEL="com.local.claudehere"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x ClaudeHere 2>/dev/null || true

# Remember how the previous build was signed (permissions survive rebuilds only with a stable certificate).
OLD_SIG="$(codesign -dv "$APP" 2>&1 | grep -m1 -E '^Authority=|Signature=adhoc' || true)"

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
# Sign with your Apple Development certificate if you have one (so macOS permissions survive rebuilds),
# otherwise ad-hoc. Override with: CODESIGN_IDENTITY="..." zsh install.sh
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 '"Apple Development' | sed -E 's/.*"(.*)"/\1/')}"
if [ -n "$IDENTITY" ]; then
  echo "Signing with: $IDENTITY (macOS may ask for your login password once — choose Always Allow)"
  codesign --force --sign "$IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
NEW_SIG="$(codesign -dv "$APP" 2>&1 | grep -m1 -E '^Authority=|Signature=adhoc' || true)"

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
# Ad-hoc builds get a new identity every time, so stale permission entries must be cleared.
# With a certificate, permissions carry over — unless the signing identity just changed.
if [[ "$NEW_SIG" == *adhoc* || "$NEW_SIG" != "$OLD_SIG" ]]; then
  for svc in Accessibility ListenEvent ScreenCapture; do tccutil reset $svc "$LABEL" >/dev/null 2>&1 || true; done
  MSG="Grant Input Monitoring + Accessibility when asked (Screen Recording on first screenshot)."
else
  MSG="Permissions kept from the previous build."
fi
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "ClaudeHere installed and running. $MSG"
