#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIGURATION="${1:-release}"
APP_NAME="Codex Limit.app"
APP_DIR="${PROJECT_DIR}/dist/${APP_NAME}"

cd "${PROJECT_DIR}"
swift build --configuration "${CONFIGURATION}"
BIN_DIR="$(swift build --configuration "${CONFIGURATION}" --show-bin-path)"

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"

cp "${PROJECT_DIR}/packaging/Info.plist" "${APP_DIR}/Contents/Info.plist"
cp "${BIN_DIR}/CodexLimitMenuBar" "${APP_DIR}/Contents/MacOS/CodexLimitMenuBar"
chmod +x "${APP_DIR}/Contents/MacOS/CodexLimitMenuBar"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "${APP_DIR}"
fi

echo "Built ${APP_DIR}"
