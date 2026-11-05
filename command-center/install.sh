#!/bin/zsh
# Builds Command Center (apps + T7 drive + iPhone Bridge + dev-cache cleaner, one menu-bar icon)
# into ~/Applications and opens it. It adds itself to Login Items.
set -e
cd "$(dirname "$0")"
REPO="$(cd .. && pwd)"
APP="$HOME/Applications/CommandCenter.app"

# Replace the older standalone apps (moved to the Trash, so they're recoverable)
for old in T7Helper iPhoneBridge DevCleaner; do
  pkill -x "$old" 2>/dev/null || true
  if [ -d "$HOME/Applications/$old.app" ]; then
    mv "$HOME/Applications/$old.app" "$HOME/.Trash/$old $(date +%H%M%S).app" && echo "Retired $old.app (moved to Trash)"
  fi
done
pkill -x CommandCenter 2>/dev/null || true
sleep 0.5

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 Shared.swift AppsSection.swift DriveSection.swift PhoneSection.swift CleanerSection.swift main.swift \
  -o "$APP/Contents/MacOS/CommandCenter"

ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICONSET"
swift make-icon.swift "$ICONSET/icon_512x512@2x.png" >/dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s*2)); [ $s -ne 512 ] && sips -z $d $d "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.local.commandcenter</string>
  <key>CFBundleName</key><string>Command Center</string>
  <key>CFBundleExecutable</key><string>CommandCenter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>2.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>RepoPath</key><string>$REPO</string>
  <key>NSAppleEventsUsageDescription</key><string>Command Center reads your Finder selection (to move/copy it to your drive) and opens Claude Code in Terminal.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Command Center lets your iPhone send and fetch your clipboard over Wi-Fi.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>Command Center moves and copies files to and from your external drive.</string>
</dict></plist>
PLIST

# Sign with your Apple Development certificate if available (permissions survive rebuilds), else ad-hoc.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 '"Apple Development' | sed -E 's/.*"(.*)"/\1/')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
touch "$APP"
open "$APP"
echo "Command Center is running — click its ⌘ icon in the menu bar, or press ⌃⌥Space."
