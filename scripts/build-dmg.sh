#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${PROJECT_DIR}/dist"
APP_NAME="Codex Limit.app"
APP_DIR="${DIST_DIR}/${APP_NAME}"

"${SCRIPT_DIR}/build-app.sh" release
codesign --verify --deep --strict "${APP_DIR}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_DIR}/Contents/Info.plist")"
ARCHITECTURES="$(lipo -archs "${APP_DIR}/Contents/MacOS/CodexLimitMenuBar")"
case "${ARCHITECTURES}" in
    arm64|x86_64) ARCH_LABEL="${ARCHITECTURES}" ;;
    *) ARCH_LABEL="universal" ;;
esac
DMG_NAME="Codex-Limit-${VERSION}-macOS-${ARCH_LABEL}.dmg"
STAGING_DIR="$(mktemp -d "${DIST_DIR}/dmg-stage.XXXXXX")"
trap 'rm -rf "${STAGING_DIR}"' EXIT

ditto "${APP_DIR}" "${STAGING_DIR}/${APP_NAME}"
ln -s /Applications "${STAGING_DIR}/Applications"

hdiutil create -volname "Codex Limit ${VERSION}" -srcfolder "${STAGING_DIR}" \
    -format UDZO -ov "${DIST_DIR}/${DMG_NAME}"
hdiutil verify "${DIST_DIR}/${DMG_NAME}"
(
    cd "${DIST_DIR}"
    shasum -a 256 "${DMG_NAME}" > "${DMG_NAME}.sha256"
)

echo "Built ${DIST_DIR}/${DMG_NAME}"
