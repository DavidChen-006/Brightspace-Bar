#!/bin/bash
#
# e2e-icon.sh — the live end-to-end run for BUILD 2: the MFA number on the icon.
#
# One story, top to bottom, against the REAL tenant:
#
#   empty root → refresh.mjs --allow-full-login → Entra shows a number →
#   cache/mfa.json appears → the STATUS BAR ICON reads it → David types it into
#   Authenticator → the login finishes → mfa.json is deleted → the icon is a logo
#   again and the cache is fresh.
#
# Costs one MFA and re-seeds the wristband, exactly like `e2e.sh tier2`, plus the
# one thing tier 2 cannot claim: that the number reached the human's menu bar.
#
# Assertions read ARTIFACTS ONLY — the exit code, cache/mfa.json's bytes and its
# absence afterwards, cache/status.json, cache/data.json, profile/ — plus one
# out-of-band witness (below) for the icon. Nothing reaches into the app or the
# daemon's internals, so a refactor behind the seams cannot break this script.
#
#   Usage: scripts/e2e-icon.sh [--yes]
#
#     --yes  skip the interactive confirmation before the root is wiped.
#            Required when stdin is not a terminal.
#
#   Exit codes: 0 GREEN · 1 an assertion or step failed · 2 usage/refused ·
#               3 SKIPPED, a precondition is not met (not a failure)
#
#   THE ICON IS VERIFIED BY DAVID'S EYES. screencapture is TCC-denied in the
#   session this was written in, so the automated witness is the status item's
#   WINDOW GEOMETRY: a helper that prints BrightspaceBar's window bounds (the
#   logo item is ~30pt wide, a two-digit badge ~62pt). When the helper is
#   missing or says nothing, the width checks report "skipped: no witness" and
#   the run still greens — the banner this script prints mid-run is the real
#   test, and a human answers it.
#
#   Environment:
#     BSB_ROOT          the root under test. UNSET (the default) means the real
#                       production root — that is the point of this run. Set it
#                       to a throwaway directory to rehearse the mechanics.
#     BSB_REFRESH_CLI   the daemon entry point (default src/refresh.mjs). A stub
#                       CLI here is how this script is rehearsed without a
#                       tenant, an MFA, or a browser.
#     BS_EMAIL/BS_PASSWORD  mandatory: the rung autofills them, it never waits
#                       for typing. Checked BEFORE anything is deleted.
#     ICON_WITNESS      the window-geometry helper (default below). Unset or
#                       missing → the width checks skip.
#     ICON_MFA_TIMEOUT  seconds to wait for cache/mfa.json to appear (default 90:
#                       Entra has to render the number and the scrape has to see
#                       it — worst case ~2s after it renders, plus page load).
#     ICON_LOGIN_TIMEOUT seconds for the whole daemon run (default 600 — most of
#                       it is a human finding their phone).
#     ICON_REQUIRE_APP  1 (default) demands a running BrightspaceBar. 0 is for
#                       rehearsals only: there is no icon to look at.
#
# NOT a node:test file and not matched by `npm test`'s glob on purpose:
# `npm test` must stay hermetic and instant on any machine.
set -u

# ─────────────────────────────────────────────────────────────────────────────
# Where everything is
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PKG_DIR="$(dirname "$SCRIPT_DIR")"           # session-capture/
REPO_DIR="$(dirname "$PKG_DIR")"             # PaperShelf/
SWIFT_DIR="$REPO_DIR/BrightspaceBar"

REFRESH_CLI="${BSB_REFRESH_CLI:-$PKG_DIR/src/refresh.mjs}"
RESET_SH="$SCRIPT_DIR/reset.sh"

MFA_TIMEOUT="${ICON_MFA_TIMEOUT:-90}"
LOGIN_TIMEOUT="${ICON_LOGIN_TIMEOUT:-600}"
REQUIRE_APP="${ICON_REQUIRE_APP:-1}"
WITNESS="${ICON_WITNESS:-/private/tmp/claude-501/-Users-davidchen-PaperShelf/15da73f9-3bba-48a0-86e3-307464186c6c/scratchpad/winlist2/winlist2}"

