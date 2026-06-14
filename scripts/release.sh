#!/usr/bin/env bash
#
# release.sh — build a signed, notarized, stapled Shelf.dmg for distribution.
#
# One-time setup (stores your Apple ID app-specific password in the keychain):
#
#   xcrun notarytool store-credentials shelf-notary \
#     --apple-id "<your-apple-id-email>" \
#     --team-id "9A7P6U2W76" \
#     --password "<app-specific-password>"
#
#   Create the app-specific password at https://appleid.apple.com
#   (Sign-In and Security → App-Specific Passwords).
#
# Then just run:  ./scripts/release.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="Shelf"
APP_NAME="Shelf"
TEAM_ID="9A7P6U2W76"
NOTARY_PROFILE="shelf-notary"
BUILD_DIR="build"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
APP_PATH="${EXPORT_DIR}/${APP_NAME}.app"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_NAME}/Info.plist")
DMG_PATH="${BUILD_DIR}/${APP_NAME}-${VERSION}.dmg"

echo "==> Releasing ${APP_NAME} ${VERSION}"

# --- Preflight: notarization credentials ---------------------------------
if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
  cat <<EOF

ERROR: notarytool profile "${NOTARY_PROFILE}" not found.

Run this once (see header of this script for details):

  xcrun notarytool store-credentials ${NOTARY_PROFILE} \\
    --apple-id "<your-apple-id-email>" \\
    --team-id "${TEAM_ID}" \\
    --password "<app-specific-password from appleid.apple.com>"

EOF
  exit 1
fi

# --- Clean & generate ----------------------------------------------------
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
xcodegen generate

# --- Archive (signed, hardened runtime) ----------------------------------
echo "==> Archiving"
xcodebuild archive \
  -scheme "${SCHEME}" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "${ARCHIVE_PATH}" \
  -skipPackagePluginValidation

# --- Export (Developer ID) -----------------------------------------------
echo "==> Exporting"
xcodebuild -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${EXPORT_DIR}" \
  -exportOptionsPlist scripts/ExportOptions.plist

# --- Verify signature ----------------------------------------------------
echo "==> Verifying code signature"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

# --- Notarize & staple the app -------------------------------------------
# Staple the .app itself (not just the DMG) so it passes Gatekeeper offline
# even after a user drags it out of the DMG. notarytool needs a container,
# so submit a zip of the app, then staple the original .app in place.
echo "==> Notarizing app (this can take a few minutes; first run is slow)"
APP_ZIP="${BUILD_DIR}/${APP_NAME}.zip"
/usr/bin/ditto -c -k --keepParent "${APP_PATH}" "${APP_ZIP}"
xcrun notarytool submit "${APP_ZIP}" \
  --keychain-profile "${NOTARY_PROFILE}" \
  --wait
echo "==> Stapling app"
xcrun stapler staple "${APP_PATH}"
xcrun stapler validate "${APP_PATH}"
rm -f "${APP_ZIP}"

# --- Build DMG (around the stapled app) ----------------------------------
echo "==> Building DMG"
rm -f "${DMG_PATH}"
create-dmg \
  --volname "${APP_NAME}" \
  --window-size 540 380 \
  --icon-size 110 \
  --icon "${APP_NAME}.app" 150 180 \
  --app-drop-link 390 180 \
  --no-internet-enable \
  "${DMG_PATH}" \
  "${APP_PATH}"

# --- Notarize & staple the DMG -------------------------------------------
# Also notarize the DMG itself so the downloaded disk image is trusted.
echo "==> Notarizing DMG"
xcrun notarytool submit "${DMG_PATH}" \
  --keychain-profile "${NOTARY_PROFILE}" \
  --wait
echo "==> Stapling DMG"
xcrun stapler staple "${DMG_PATH}"
xcrun stapler validate "${DMG_PATH}"

echo ""
echo "==> Verifying the packaged app passes Gatekeeper"
# Assess the app inside the DMG. (Don't spctl the DMG itself — the disk-image
# container isn't code-signed, so it always reports "no usable signature"
# even when correctly notarized + stapled.)
MOUNT_POINT=$(hdiutil attach "${DMG_PATH}" -nobrowse -readonly | grep '/Volumes/' | awk -F'\t' '{print $NF}')
spctl --assess --type execute --verbose=2 "${MOUNT_POINT}/${APP_NAME}.app" || true
hdiutil detach "${MOUNT_POINT}" >/dev/null 2>&1 || true

echo ""
echo "==> Done: ${DMG_PATH}"
