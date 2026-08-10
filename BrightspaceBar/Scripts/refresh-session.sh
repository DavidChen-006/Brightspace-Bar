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
CAPTURE_DIR="${REPO_DIR}/experiment-1-fresh-cookie"
DEFAULT_SRC="${CAPTURE_DIR}/artifacts/session.json"
DEST_DIR="${HOME}/Library/Application Support/BrightspaceBar"
DEST="${DEST_DIR}/session.json"

log() { printf '==> %s\n' "$*"; }

SRC="${DEFAULT_SRC}"
if [ "${1:-}" = "--capture" ]; then
    # Experiment 1 is the proven interactive path: headed Chromium, Purdue SSO,
    # Duo MFA. Its e2e test drives the capture and writes artifacts/session.json;
    # we only copy the result.
    #
    # Credentials: prompted here, exported to the child only — never an argument
    # (would land in `ps`), never echoed (read -s), never written anywhere.
    if [ -z "${BS_EMAIL:-}" ]; then
        printf 'Purdue email: ' >&2
        read -r BS_EMAIL
    fi
    if [ -z "${BS_PASSWORD:-}" ]; then
        printf 'Purdue password (not echoed): ' >&2
        read -rs BS_PASSWORD
        printf '\n' >&2
    fi
    export BS_EMAIL BS_PASSWORD
    log "Opening the login browser — approve MFA on your phone when it appears"
    (cd "${CAPTURE_DIR}" && npm test)
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
