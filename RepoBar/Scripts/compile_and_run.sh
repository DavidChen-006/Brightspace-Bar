#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP_NAME="RepoBar"
APP_PROCESS_PATTERN="${APP_NAME}.app/Contents/MacOS/${APP_NAME}"
CACHE_PATH="${HOME}/Library/Caches/RepoBar/swiftpm"
log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Load signing defaults from Config/Local.xcconfig if present (xcconfig syntax)
if [ -f "${ROOT_DIR}/Config/Local.xcconfig" ]; then
  # extract key/value pairs like KEY = value
  while IFS='=' read -r rawKey rawValue; do
    key="$(printf '%s' "$rawKey" | sed 's,//.*$,,' | xargs)"
    value="$(printf '%s' "$rawValue" | sed 's,//.*$,,' | xargs)"
    case "$key" in
      CODE_SIGN_IDENTITY|CODESIGN_IDENTITY) CODE_SIGN_IDENTITY="${value}" ;;
      DEVELOPMENT_TEAM) DEVELOPMENT_TEAM="${value}" ;;
      PROVISIONING_PROFILE_SPECIFIER) PROVISIONING_PROFILE_SPECIFIER="${value}" ;;
    esac
  done < <(grep -v '^[[:space:]]*//' "${ROOT_DIR}/Config/Local.xcconfig")
fi

kill_existing() {
  for _ in {1..10}; do
    pkill -f "${APP_PROCESS_PATTERN}" 2>/dev/null || true
    pkill -x "${APP_NAME}" 2>/dev/null || true
    pgrep -f "${APP_PROCESS_PATTERN}" >/dev/null || pgrep -x "${APP_NAME}" >/dev/null || return 0
    sleep 0.2
  done
}

log "==> Killing existing ${APP_NAME} instances"
kill_existing

mkdir -p "${CACHE_PATH}"

log "==> swift build"
./Scripts/swiftpm_sanitize.sh
swift build -q --cache-path "${CACHE_PATH}"
swift build -q --product repobarcli --cache-path "${CACHE_PATH}"

log "==> Packaging debug app bundle"
DEFAULT_IDENTITY="${CODE_SIGN_IDENTITY:-${CODESIGN_IDENTITY:-}}"
IDENTITY="${CODESIGN_IDENTITY:-$DEFAULT_IDENTITY}"
SKIP_KEYCHAIN_GROUPS=0
if [ -z "${PROVISIONING_PROFILE_SPECIFIER:-}" ]; then
  SKIP_KEYCHAIN_GROUPS=1
fi
if [ -n "$IDENTITY" ]; then
  SKIP_BUILD=1 REPOBAR_DEBUG_SIGNING=1 REPOBAR_SKIP_KEYCHAIN_GROUPS="$SKIP_KEYCHAIN_GROUPS" CODESIGN_IDENTITY="$IDENTITY" \
    "${ROOT_DIR}/Scripts/package_app.sh" debug
else
  SKIP_BUILD=1 REPOBAR_DEBUG_SIGNING=1 REPOBAR_SKIP_KEYCHAIN_GROUPS="$SKIP_KEYCHAIN_GROUPS" "${ROOT_DIR}/Scripts/package_app.sh" debug
fi

log "==> Launching debug build"
APP_BUNDLE="${ROOT_DIR}/.build/debug/${APP_NAME}.app"
EXPECTED_PROCESS_RESOLVED="$(cd "${APP_BUNDLE}" && pwd -P)/Contents/MacOS/${APP_NAME}"
if [ -d "${APP_BUNDLE}" ]; then
  # Launch via LaunchServices so the process has a proper bundle identifier (menubar item, single-instance, URL handlers).
  open -n -g "${APP_BUNDLE}"
else
  "${ROOT_DIR}/.build/debug/${APP_NAME}" &
fi

sleep 1

if [ -d "${APP_BUNDLE}" ]; then
  proc_pidpath() {
    python3 - "$1" <<'PY'
import ctypes
import sys

pid = int(sys.argv[1])
buf = ctypes.create_string_buffer(4096)
lib = ctypes.CDLL("/usr/lib/libproc.dylib")
ret = lib.proc_pidpath(pid, buf, ctypes.sizeof(buf))
if ret <= 0:
    raise SystemExit(1)
print(buf.value.decode("utf-8", errors="replace"))
PY
  }

  EXPECTED_PROCESS_COMPARE="$(printf '%s' "${EXPECTED_PROCESS_RESOLVED}" | tr '[:upper:]' '[:lower:]')"
  launched_from_checkout=0
  for _ in {1..50}; do
    while read -r pid; do
      path="$(proc_pidpath "${pid}" 2>/dev/null || true)"
      path_compare="$(printf '%s' "${path}" | tr '[:upper:]' '[:lower:]')"
      if [ -n "${path}" ] && [ "${path_compare}" = "${EXPECTED_PROCESS_COMPARE}" ]; then
        launched_from_checkout=1
        break
      fi
    done < <(pgrep -x "${APP_NAME}" || true)

    if [ "${launched_from_checkout}" -eq 1 ]; then break; fi
    sleep 0.2
  done

  if [ "${launched_from_checkout}" -ne 1 ]; then
    log "ERROR: ${APP_NAME} did not launch from this checkout."
    log "Expected: ${EXPECTED_PROCESS_RESOLVED}"
    while read -r pid; do
      path="$(proc_pidpath "${pid}" 2>/dev/null || true)"
      if [ -n "${path}" ]; then
        log "Running: ${path}"
      fi
    done < <(pgrep -x "${APP_NAME}" || true)
    log "Hint: another RepoBar build may be running from a different path; run:"
    log "  pgrep -af \"${APP_PROCESS_PATTERN}\""
    exit 1
  fi
fi

if pgrep -f "${APP_PROCESS_PATTERN}" >/dev/null 2>&1 || pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
  log "OK: ${APP_NAME} is running."
else
  fail "App exited immediately."
fi
