#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

BUNDLE_ID="com.steipete.repobar.ios"
DERIVED_DATA="${DERIVED_DATA:-$PWD/.build/ios-smoke-derived}"
SCREENSHOT="${SCREENSHOT:-/tmp/repobarios-smoke.png}"

udid="${SIMULATOR_UDID:-}"
if [[ -z "$udid" ]]; then
  udid="$(
    xcodebuild -project RepoBariOS.xcodeproj -scheme RepoBariOS -showdestinations 2>/dev/null \
      | sed -n 's/.*id:\([^,}]*\).*name:iPhone.*/\1/p' \
      | head -n 1
  )"
fi
if [[ -z "$udid" ]]; then
  echo "No Xcode-available iPhone simulator found." >&2
  exit 1
fi

xcrun simctl boot "$udid" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$udid" -b

xcodebuild \
  -project RepoBariOS.xcodeproj \
  -scheme RepoBariOS \
  -configuration Debug \
  -destination "id=$udid" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

app="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/RepoBariOS.app"
xcrun simctl install "$udid" "$app"
xcrun simctl launch "$udid" "$BUNDLE_ID"
xcrun simctl openurl "$udid" "repobar://resolve?text=openclaw/openclaw%2376162"
xcrun simctl io "$udid" screenshot "$SCREENSHOT"

echo "Smoke screenshot: $SCREENSHOT"
