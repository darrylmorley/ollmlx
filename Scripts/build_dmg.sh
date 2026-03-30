#!/bin/bash
# build_dmg.sh — Archive, codesign, and package ollmlx into a DMG.
# Requires: Xcode, create-dmg, Apple Developer ID certificate.
#
# Usage: bash Scripts/build_dmg.sh
#
# Replace YOUR_TEAM_ID and YOUR_DEVELOPER_ID with real values before use.

set -euo pipefail

SCHEME="OllmlxApp"
ARCHIVE_PATH="build/ollmlx.xcarchive"
EXPORT_PATH="build/export"
ENTITLEMENTS="ollmlx.entitlements"

# Read version from the Xcode project or Info.plist
VERSION=$(defaults read "$(pwd)/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "0.1.0")
DMG_NAME="ollmlx-${VERSION}.dmg"
OUTPUT_DIR="build"

TEAM_ID="${TEAM_ID:-M4RUJ7W6MP}"
DEVELOPER_ID="${DEVELOPER_ID:-Darryl Morley (M4RUJ7W6MP)}"

echo "=== ollmlx DMG build ==="
echo "Version: ${VERSION}"
echo "Output:  ${OUTPUT_DIR}/${DMG_NAME}"
echo ""

# 1. Clean previous build artifacts
echo "[1/6] Cleaning previous build..."
rm -rf "${ARCHIVE_PATH}" "${EXPORT_PATH}" "${OUTPUT_DIR}/${DMG_NAME}"
mkdir -p "${OUTPUT_DIR}"

# 2. Archive
echo "[2/6] Archiving..."
xcodebuild -resolvePackageDependencies -scheme "${SCHEME}" 2>&1 | tail -3
xcodebuild archive \
    -scheme "${SCHEME}" \
    -archivePath "${ARCHIVE_PATH}" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="Developer ID Application: ${DEVELOPER_ID}" \
    DEVELOPMENT_TEAM="${TEAM_ID}" \
    CODE_SIGN_STYLE=Manual \
    OTHER_CODE_SIGN_FLAGS="--options=runtime" \
    | tail -10

echo "Archive complete."

# 3. Export
echo "[3/6] Exporting signed app..."

# Create export options plist
cat > "${OUTPUT_DIR}/export_options.plist" <<'EXPORTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
</dict>
</plist>
EXPORTEOF

xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportOptionsPlist "${OUTPUT_DIR}/export_options.plist" \
    -exportPath "${EXPORT_PATH}" \
    | tail -5

echo "Export complete."

# 4. Notarise
echo "[4/6] Notarising..."
APP_PATH="${EXPORT_PATH}/OllmlxApp.app"

if [ -d "${APP_PATH}" ]; then
    xcrun notarytool submit "${APP_PATH}" \
        --team-id "${TEAM_ID}" \
        --wait \
        || echo "WARNING: Notarisation failed or skipped. Set TEAM_ID and credentials."

    xcrun stapler staple "${APP_PATH}" \
        || echo "WARNING: Stapling failed."
else
    echo "WARNING: App not found at ${APP_PATH} — skipping notarisation."
fi

# 5. Install create-dmg if needed
echo "[5/6] Preparing DMG tool..."
if ! command -v create-dmg &>/dev/null; then
    echo "Installing create-dmg via Homebrew..."
    brew install create-dmg
fi

# 6. Create DMG
echo "[6/6] Creating DMG..."
create-dmg \
    --volname "ollmlx" \
    --volicon "${APP_PATH}/Contents/Resources/AppIcon.icns" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "OllmlxApp.app" 150 190 \
    --app-drop-link 450 190 \
    --no-internet-enable \
    "${OUTPUT_DIR}/${DMG_NAME}" \
    "${EXPORT_PATH}/" \
    || {
        # create-dmg exits non-zero if icon positioning fails but DMG is still created
        # Fall back to simpler hdiutil approach
        echo "create-dmg styling failed — creating basic DMG with hdiutil..."
        hdiutil create -volname "ollmlx" -srcfolder "${EXPORT_PATH}" \
            -ov -format UDZO "${OUTPUT_DIR}/${DMG_NAME}"
    }

echo ""
echo "=== Build complete ==="
echo "DMG: ${OUTPUT_DIR}/${DMG_NAME}"
echo ""
echo "Next steps:"
echo "  1. Upload DMG to GitHub release"
echo "  2. Generate appcast.xml with Sparkle's generate_appcast tool"
echo "  3. Upload appcast.xml to the release"
