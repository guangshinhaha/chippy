#!/bin/bash
# Build build/Chippy.app (menu-bar agent, no Dock icon) with chippy-hook inside.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/Chippy.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Chippy "$APP/Contents/MacOS/Chippy"
cp .build/release/chippy-hook "$APP/Contents/MacOS/chippy-hook"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>sg.gov.tech.grl.chippy</string>
<key>CFBundleName</key><string>Chippy</string>
<key>CFBundleExecutable</key><string>Chippy</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "built $APP"
