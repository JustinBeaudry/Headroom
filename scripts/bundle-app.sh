#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Headroom"
VERSION="${HEADROOM_VERSION:-$(tr -d '[:space:]' < "$ROOT_DIR/VERSION" 2>/dev/null || echo "0.4.0")}"
BUILD_NUMBER="${HEADROOM_BUILD_NUMBER:-1}"
DIST_DIR="$ROOT_DIR/dist"
BUNDLE_DIR="$DIST_DIR/${APP_NAME}.app"
CONTENTS_DIR="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_SRC="$ROOT_DIR/Assets/AppIcon.png"
ENTITLEMENTS_PATH="$ROOT_DIR/Config/Headroom.entitlements"
SIGN_IDENTITY="${HEADROOM_SIGN_IDENTITY:-}"

echo "Building ${APP_NAME} v${VERSION} (build ${BUILD_NUMBER})..."
cd "$ROOT_DIR"
swift build -c release ${HEADROOM_SWIFT_BUILD_FLAGS:-}

rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$ROOT_DIR/.build/release/HeadroomApp" "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/.build/release/headroom" "$MACOS_DIR/headroom"

# Generate native macOS AppIcon.icns from Assets/AppIcon.png if available
ICON_PLIST_ENTRY=""
if [ -f "$ICON_SRC" ] && command -v sips >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    ICON_TMP="$(mktemp -d /tmp/headroom-icon.XXXXXX)"
    for size in 16 32 64 128 256 512 1024; do
        sips -s format png -z "$size" "$size" "$ICON_SRC" --out "$ICON_TMP/${size}.png" >/dev/null
    done
    python3 - "$ICON_TMP" "$RESOURCES_DIR/AppIcon.icns" <<'PY'
import os, struct, sys

src_dir, out_path = sys.argv[1], sys.argv[2]
chunks = [
    (b"icp4", "16.png"),
    (b"icp5", "32.png"),
    (b"icp6", "64.png"),
    (b"ic07", "128.png"),
    (b"ic08", "256.png"),
    (b"ic09", "512.png"),
    (b"ic10", "1024.png"),
    (b"ic11", "32.png"),
    (b"ic12", "64.png"),
    (b"ic13", "256.png"),
    (b"ic14", "512.png"),
]
body = bytearray()
for ostype, filename in chunks:
    with open(os.path.join(src_dir, filename), "rb") as f:
        data = f.read()
    body += ostype + struct.pack(">I", len(data) + 8) + data

with open(out_path, "wb") as f:
    f.write(b"icns" + struct.pack(">I", len(body) + 8) + body)
PY
    rm -rf "$ICON_TMP"
    ICON_PLIST_ENTRY="    <key>CFBundleIconFile</key>
    <string>AppIcon</string>"
    echo "Embedded native AppIcon.icns"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Headroom</string>
${ICON_PLIST_ENTRY}
    <key>CFBundleIdentifier</key>
    <string>com.headroom.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Headroom</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

# Sign binaries: Developer ID Application (Hardened Runtime + timestamp) if configured, else ad-hoc.
if command -v codesign >/dev/null 2>&1; then
    if [ -n "$SIGN_IDENTITY" ]; then
        echo "Signing with Developer ID: $SIGN_IDENTITY"
        SIGN_FLAGS=(--force --options runtime --timestamp --sign "$SIGN_IDENTITY")
        if [ -f "$ENTITLEMENTS_PATH" ]; then
            SIGN_FLAGS+=(--entitlements "$ENTITLEMENTS_PATH")
        fi
        # Sign embedded CLI helper first, then the outer app bundle (inside-out)
        codesign "${SIGN_FLAGS[@]}" "$MACOS_DIR/headroom"
        codesign "${SIGN_FLAGS[@]}" "$BUNDLE_DIR"
        codesign --verify --deep --strict --verbose=2 "$BUNDLE_DIR"
        echo "Verified Developer ID code signature"
    else
        codesign --force --deep --sign - "$BUNDLE_DIR" >/dev/null 2>&1 || true
        echo "Signed ad-hoc (set HEADROOM_SIGN_IDENTITY for Developer ID signing)"
    fi
fi

echo "Created native app bundle at: $BUNDLE_DIR"

