#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/.build/debug/RepoBar.app}"
# Default identity comes from CODE_SIGN_IDENTITY or env override.
DEFAULT_IDENTITY="${CODE_SIGN_IDENTITY:-${CODESIGN_IDENTITY:-}}"
IDENTITY="${2:-${CODESIGN_IDENTITY:-$DEFAULT_IDENTITY}}"

log() { printf '%s\n' "[$(date '+%H:%M:%S')] $*"; }

# Load signing defaults from Config/Local.xcconfig if present (xcconfig syntax)
if [ -f "${ROOT_DIR}/Config/Local.xcconfig" ]; then
  while IFS='=' read -r rawKey rawValue; do
    key="$(printf '%s' "$rawKey" | sed 's,//.*$,,' | xargs)"
    value="$(printf '%s' "$rawValue" | sed 's,//.*$,,' | xargs)"
    case "$key" in
      DEVELOPMENT_TEAM) DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-$value}" ;;
    esac
  done < <(grep -v '^[[:space:]]*//' "${ROOT_DIR}/Config/Local.xcconfig")
fi

if [ -z "$IDENTITY" ]; then
  log "No signing identity provided; skipping codesign for $APP_PATH"
  exit 0
fi
ENTITLEMENTS="$ROOT_DIR/RepoBar.entitlements"
TMP_ENTITLEMENTS="/tmp/RepoBar_entitlements.plist"

if [ ! -d "$APP_PATH" ]; then
  log "App bundle not found: $APP_PATH"
  exit 1
fi

extract_team_id() {
  local identity="$1"
  if [[ "$identity" =~ \\(([A-Z0-9]{10})\\)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# Prepare entitlements (enable hardened runtime, Sparkle XPC exceptions)
if [ -f "$ENTITLEMENTS" ]; then
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo 'com.steipete.repobar')"
  team_id="${DEVELOPMENT_TEAM:-}"
  if [ -z "$team_id" ]; then
    team_id="$(extract_team_id "$IDENTITY" || true)"
  fi
  app_id_prefix=""
  if [ -n "$team_id" ]; then
    app_id_prefix="${team_id}."
  fi
  sed -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/${bundle_id}/g" \
    -e "s/\$(AppIdentifierPrefix)/${app_id_prefix}/g" \
    "$ENTITLEMENTS" > "$TMP_ENTITLEMENTS"
  if [ "${REPOBAR_SKIP_KEYCHAIN_GROUPS:-0}" -eq 1 ]; then
    /usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" "$TMP_ENTITLEMENTS" >/dev/null 2>&1 || true
    log "Stripped keychain access groups (no provisioning profile)"
  fi
else
  cat > "$TMP_ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.hardened-runtime</key>
    <true/>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
    <key>com.apple.security.temporary-exception.mach-lookup.global-name</key>
    <array>
        <string>com.steipete.repobar-spks</string>
        <string>com.steipete.repobar-spkd</string>
    </array>
</dict>
</plist>
PLIST
fi

if [ "${REPOBAR_DEBUG_SIGNING:-0}" -eq 1 ]; then
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.get-task-allow bool true" "$TMP_ENTITLEMENTS" >/dev/null 2>&1 ||
    /usr/libexec/PlistBuddy -c "Set :com.apple.security.get-task-allow true" "$TMP_ENTITLEMENTS" >/dev/null 2>&1 || true
  log "Enabled get-task-allow for LLDB attach"
fi

log "Signing frameworks (if any)"
find "$APP_PATH/Contents/Frameworks" \( -type d -name '*.framework' -o -type f -name '*.dylib' \) 2>/dev/null | while read -r fw; do
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$fw"
done

SPARKLE_FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_FRAMEWORK" ]; then
  log "Signing Sparkle components"
  sign_sparkle() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$1"; }
  SPARKLE_VERSION="$SPARKLE_FRAMEWORK/Versions/B"
  for path in \
    "$SPARKLE_VERSION/Sparkle" \
    "$SPARKLE_VERSION/Autoupdate" \
    "$SPARKLE_VERSION/Updater.app/Contents/MacOS/Updater" \
    "$SPARKLE_VERSION/Updater.app" \
    "$SPARKLE_VERSION/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
    "$SPARKLE_VERSION/XPCServices/Downloader.xpc" \
    "$SPARKLE_VERSION/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
    "$SPARKLE_VERSION/XPCServices/Installer.xpc" \
    "$SPARKLE_VERSION" \
    "$SPARKLE_FRAMEWORK"
  do
    if [ -e "$path" ]; then
      sign_sparkle "$path"
    fi
  done
fi

log "Signing auxiliary binaries"
for bin in "$APP_PATH/Contents/MacOS/"*; do
  if [ -f "$bin" ] && [ "$bin" != "$APP_PATH/Contents/MacOS/RepoBar" ]; then
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$bin"
  fi
done

# Sign nested binaries before the main executable; otherwise codesign can fail with
# “code object is not signed at all” when it encounters an unsigned subcomponent
# (e.g. `repobarcli`) while sealing the bundle.
log "Signing main binary"
codesign --force --options runtime --timestamp --entitlements "$TMP_ENTITLEMENTS" --sign "$IDENTITY" "$APP_PATH/Contents/MacOS/RepoBar"

log "Signing app bundle"
codesign --force --options runtime --timestamp --entitlements "$TMP_ENTITLEMENTS" --sign "$IDENTITY" "$APP_PATH"

log "Verifying"
codesign --verify --verbose=2 "$APP_PATH"

rm -f "$TMP_ENTITLEMENTS"
log "Done codesigning $APP_PATH"
