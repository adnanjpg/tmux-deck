#!/bin/bash
# Builds Tmux Deck.app and installs it in ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP="build/Tmux Deck.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TmuxDeck "$APP/Contents/MacOS/TmuxDeck"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Tmux Deck</string>
  <key>CFBundleDisplayName</key><string>Tmux Deck</string>
  <key>CFBundleIdentifier</key><string>io.github.tmuxdeck</string>
  <key>CFBundleExecutable</key><string>TmuxDeck</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
mkdir -p ~/Applications
rm -rf ~/Applications/"Tmux Deck.app"
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/Tmux Deck.app"
