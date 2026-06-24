#!/usr/bin/env bash
# Builds ClaudeBar and assembles a standalone ClaudeBar.app bundle.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Building (release)..."
swift build -c release

BIN=".build/release/ClaudeBar"
APP="ClaudeBar.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

echo "==> Assembling $APP..."
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
cp "$BIN" "$MACOS/ClaudeBar"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>ClaudeBar</string>
    <key>CFBundleDisplayName</key>     <string>ClaudeBar</string>
    <key>CFBundleIdentifier</key>      <string>app.claudebar.menubar</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleExecutable</key>      <string>ClaudeBar</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <!-- Menu-bar agent: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key>             <true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so launch-at-login (SMAppService) and Gatekeeper are happy locally.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "==> Done: $(pwd)/$APP"
echo "    Launch:  open $APP"
echo "    Install: cp -r $APP /Applications/"
