#!/usr/bin/env bash
# Build Exp9, assemble a .app bundle, ad-hoc sign, launch. Experiment-5's
# harness, renamed.
#
# Usage:  ./Scripts/run.sh           build, bundle, launch
#         ./Scripts/run.sh --smoke   build, launch, verify alive, kill
#         ./Scripts/run.sh --shoot   launch with the menu popped open (for
#                                    `screencapture` from another shell)
#         ./Scripts/run.sh --selftest  headless popup geometry + deep links
#         ./Scripts/run.sh --probe   open the menu and interrogate it from
#                                    inside its own tracking loop; writes
#                                    artifacts/probe.log
#         ./Scripts/run.sh --render  redraw artifacts/popup.png
#
# PROCESS_PATTERN is anchored on "Exp9.app/Contents/MacOS/Exp9" so `pkill -f`
# here can never match BrightspaceBar or any other menu-bar app.
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

# The headless modes need the executable, not the bundle, because they report
# on stdout and `open` would send it nowhere.
if [ "${MODE}" = "--selftest" ]; then
    log "Self-test (headless)"
    exec env EXP9_SELFTEST=1 "${EXE}"
fi

if [ "${MODE}" = "--probe" ]; then
    mkdir -p "${ROOT_DIR}/artifacts"
    log "Overlay probe — the menu will open by itself for ~3s and the cursor"
    log "will be borrowed briefly, then put back."
    exec env EXP9_PROBE=1 EXP9_PROBE_LOG="${ROOT_DIR}/artifacts/probe.log" "${EXE}"
fi

if [ "${MODE}" = "--render" ]; then
    mkdir -p "${ROOT_DIR}/artifacts"
    log "Rendering artifacts/popup.png"
    exec env EXP9_POPUP_RENDER="${ROOT_DIR}/artifacts/popup.png" "${EXE}"
fi

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