submit_for_notarization() {
    local artifact="$1"
    if [ -n "${HEADROOM_NOTARY_PROFILE:-}" ]; then
        xcrun notarytool submit "$artifact" --keychain-profile "$HEADROOM_NOTARY_PROFILE" --wait
    elif [ -n "${APPLE_API_KEY_PATH:-}" ] && [ -n "${APPLE_API_KEY_ID:-}" ] && [ -n "${APPLE_API_ISSUER_ID:-}" ]; then
        xcrun notarytool submit "$artifact" \
            --key "$APPLE_API_KEY_PATH" \
            --key-id "$APPLE_API_KEY_ID" \
            --issuer "$APPLE_API_ISSUER_ID" \
            --wait
    elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]; then
        xcrun notarytool submit "$artifact" \
            --apple-id "$APPLE_ID" \
            --team-id "$APPLE_TEAM_ID" \
            --password "$APPLE_APP_SPECIFIC_PASSWORD" \
            --wait
    else
        echo "Skipping notarization: no notarytool credentials configured"
        return 1
    fi
}

if [ "${HEADROOM_CREATE_ARCHIVES:-0}" = "1" ]; then
    ARCH="$(uname -m)"
    ZIP_PATH="$DIST_DIR/${APP_NAME}-v${VERSION}-macos-${ARCH}.zip"
    CLI_TAR_PATH="$DIST_DIR/headroom-cli-v${VERSION}-macos-${ARCH}.tar.gz"
    DMG_PATH="$DIST_DIR/${APP_NAME}-v${VERSION}-macos-${ARCH}.dmg"

    echo "Packaging release archives..."
    rm -f "$ZIP_PATH" "$CLI_TAR_PATH" "$DMG_PATH"
    ditto -c -k --sequesterRsrc --keepParent "$BUNDLE_DIR" "$ZIP_PATH"

    # Notarize & staple Headroom.app if Developer ID signing + notarization are enabled
    if [ "${HEADROOM_NOTARIZE:-0}" = "1" ] && [ -n "$SIGN_IDENTITY" ]; then
        echo "Submitting ${APP_NAME}.app for Apple notarization..."
        if submit_for_notarization "$ZIP_PATH"; then
            xcrun stapler staple "$BUNDLE_DIR"
            xcrun stapler validate "$BUNDLE_DIR"
            # Re-pack .zip from the stapled .app bundle
            rm -f "$ZIP_PATH"
            ditto -c -k --sequesterRsrc --keepParent "$BUNDLE_DIR" "$ZIP_PATH"
            echo "Stapled notarization ticket to ${APP_NAME}.app"
        fi
    fi

    # Package signed CLI binary (use the signed binary inside the app bundle)
    tar -czf "$CLI_TAR_PATH" -C "$MACOS_DIR" headroom

    if command -v hdiutil >/dev/null 2>&1; then
        DMG_STAGING="$(mktemp -d /tmp/headroom-dmg.XXXXXX)"
        cp -R "$BUNDLE_DIR" "$DMG_STAGING/"
        ln -s /Applications "$DMG_STAGING/Applications"
        if hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null; then
            if [ -n "$SIGN_IDENTITY" ]; then
                codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
                if [ "${HEADROOM_NOTARIZE:-0}" = "1" ]; then
                    echo "Submitting DMG for Apple notarization..."
                    if submit_for_notarization "$DMG_PATH"; then
                        xcrun stapler staple "$DMG_PATH"
                        xcrun stapler validate "$DMG_PATH"
                        echo "Stapled notarization ticket to DMG"
                    fi
                fi
            fi
        else
            echo "Skipping DMG creation in restricted environment"
        fi
        rm -rf "$DMG_STAGING"
    fi

    (
        cd "$DIST_DIR"
        shasum -a 256 "${APP_NAME}-v${VERSION}-macos-${ARCH}.zip" \
            "headroom-cli-v${VERSION}-macos-${ARCH}.tar.gz" \
            $( [ -f "$DMG_PATH" ] && echo "${APP_NAME}-v${VERSION}-macos-${ARCH}.dmg" ) \
            > SHA256SUMS.txt
    )
    echo "Release archives ready in $DIST_DIR"
fi
