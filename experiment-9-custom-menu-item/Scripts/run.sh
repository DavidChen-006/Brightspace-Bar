#!/usr/bin/env bash
# Build Exp9, assemble a .app bundle, ad-hoc sign, launch. Experiment-5's
# harness, renamed.
#
# Usage:  ./Scripts/run.sh           build, bundle, launch
#         ./Scripts/run.sh --smoke   build, launch, verify alive, kill
#         ./Scripts/run.sh --shoot   launch with the menu popped open (for
#                                    `screencapture` from another shell)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP_NAME="Exp9"
CONFIG="${CONFIG:-debug}"
APP="${ROOT_DIR}/.build/${CONFIG}/${APP_NAME}.app"
EXE="${ROOT_DIR}/.build/${CONFIG}/${APP_NAME}"
PROCESS_PATTERN="${APP_NAME}.app/Contents/MacOS/${APP_NAME}"
MODE="${1:-}"

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

log "Signing (ad-hoc)"
codesign --force --sign - "${APP}" >/dev/null 2>&1

log "Launching"
if [ "${MODE}" = "--shoot" ]; then
    EXP9_SHOOT=1 open -n "${APP}"
else
    open -n "${APP}"
fi

if [ "${MODE}" = "--smoke" ]; then
    sleep 3
    if pgrep -f "${PROCESS_PATTERN}" >/dev/null; then
        log "SMOKE PASS — process alive after launch"
        pkill -f "${PROCESS_PATTERN}" 2>/dev/null || true
        exit 0
    fi
    echo "SMOKE FAIL — process not running 3s after launch" >&2
    exit 1
fi

log "Running. Click the grid icon in the menu bar."
log "Stop it with: pkill -f '${PROCESS_PATTERN}'"
