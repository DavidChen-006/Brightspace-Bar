#!/usr/bin/env bash
# Build Exp13, assemble a .app bundle, ad-hoc sign, launch. Experiment-9's
# harness with one addition: an opt-in mode that claims the time-sensitive
# entitlement, which is worth running once because it FAILS (see --entitled).
#
# Usage:  ./Scripts/run.sh              build, bundle, launch, leave running
#         ./Scripts/run.sh --smoke      build, launch, verify alive, kill
#         ./Scripts/run.sh --autofire   launch and fire one time-sensitive
#                                       notification unattended after 2s
#         ./Scripts/run.sh --probe      launch and round-trip every
#                                       interruption level, logging what the
#                                       OS gives back
#         ./Scripts/run.sh --entitled   sign claiming
#                                       com.apple.developer.usernotifications.time-sensitive
#                                       and try to launch. MEASURED: codesign
#                                       accepts the claim, then launchd REFUSES
#                                       to start the process (RBSRequestError 5
#                                       / POSIX 153). A restricted entitlement
#                                       needs a provisioning profile; ad-hoc
#                                       signing cannot fake one.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP_NAME="Exp13"
CONFIG="${CONFIG:-debug}"
APP="${ROOT_DIR}/.build/${CONFIG}/${APP_NAME}.app"
EXE="${ROOT_DIR}/.build/${CONFIG}/${APP_NAME}"
ENTITLEMENTS="${ROOT_DIR}/Sources/${APP_NAME}/${APP_NAME}.entitlements"
LOG="${ROOT_DIR}/artifacts/run.log"
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

if [ "${MODE}" = "--entitled" ]; then
    log "Signing (ad-hoc + time-sensitive entitlement) — expected to break launch"
    codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${APP}"
    log "Embedded entitlements:"
    codesign -d --entitlements - --xml "${APP}" 2>/dev/null | plutil -p - || true
else
    log "Signing (ad-hoc)"
    codesign --force --sign - "${APP}"
fi

mkdir -p "${ROOT_DIR}/artifacts"
: > "${LOG}"

# `open` DOES forward the calling shell's environment to the launched app —
# verified here, since EXP13_LOG arriving is what makes artifacts/run.log exist.
log "Launching (log mirrored to ${LOG})"
case "${MODE}" in
    --autofire) EXP13_LOG="${LOG}" EXP13_AUTOFIRE=1 open -n "${APP}" ;;
    --probe)    EXP13_LOG="${LOG}" EXP13_PROBE=1 open -n "${APP}" ;;
    *)          EXP13_LOG="${LOG}" open -n "${APP}" ;;
esac

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

log "Running. Click the bell icon in the menu bar."
log "Watch the log with: tail -f ${LOG}"
log "Stop it with: pkill -f '${PROCESS_PATTERN}'"
