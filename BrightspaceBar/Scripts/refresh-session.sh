#!/usr/bin/env bash
# Fill the app's session file — the supply side of the `SessionProviding` seam.
#
# The app reads ~/Library/Application Support/BrightspaceBar/session.json fresh on
# every fetch, so running this against a live app takes effect on the next poll,
# no relaunch needed.
#
# Usage:
#   ./Scripts/refresh-session.sh                 copy the latest experiment-1 capture
#   ./Scripts/refresh-session.sh <path.json>     copy a specific capture
#   ./Scripts/refresh-session.sh --capture       run experiment 1's interactive login
#                                                first (headed browser + MFA on your
#                                                phone), then copy its capture
#
# This script MOVES credentials, it never prints them. The destination is outside
# the repository on purpose: no credential lives where `git add` could reach it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
REPO_DIR="$(cd "${ROOT_DIR}/.." && pwd -P)"
# ../session-capture is the live capture tool: a headed browser the human signs in
# to, so no password is ever handled. (experiment-1-fresh-cookie automates the
# login and therefore needs BS_PASSWORD in the environment — kept as a frozen
# experiment record, deliberately not used here.)
CAPTURE_DIR="${REPO_DIR}/session-capture"
DEFAULT_SRC="${CAPTURE_DIR}/artifacts/session.json"
DEST_DIR="${HOME}/Library/Application Support/BrightspaceBar"
DEST="${DEST_DIR}/session.json"

log() { printf '==> %s\n' "$*"; }

SRC="${DEFAULT_SRC}"
if [ "${1:-}" = "--capture" ]; then
    # A headed browser opens and waits; YOU type everything, including MFA. This
    # script asks for no credentials and stores none — there is no password here
    # to end up in shell history or in an agent's transcript.
    log "Opening the login browser — sign in yourself, then approve MFA on your phone"
    (cd "${CAPTURE_DIR}" && npm run --silent capture)
    # A cookie without a CSRF token is useless: the mint answers 403 without the
    # x-csrf-token header, and the token is often unreadable on the page an SSO
    # redirect lands on. Cheap to re-derive from the cookie we just captured.
    log "Deriving the CSRF token"
    (cd "${CAPTURE_DIR}" && npm run --silent xsrf)
elif [ -n "${1:-}" ]; then
    SRC="$1"
fi

[ -f "${SRC}" ] || { echo "ERROR: no capture at ${SRC}" >&2; exit 1; }

# Refuse a capture that does not even parse as the expected shape — better to
# keep yesterday's session than to install garbage over it.
python3 - "$SRC" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
missing = [k for k in ("baseUrl", "cookieHeader") if not d.get(k)]
sys.exit(f"capture missing fields: {missing}" if missing else 0)
PY

mkdir -p "${DEST_DIR}"
# install(1): copy + permissions in one atomic-enough step; 600 because the file
# IS a credential.
install -m 600 "${SRC}" "${DEST}"

# Report the capture's age — the only fact about the file worth printing.
python3 - "$DEST" <<'PY'
import json, sys, time
captured = json.load(open(sys.argv[1])).get("capturedAt")
if captured:
    hours = (time.time() - captured / 1000) / 3600
    print(f"==> Installed. Capture is {hours:.1f}h old" + (" — likely already expired." if hours > 4 else "."))
else:
    print("==> Installed (capture carries no timestamp).")
PY
