#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Headroom"
BUNDLE_DIR="$ROOT_DIR/dist/${APP_NAME}.app"
CONTENTS_DIR="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

echo "Building release binaries..."
cd "$ROOT_DIR"
swift build -c release ${HEADROOM_SWIFT_BUILD_FLAGS:-}

rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS_DIR"

cp "$ROOT_DIR/.build/release/HeadroomApp" "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/.build/release/headroom" "$MACOS_DIR/headroom"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Headroom</string>
    <key>CFBundleIdentifier</key>
    <string>com.headroom.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Headroom</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.4.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$BUNDLE_DIR" >/dev/null 2>&1 || true
fi

echo "Created native app bundle at: $BUNDLE_DIR"
echo "Run with: open \"$BUNDLE_DIR\""
