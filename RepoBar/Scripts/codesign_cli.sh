#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI_PATH="${1:-$ROOT_DIR/.build/debug/repobarcli}"

log() { printf '%s\n' "[$(date '+%H:%M:%S')] $*"; }

# Load signing defaults from Config/Local.xcconfig if present (xcconfig syntax)
if [ -f "${ROOT_DIR}/Config/Local.xcconfig" ]; then
  while IFS='=' read -r rawKey rawValue; do
    key="$(printf '%s' "$rawKey" | sed 's,//.*$,,' | xargs)"
    value="$(printf '%s' "$rawValue" | sed 's,//.*$,,' | xargs)"
    case "$key" in
      CODE_SIGN_IDENTITY|CODESIGN_IDENTITY) CODE_SIGN_IDENTITY="${value}" ;;
    esac
  done < <(grep -v '^[[:space:]]*//' "${ROOT_DIR}/Config/Local.xcconfig")
fi

select_identity() {
  local preferred available first

  # Prefer Apple Development for local debug signing.
  preferred="$(security find-identity -p codesigning -v 2>/dev/null \
    | awk -F'\"' '/Apple Development/ { print $2; exit }')"
  if [ -n "$preferred" ]; then
    echo "$preferred"
    return
  fi

  # Fallback to Developer ID Application.
  preferred="$(security find-identity -p codesigning -v 2>/dev/null \
    | awk -F'\"' '/Developer ID Application/ { print $2; exit }')"
  if [ -n "$preferred" ]; then
    echo "$preferred"
    return
  fi

  # Fallback to the first valid signing identity.
  available="$(security find-identity -p codesigning -v 2>/dev/null \
    | sed -n 's/.*\"\\(.*\\)\"/\\1/p')"
  if [ -n "$available" ]; then
    first="$(printf '%s\n' "$available" | head -n1)"
    echo "$first"
    return
  fi

  return 1
}

IDENTITY="${REPOBAR_CODE_SIGN_IDENTITY:-${CODESIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-${SIGN_IDENTITY:-}}}}"
if [ -z "$IDENTITY" ]; then
  if ! IDENTITY="$(select_identity)"; then
    log "ERROR: No signing identity found; install a codesigning cert or set CODE_SIGN_IDENTITY."
    exit 1
  fi
fi

if [ ! -f "$CLI_PATH" ]; then
  log "ERROR: CLI binary not found: $CLI_PATH"
  exit 1
fi

timestamp_arg="--timestamp=none"
if [[ "$IDENTITY" == *"Developer ID Application"* ]]; then
  timestamp_arg="--timestamp"
fi

IDENTIFIER="com.steipete.repobar.cli"

log "Signing repobar ($CLI_PATH) with $IDENTITY"
xattr -cr "$CLI_PATH" 2>/dev/null || true
codesign --force --options runtime "$timestamp_arg" --identifier "$IDENTIFIER" --sign "$IDENTITY" "$CLI_PATH"
codesign --verify --verbose=2 "$CLI_PATH"
