#!/usr/bin/env bash
# Build BrightspaceBar, assemble a .app bundle, ad-hoc sign it, and launch it.
#
# `swift build` emits a bare Mach-O executable, which macOS will not treat as an
# app. The minimum viable bundle is three things: Contents/MacOS/<exe>,
# Contents/Info.plist, and an ad-hoc signature. RepoBar's equivalent runs ~255
# lines because it also handles Sparkle, notarization, provisioning profiles, and
# keychain groups — none of which a local menu-bar experiment needs.
#
# Usage:  ./Scripts/run.sh          build, bundle, launch
#         ./Scripts/run.sh --smoke  build, bundle, launch, verify alive, then kill
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP_NAME="BrightspaceBar"
CONFIG="${CONFIG:-debug}"
APP="${ROOT_DIR}/.build/${CONFIG}/${APP_NAME}.app"
EXE="${ROOT_DIR}/.build/${CONFIG}/${APP_NAME}"
# Anchored to THIS experiment's build dir. The bare bundle-relative pattern
# ("BrightspaceBar.app/Contents/MacOS/…") also matches the PRODUCTION app and
# pkill'd it out of the menu bar on every run of this script.
PROCESS_PATTERN="${ROOT_DIR}/.build/.*${APP_NAME}.app/Contents/MacOS/${APP_NAME}"
SMOKE=0
[ "${1:-}" = "--smoke" ] && SMOKE=1

log() { printf '==> %s\n' "$*"; }

log "Stopping any running instance"
pkill -f "${PROCESS_PATTERN}" 2>/dev/null || true

log "swift build (${CONFIG})"
swift build -c "${CONFIG}" --package-path "${ROOT_DIR}"
[ -x "${EXE}" ] || { echo "ERROR: no executable at ${EXE}" >&2; exit 1; }

log "Assembling ${APP_NAME}.app"
mkdir -p "${APP}/Contents/MacOS"
cp -f "${EXE}" "${APP}/Contents/MacOS/${APP_NAME}"
cp -f "${ROOT_DIR}/Sources/${APP_NAME}/Info.plist" "${APP}/Contents/Info.plist"

# Ad-hoc signature ("-"). Enough to launch locally; real distribution needs a
# Developer ID and notarization, which is out of scope for this experiment.
log "Signing (ad-hoc)"
codesign --force --sign - "${APP}" >/dev/null 2>&1

log "Launching"
# Direct exec, not `open -n`: this bundle shares production BrightspaceBar's
# bundle identifier, and Launch Services silently refuses a second instance of
# an identifier that is already running. Direct exec has no such arbiter, and
# the absolute path also makes the process matchable by PROCESS_PATTERN.
"${APP}/Contents/MacOS/${APP_NAME}" >/dev/null 2>&1 &
disown

if [ "${SMOKE}" -eq 1 ]; then
    # A menu-bar app that crashes on launch still returns 0 from `open`, so the
    # only honest check is whether the process is still alive a moment later.
    sleep 3
    if pgrep -f "${PROCESS_PATTERN}" >/dev/null; then
        log "SMOKE PASS — process alive after launch"
        pkill -f "${PROCESS_PATTERN}" 2>/dev/null || true
        exit 0
    fi
    echo "SMOKE FAIL — process not running 3s after launch" >&2
    exit 1
fi

log "Running. Look for the icon in your menu bar."
log "Stop it with: pkill -f '${PROCESS_PATTERN}'"
