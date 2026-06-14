#!/usr/bin/env bash
#
# release.sh — build a signed, notarized, stapled Shelf.dmg for distribution.
#
# One-time setup:
#
#   1. Create your local release config (holds your Team ID + profile name):
#        cp scripts/release.config.sh.example scripts/release.config.sh
#        # then edit scripts/release.config.sh
#
#   2. Store your Apple ID app-specific password in the keychain:
#        xcrun notarytool store-credentials "<profile>" \
#          --apple-id "<your-apple-id-email>" \
#          --team-id "<your-team-id>" \
#          --password "<app-specific-password>"
#      Create the app-specific password at https://appleid.apple.com
#      (Sign-In and Security → App-Specific Passwords).
#
# Then just run:  ./scripts/release.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."

# --- Maintainer-specific config (gitignored) -----------------------------
# TEAM_ID and NOTARY_PROFILE come from scripts/release.config.sh (or the
# environment) so no personal identifiers live in the committed repo.
if [ -f scripts/release.config.sh ]; then
  # shellcheck source=/dev/null
  source scripts/release.config.sh
fi
: "${TEAM_ID:?TEAM_ID is unset — copy scripts/release.config.sh.example to scripts/release.config.sh and fill it in}"
NOTARY_PROFILE="${NOTARY_PROFILE:-shelf-notary}"

SCHEME="Shelf"
APP_NAME="Shelf"
BUILD_DIR="build"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
APP_PATH="${EXPORT_DIR}/${APP_NAME}.app"
EXPORT_OPTIONS="${BUILD_DIR}/ExportOptions.plist"

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

(see scripts/release.config.sh.example for full setup)

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
  -skipPackagePluginValidation \
  DEVELOPMENT_TEAM="${TEAM_ID}"

# --- Export (Developer ID) -----------------------------------------------
# Generate the export options with the configured Team ID (kept out of the repo).
cat > "${EXPORT_OPTIONS}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>${TEAM_ID}</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>Developer ID Application</string>
</dict>
</plist>
EOF

echo "==> Exporting"
xcodebuild -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${EXPORT_DIR}" \
  -exportOptionsPlist "${EXPORT_OPTIONS}"

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
