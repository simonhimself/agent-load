#!/bin/zsh
# Builds "build/Agent Load.app" from the Swift package (Command Line Tools only, no Xcode).
#   scripts/build-app.sh
# Then run it with:  open "build/Agent Load.app"
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release --product AgentLoad
BIN="$(swift build -c release --show-bin-path)/AgentLoad"

APP="build/Agent Load.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AgentLoad"

# LSUIElement = menu bar only, no Dock icon.
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Agent Load</string>
    <key>CFBundleDisplayName</key><string>Agent Load</string>
    <key>CFBundleIdentifier</key><string>local.agentload</string>
    <key>CFBundleExecutable</key><string>AgentLoad</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature (no developer account needed; runs locally).
codesign -s - --force --timestamp=none "$APP"
echo "Built $APP"
