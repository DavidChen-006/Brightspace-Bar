#!/usr/bin/env bash
set -euo pipefail

# Notarizes a pre-signed app bundle using Apple's notarytool.
# Usage: Scripts/notarize_app.sh path/to/RepoBar.app [profile]
#
# - profile: optional notarytool keychain profile (defaults to NOTARY_PROFILE env or "Xcode Notary")
# - Requires the app to be codesigned already and Info.plist in place.

APP_PATH="${1:-}"
PROFILE="${2:-${NOTARY_PROFILE:-Xcode Notary}}"

if [ -z "${APP_PATH}" ] || [ ! -d "${APP_PATH}" ]; then
  echo "Usage: $0 /path/to/RepoBar.app [profile]" >&2
  exit 1
fi

if ! command -v notarytool >/dev/null 2>&1; then
  echo "notarytool not found. Install Xcode CLTs 14+ or Xcode 15+." >&2
  exit 1
fi

TMPDIR="$(mktemp -d)"
ZIP_PATH="${TMPDIR}/repobar.zip"

echo "==> Zipping app"
/usr/bin/ditto -ck --keepParent "${APP_PATH}" "${ZIP_PATH}"

echo "==> Submitting to Apple Notary Service (profile: ${PROFILE})"
REQUEST_UUID=$(notarytool submit "${ZIP_PATH}" --keychain-profile "${PROFILE}" --wait --output-format json | /usr/bin/python3 -c "import sys,json;print(json.load(sys.stdin).get('id',''))")

if [ -z "${REQUEST_UUID}" ]; then
  echo "Notarization submission failed (no request UUID)." >&2
  exit 1
fi

echo "==> Stapling ticket"
/usr/bin/xcrun stapler staple "${APP_PATH}"

echo "==> Notarization complete: ${REQUEST_UUID}"
rm -rf "${TMPDIR}"
