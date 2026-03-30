#!/bin/bash
# build_dmg.sh — Archive, codesign, and package ollmlx into a DMG.
# Requires: Xcode, create-dmg, Apple Developer ID certificate.
#
# Usage: bash Scripts/build_dmg.sh
#
# Notarisation requires a keychain profile named "ollmlx".
# Create it once with:
#   xcrun notarytool store-credentials "ollmlx" --apple-id <email> --team-id M4RUJ7W6MP

set -euo pipefail

SCHEME="OllmlxApp"
ARCHIVE_PATH="build/ollmlx.xcarchive"
EXPORT_PATH="build/export"

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

# 1. Build CLI binary (needed by Copy Files phase in Xcode archive)
echo "[1/7] Building CLI..."
swift build -c release --product ollmlx 2>&1 | tail -5
CLI_BIN="$(swift build -c release --product ollmlx --show-bin-path)/ollmlx"
echo "CLI binary: ${CLI_BIN}"

# 2. Clean previous build artifacts
echo "[2/7] Cleaning previous build..."
rm -rf "${ARCHIVE_PATH}" "${EXPORT_PATH}" "${OUTPUT_DIR}/${DMG_NAME}"
mkdir -p "${OUTPUT_DIR}"

# 3. Archive menubar app (includes CLI via Copy Files build phase)
echo "[3/7] Archiving app..."
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

# 4. Export
echo "[4/7] Exporting signed app..."

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

# 5. Stage only the .app for DMG (exclude Xcode export metadata)
echo "[5/7] Staging app for DMG..."
APP_PATH="${EXPORT_PATH}/ollmlx.app"
STAGING_DIR="${OUTPUT_DIR}/staging"
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"
cp -R "${APP_PATH}" "${STAGING_DIR}/"

# Install create-dmg if needed
if ! command -v create-dmg &>/dev/null; then
    echo "Installing create-dmg via Homebrew..."
    brew install create-dmg
fi

# 6. Create DMG
echo "[6/7] Creating DMG..."
create-dmg \
    --volname "ollmlx" \
    --window-size 540 380 \
    --icon-size 128 \
    --icon "ollmlx.app" 160 190 \
    --hide-extension "ollmlx.app" \
    --app-drop-link 380 190 \
    "${OUTPUT_DIR}/${DMG_NAME}" \
    "${STAGING_DIR}/" \
    || {
        # create-dmg exits non-zero if icon positioning fails but DMG is still created
        # Fall back to simpler hdiutil approach
        echo "create-dmg styling failed — creating basic DMG with hdiutil..."
        hdiutil create -volname "ollmlx" -srcfolder "${STAGING_DIR}" \
            -ov -format UDZO "${OUTPUT_DIR}/${DMG_NAME}"
    }

# 7. Notarise and staple the DMG
echo "[7/7] Notarising DMG..."
xcrun notarytool submit "${OUTPUT_DIR}/${DMG_NAME}" \
    --keychain-profile "ollmlx" \
    --wait

xcrun stapler staple "${OUTPUT_DIR}/${DMG_NAME}"

echo ""
echo "=== Build complete ==="
echo "DMG: ${OUTPUT_DIR}/${DMG_NAME}"
echo ""
echo "Next steps:"
echo "  1. Upload DMG to GitHub release"
echo "  2. Generate appcast.xml with Sparkle's generate_appcast tool"
echo "  3. Upload appcast.xml to the release"
