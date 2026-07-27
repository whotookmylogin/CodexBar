#!/usr/bin/env bash
set -euo pipefail
CONF=${1:-release}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

ARCH=${ARCH:-x86_64}
swift build -c "$CONF" --arch "$ARCH"

APP="$ROOT/CodexBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Convert new .icon bundle to .icns if present (macOS 14+/IconStudio export)
ICON_SOURCE="$ROOT/Icon.icon"
ICON_TARGET="$ROOT/Icon.icns"
if [[ -f "$ICON_SOURCE" ]]; then
  iconutil --convert icns --output "$ICON_TARGET" "$ICON_SOURCE"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>CodexBar</string>
    <key>CFBundleDisplayName</key><string>CodexBar</string>
    <key>CFBundleIdentifier</key><string>com.steipete.codexbar</string>
    <key>CFBundleExecutable</key><string>CodexBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.4</string>
    <key>CFBundleVersion</key><string>6</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>CFBundleIconFile</key><string>Icon</string>
    <key>NSHumanReadableCopyright</key><string>© 2025-2026 Peter Steinberger / macOS13 fork. MIT License.</string>
</dict>
</plist>
PLIST

cp ".build/$ARCH-apple-macosx/$CONF/CodexBar" "$APP/Contents/MacOS/CodexBar"
chmod +x "$APP/Contents/MacOS/CodexBar"

if [[ -f "$ICON_TARGET" ]]; then
  cp "$ICON_TARGET" "$APP/Contents/Resources/Icon.icns"
fi

echo "Created $APP"