APP_PATTERN="BrightspaceBar.app/Contents/MacOS/BrightspaceBar"

# The layout duplicated from src/paths.mjs (a shell script cannot import it) —
# and duplicated ON PURPOSE rather than exported into the child: when BSB_ROOT is
# unset the daemon resolves the production default ITSELF, exactly as it does
# under launchd. If the two defaults ever disagree, the artifacts land where this
# script is not looking and the run fails loudly, which is the honest outcome.
if [ -n "${BSB_ROOT:-}" ]; then
  case "$BSB_ROOT" in
    /*) ROOT="$BSB_ROOT" ;;
    *) ROOT="$PWD/$BSB_ROOT" ;;
  esac
  export BSB_ROOT="$ROOT"
  ROOT_ORIGIN="BSB_ROOT is set — this is a rehearsal root, not the production one"
else
  ROOT="$HOME/Library/Application Support/BrightspaceBar"
  ROOT_ORIGIN="BSB_ROOT is unset — the PRODUCTION default, resolved by the daemon itself"
fi

DATA_FILE="$ROOT/cache/data.json"
STATUS_FILE="$ROOT/cache/status.json"
MFA_FILE="$ROOT/cache/mfa.json"
PROFILE_DIR="$ROOT/profile"

# ─────────────────────────────────────────────────────────────────────────────
# Saying things
# ─────────────────────────────────────────────────────────────────────────────

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
note() { printf '    note: %s\n' "$*"; }

DAEMON_LOG=""
DAEMON_PID=""

log_tail() {
  [ -n "$DAEMON_LOG" ] && [ -f "$DAEMON_LOG" ] || return 0
  printf '\n--- last 20 lines of the daemon log (%s) ---\n' "$DAEMON_LOG" >&2
  tail -n 20 "$DAEMON_LOG" >&2
  printf -- '--------------------------------------------\n' >&2
}

# Every failure names what was expected and what was found, because the operator
# reading this is mid-run and will not go source-diving to find out.
fail() {
  printf '\nFAIL: %s\n' "$1" >&2
  shift
  for line in "$@"; do printf '      %s\n' "$line" >&2; done
  log_tail
  # A daemon still holding a browser open would outlive this script otherwise.
  if [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then
    printf '\n      (the daemon is still running as pid %s — sending SIGTERM)\n' "$DAEMON_PID" >&2
    kill -TERM "$DAEMON_PID" 2>/dev/null
  fi
  printf '\nE2E ICON: FAILED\n' >&2
  exit 1
}

skip() {
  printf '\nSKIP: %s\n' "$1" >&2
  shift
  for line in "$@"; do printf '      %s\n' "$line" >&2; done
  printf '\nE2E ICON: SKIPPED (precondition not met — this is not a failure)\n' >&2
  exit 3
}

usage() {
  sed -n '3,56p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

# ─────────────────────────────────────────────────────────────────────────────
# The icon witness — secondary evidence, never the reason a green run turns red
# ─────────────────────────────────────────────────────────────────────────────

WITNESS_RAW=""
WITNESS_WIDTH=""

# Sets WITNESS_RAW (everything the helper printed) and WITNESS_WIDTH (the width
# of the status-item window, layer 25 — "" when there is nothing to read).
read_witness() {
  WITNESS_RAW=""
  WITNESS_WIDTH=""
  [ -n "$WITNESS" ] || return 0
  [ -x "$WITNESS" ] || return 0
  WITNESS_RAW="$("$WITNESS" 2>&1)" || WITNESS_RAW=""
  # A status-item window is layer 25; its size is the last field, "62.0x24.0".
  WITNESS_WIDTH="$(printf '%s\n' "$WITNESS_RAW" |
    awk '/layer=25/ { split($NF, size, "x"); print size[1]; exit }')"
}

# $1 = a label for the moment being witnessed.
report_witness() {
  if [ ! -x "$WITNESS" ]; then
    note "icon witness $1: skipped: no witness (not executable: $WITNESS)"
    return 0
  fi
  if [ -z "$WITNESS_WIDTH" ]; then
    note "icon witness $1: skipped: no witness (the helper reported no status-item window)"
    [ -n "$WITNESS_RAW" ] && printf '          %s\n' "$WITNESS_RAW"
    return 0
  fi
  note "icon witness $1: status-item window ${WITNESS_WIDTH}pt wide"
  printf '          %s\n' "$WITNESS_RAW"
}

# ─────────────────────────────────────────────────────────────────────────────
# Reading the artifacts
# ─────────────────────────────────────────────────────────────────────────────

# One field of a JSON file, or "" when it is missing/corrupt/absent-key. Values
# arrive by environment, never argv, so a path with spaces (and the real root has
# two) cannot be mis-split.
json_field() {
  E2E_FILE="$1" E2E_KEY="$2" node --input-type=module -e '
    import { readFileSync } from "node:fs";
    try {
      const value = JSON.parse(readFileSync(process.env.E2E_FILE, "utf8"))[process.env.E2E_KEY];
      process.stdout.write(value === null || value === undefined ? "" : String(value));
    } catch { process.stdout.write(""); }
  ' 2>/dev/null
}

status_line() {
  if [ ! -f "$STATUS_FILE" ]; then printf 'no status.json at %s' "$STATUS_FILE"; return; fi
  printf 'state=%s rungUsed=%s error=%s' \
    "$(json_field "$STATUS_FILE" state)" \
    "$(json_field "$STATUS_FILE" rungUsed)" \
    "$(json_field "$STATUS_FILE" error)"
}

assert_status() {
  [ -f "$STATUS_FILE" ] || fail "no status.json was written" \
    "expected: $STATUS_FILE with state=$1 rungUsed=$2" \
    "found:    the file does not exist"
  found_state="$(json_field "$STATUS_FILE" state)"
  found_rung="$(json_field "$STATUS_FILE" rungUsed)"
  if [ "$found_state" != "$1" ] || [ "$found_rung" != "$2" ]; then
    fail "status.json does not describe the run this script asked for" \
      "expected: state=$1 rungUsed=$2" \
      "found:    state=${found_state:-<unreadable>} rungUsed=${found_rung:-<unreadable>}" \
      "error:    $(json_field "$STATUS_FILE" error)" \
      "file:     $STATUS_FILE" \
      "(the app polls every 15 minutes without --allow-full-login; a tick that" \
      " landed on this window would overwrite the status with needs-login)"
  fi
  ok "status.json: state=$1 rungUsed=$2 (lastSuccessAt=$(json_field "$STATUS_FILE" lastSuccessAt))"
}

# mfa.json's shape, checked the instant it appears — this is the contract the
# icon renders. $1 = epoch seconds when the daemon started.
assert_mfa_shape() {
  E2E_FILE="$MFA_FILE" E2E_SINCE="$1" node --input-type=module -e '
    import { readFileSync } from "node:fs";

    const file = process.env.E2E_FILE;
    const since = Number(process.env.E2E_SINCE) * 1000;
    const bad = (what, expected, found) => {
      console.error(`FAIL: ${what}`);
      console.error(`      expected: ${expected}`);
      console.error(`      found:    ${found}`);
      console.error(`      file:     ${file}`);
      process.exit(1);
    };

    let payload;
    try { payload = JSON.parse(readFileSync(file, "utf8")); }
    catch (error) { bad("mfa.json is missing or unparseable", "a JSON object", String(error.message)); }

    if (typeof payload.number !== "string" || !/^[0-9]{1,4}$/.test(payload.number)) {
      bad("number is not the digits Entra shows",
        "a string of 1-4 digits (the icon renders it verbatim)",
        JSON.stringify(payload.number));
    }

    const minted = Date.parse(payload.mintedAt);
    if (Number.isNaN(minted)) bad("mintedAt is not a date", "an ISO-8601 string", JSON.stringify(payload.mintedAt));
    // The icon is a pure function of (file exists && now - mintedAt < 60s): a
    // stamp older than this run means the number on screen is not this one.
    if (minted < since - 120000 || minted > Date.now() + 120000) {
      bad("mintedAt was not stamped by THIS run",
        `a stamp within the run window (since ${new Date(since - 120000).toISOString()})`,
        `${payload.mintedAt} — a leftover file, or a clock that disagrees`);
    }

    const age = Math.round((Date.now() - minted) / 1000);
    console.log(`    ok: mfa.json shape — number "${payload.number}", mintedAt ${payload.mintedAt} (${age}s old, TTL 60s)`);
  '
  # shellcheck disable=SC2181  # the heredoc-style node call above is the subject
  if [ $? -ne 0 ]; then
    fail "mfa.json did not satisfy the file contract" "see the expected/found above"
  fi
}

# data.json holds a payload the menu bar could actually render, stamped inside
# this run's window. $1 = epoch seconds when the run started. (The full course
# shape is e2e.sh's contract; the claim here is only "fresh, and not empty".)
assert_data_fresh() {
  E2E_FILE="$DATA_FILE" E2E_SINCE="$1" node --input-type=module -e '
    import { readFileSync } from "node:fs";

    const file = process.env.E2E_FILE;
    const since = Number(process.env.E2E_SINCE) * 1000;
    const bad = (what, expected, found) => {
      console.error(`FAIL: ${what}`);
      console.error(`      expected: ${expected}`);
      console.error(`      found:    ${found}`);
      console.error(`      file:     ${file}`);
      process.exit(1);
    };

    let payload;
    try { payload = JSON.parse(readFileSync(file, "utf8")); }
    catch (error) { bad("data.json is missing or unparseable", "a JSON object", String(error.message)); }

    const stamped = Date.parse(payload.fetchedAt);
    if (Number.isNaN(stamped)) bad("fetchedAt is not a date", "an ISO-8601 string", JSON.stringify(payload.fetchedAt));
    if (stamped < since - 120000 || stamped > Date.now() + 120000) {
      bad("data.json was not written by THIS run",
        `fetchedAt within the run window (since ${new Date(since - 120000).toISOString()})`,
        `${payload.fetchedAt} — the daemon wrote no new cache, or preserved an old one`);
    }

    const courses = payload.courses;
    if (!Array.isArray(courses) || courses.length === 0) {
      bad("the cache holds no courses", "at least one course (the menu would be empty)",
        Array.isArray(courses) ? "courses: []" : typeof courses);
    }

    console.log(`    ok: data.json fresh — ${courses.length} courses, fetchedAt ${payload.fetchedAt}`);
  '
  # shellcheck disable=SC2181
  if [ $? -ne 0 ]; then
    fail "data.json did not satisfy the file contract" "see the expected/found above"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Argv
# ─────────────────────────────────────────────────────────────────────────────

ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=1 ;;
    --help|-h) usage ;;
    *) say "unknown argument: $arg" >&2; usage ;;
  esac
done

say "MFA-icon E2E — the number on the menu bar, end to end"
say "  root:        $ROOT"
say "               ($ROOT_ORIGIN)"
say "  daemon CLI:  $REFRESH_CLI"
say "  icon witness: $([ -x "$WITNESS" ] && echo "$WITNESS" || echo "MISSING ($WITNESS) — width checks will skip")"
say "  bounds:      mfa.json appears within ${MFA_TIMEOUT}s · whole run ${LOGIN_TIMEOUT}s"

command -v node >/dev/null 2>&1 || fail "node is not on PATH" "expected: a node binary" "found: none"
[ -f "$REFRESH_CLI" ] || fail "the daemon CLI is missing" \
  "expected: a file at $REFRESH_CLI" "found: nothing (BSB_REFRESH_CLI overrides this path)"
[ -x "$RESET_SH" ] || fail "reset.sh is not executable" \
  "expected: an executable $RESET_SH" "found: not executable"

# ─────────────────────────────────────────────────────────────────────────────
# Preconditions — all of them BEFORE anything is deleted. Discovering a missing
# password after the wristband is gone strands the root with no cheap way back.
# ─────────────────────────────────────────────────────────────────────────────

step "preconditions"

if [ -z "${BS_EMAIL:-}" ] || [ -z "${BS_PASSWORD:-}" ]; then
  skip "BS_EMAIL and BS_PASSWORD are not both set" \
    "expected: both in the environment — the rung AUTOFILLS them (D3) and never" \
    "          waits for a human to type them; after the wipe there is no profile," \
    "          so silent SSO cannot cover for them" \
    "found:    BS_EMAIL=${BS_EMAIL:+set}${BS_EMAIL:-<unset>} BS_PASSWORD=${BS_PASSWORD:+set}${BS_PASSWORD:-<unset>}" \
    "nothing has been deleted. Re-run as:" \
    "  BS_EMAIL='you@purdue.edu' BS_PASSWORD='…' scripts/e2e-icon.sh --yes"
fi
ok "BS_EMAIL is set (${#BS_EMAIL} chars) and BS_PASSWORD is set (${#BS_PASSWORD} chars)"

if [ "$REQUIRE_APP" -eq 1 ]; then
  if ! pgrep -f "$APP_PATTERN" >/dev/null 2>&1; then
    skip "BrightspaceBar is not running — there is no icon to watch" \
      "expected: a live app process matching $APP_PATTERN" \
      "found:    nothing" \
      "start it yourself (this script will not: run.sh REBUILDS, which is the" \
      "orchestrator's call, and its launch spawns a daemon run of its own):" \
      "  cd $SWIFT_DIR && ./Scripts/run.sh" \
      "then re-run this script."
  fi
  ok "BrightspaceBar is running (pid $(pgrep -f "$APP_PATTERN" | tr '\n' ' '))"
  say ""
  say "  Heads up: the app also refreshes on its own every 15 minutes, WITHOUT"
  say "  --allow-full-login. Such a tick cannot touch mfa.json (the full rung is"
  say "  skipped before it is ever entered), but it CAN overwrite status.json with"
  say "  needs-login while this root is empty. If the end-of-run status assertion"
  say "  fails that way, it is a collision, not a regression — re-run."
else
  note "ICON_REQUIRE_APP=0 — not checking for a running app (rehearsal mode; no icon exists)"
fi

read_witness
report_witness "before the wipe"
BASELINE_WIDTH="$WITNESS_WIDTH"

# ─────────────────────────────────────────────────────────────────────────────
# The wipe
# ─────────────────────────────────────────────────────────────────────────────

say ""
say "  DESTRUCTIVE. This deletes everything inside:"
say "      $ROOT"
say "    - profile/      the ~90-day Entra wristband (this run re-seeds it)"
say "    - session.json  the live D2L credential"
say "    - cache/        data.json + status.json (the menu goes empty until the run ends)"
say ""

if [ "$ASSUME_YES" -eq 1 ]; then
  say "  --yes was given — proceeding without asking."
elif [ ! -t 0 ]; then
  say "REFUSED: stdin is not a terminal and --yes was not given." >&2
  say "         Nothing was deleted. Re-run with --yes to accept the wipe." >&2
  exit 2
else
  printf '  Type WIPE to continue (anything else aborts): '
  read -r answer || answer=""
  if [ "$answer" != "WIPE" ]; then
    say "REFUSED: aborted — nothing was deleted." >&2
    exit 2
  fi
fi

step "wiping the root: $RESET_SH --all"
BSB_ROOT="$ROOT" "$RESET_SH" --all || fail "reset.sh --all failed" "the root was not emptied"

cat <<EOF

  WHAT HAPPENS NEXT — read this before it starts:
    1. NO window opens — the login runs fully headless. Watch your MENU BAR.
    2. It fills in your email and password by itself, in the background.
    3. Microsoft shows a NUMBER — it appears ON YOUR MENU BAR icon (and this
       script also SHOUTS it at you). Type it into Authenticator on your phone.
    4. If it offers "Stay signed in?" the rung clicks Yes — that is the wristband.
    5. ~55 requests fetch courses, and the icon goes back to being a logo.
    (To watch the browser for debugging, re-run with BSB_FULL_HEADED=1.)
  The number is only good for 60 seconds on the icon. Watch the menu bar.

EOF

# ─────────────────────────────────────────────────────────────────────────────
# The run
# ─────────────────────────────────────────────────────────────────────────────

DAEMON_LOG="$(mktemp -t bsb-e2e-icon)"
STARTED="$(date +%s)"

step "starting the full ladder in the background: refresh.mjs --allow-full-login"
say "    node $REFRESH_CLI --allow-full-login"
node "$REFRESH_CLI" --allow-full-login >"$DAEMON_LOG" 2>&1 &
DAEMON_PID=$!
say "    pid $DAEMON_PID · log $DAEMON_LOG"

step "waiting up to ${MFA_TIMEOUT}s for cache/mfa.json to appear"
waited=0
while [ ! -f "$MFA_FILE" ]; do
  if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
    wait "$DAEMON_PID"
    early_rc=$?
    fail "the daemon exited (code $early_rc) before it ever published a number" \
      "expected: $MFA_FILE written while Entra shows the number-match digits" \
      "found:    the run ended first — the login failed, or the page never" \
      "          rendered #idRichContext_DisplaySign" \
      "status.json now says: $(status_line)"
  fi
  if [ "$waited" -ge "$MFA_TIMEOUT" ]; then
    fail "no number reached the icon within ${MFA_TIMEOUT}s" \
      "expected: $MFA_FILE (the full rung publishes it the moment the scrape lands," \
      "          worst case ~2s after Entra renders the number)" \
      "found:    nothing at that path — the daemon is still running as pid $DAEMON_PID" \
      "raise the bound with ICON_MFA_TIMEOUT if this machine is genuinely slow." \
      "The daemon is being stopped; the root is left wiped."
  fi
  sleep 1
  waited=$((waited + 1))
done

# From here the clock is the 60s TTL: read the bytes, witness the icon, THEN
# talk to the human. Anything slower than this order verifies an expired badge.
MFA_BYTES="$(cat "$MFA_FILE" 2>/dev/null)"
read_witness
BADGE_WIDTH="$WITNESS_WIDTH"
MFA_NUMBER="$(json_field "$MFA_FILE" number)"

cat <<EOF

################################################################################
#
#   LOOK AT YOUR MENU BAR — the icon should now read:   🔐 ${MFA_NUMBER}
#
#   Type ${MFA_NUMBER} into Authenticator on your phone. It is good for 60 seconds
#   on the icon (the badge reverts to the logo after that, whatever the phone
#   is doing).
#
################################################################################

EOF

say "    mfa.json appeared after ${waited}s. Its exact bytes:"
printf '%s\n' "$MFA_BYTES" | sed 's/^/      /'
report_witness "with the number live"
assert_mfa_shape "$STARTED"

if [ -n "$BADGE_WIDTH" ] && [ -n "$BASELINE_WIDTH" ]; then
  if awk "BEGIN { exit !($BADGE_WIDTH > $BASELINE_WIDTH) }"; then
    ok "the status item GREW while the number was live: ${BASELINE_WIDTH}pt → ${BADGE_WIDTH}pt"
  else
    fail "the status item did not widen for the badge" \
      "expected: wider than the logo (${BASELINE_WIDTH}pt — a 2-digit badge measures ~62pt)" \
      "found:    ${BADGE_WIDTH}pt" \
      "the file was published, so this is the app half: the watcher did not paint."
  fi
fi

step "waiting up to ${LOGIN_TIMEOUT}s for the login to finish (your phone, then ~55 requests)"
waited=0
while kill -0 "$DAEMON_PID" 2>/dev/null; do
  if [ "$waited" -ge "$LOGIN_TIMEOUT" ]; then
    say "    (no answer after ${LOGIN_TIMEOUT}s — sending SIGTERM)"
    kill -TERM "$DAEMON_PID" 2>/dev/null
    sleep 5
    kill -KILL "$DAEMON_PID" 2>/dev/null
    wait "$DAEMON_PID" 2>/dev/null
    DAEMON_PID=""
    fail "the daemon did not finish within ${LOGIN_TIMEOUT}s" \
      "expected: an exit once the MFA was approved and the fetch completed" \
      "found:    still running — SIGTERM, then SIGKILL" \
      "raise the bound with ICON_LOGIN_TIMEOUT if the wait was genuinely yours."
  fi
  sleep 1
  waited=$((waited + 1))
done
wait "$DAEMON_PID"
RUN_RC=$?
DAEMON_PID=""
say "    the daemon exited after ${waited}s"

# ─────────────────────────────────────────────────────────────────────────────
# What the run must have left behind
# ─────────────────────────────────────────────────────────────────────────────

step "asserting the artifacts"

if [ "$RUN_RC" -ne 0 ]; then
  fail "the daemon exited $RUN_RC" \
    "expected: exit 0 (a fresh cache was written)" \
    "found:    exit $RUN_RC (0 fresh · 2 needs-login · 1 error)" \
    "status.json now says: $(status_line)"
fi
ok "exit 0"

# The icon's lifetime IS this file's lifetime. A file that outlives its number is
# an icon telling a human to type digits that will not work.
if [ -f "$MFA_FILE" ]; then
  fail "mfa.json outlived the login" \
    "expected: $MFA_FILE deleted on the way out (the rung's finally)" \
    "found:    still there, holding: $(cat "$MFA_FILE" 2>/dev/null | tr '\n' ' ')" \
    "the icon only recovers here because of the 60s TTL — that is a safety net," \
    "not the contract."
fi
ok "mfa.json is gone — the number's lifetime ended with the login"

read_witness
report_witness "after the login"
if [ -n "$WITNESS_WIDTH" ] && [ -n "$BADGE_WIDTH" ]; then
  if awk "BEGIN { exit !($WITNESS_WIDTH < $BADGE_WIDTH) }"; then
    ok "the status item shrank back to the logo: ${BADGE_WIDTH}pt → ${WITNESS_WIDTH}pt"
  else
    fail "the status item never went back to the logo" \
      "expected: narrower than the badge (${BADGE_WIDTH}pt — the logo measures ~30pt)" \
      "found:    ${WITNESS_WIDTH}pt" \
      "mfa.json is gone, so the app did not act on the delete event."
  fi
fi

assert_status fresh full
assert_data_fresh "$STARTED"

# The wristband is the whole return on the MFA that was just spent: without a
# profile directory left behind, every later silent run is another full login.
[ -d "$PROFILE_DIR" ] || fail "the login left no persistent profile behind" \
  "expected: $PROFILE_DIR (the ~90-day Entra wristband)" \
  "found:    nothing — the silent rung will have nothing to re-mint from"
ok "the Entra profile survives at $PROFILE_DIR"

rm -f "$DAEMON_LOG"

say ""
say "  The number reached the icon, the icon let it go, and the wristband is re-seeded."
say "  Cheap runs from here: scripts/e2e.sh tier1 · scripts/e2e.sh tier0"
printf '\nE2E ICON: GREEN\n'
