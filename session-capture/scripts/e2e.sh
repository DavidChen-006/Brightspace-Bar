#!/bin/bash
#
# e2e.sh — the tiered end-to-end run for the session ladder (LADDER-PLAN phase 4).
#
# Each tier proves one rung of the success story against the REAL tenant, and
# each one costs exactly what its name says:
#
#   tier0  a live session is in place       → refetch, cache advances   ZERO human
#   tier1  session.json deleted, profile kept → silent rung re-mints it  ZERO human
#   tier2  root emptied                     → headed login, one MFA      DAVID PRESENT
#
# Assertions read ARTIFACTS ONLY — the exit code, cache/status.json,
# cache/data.json, file mtimes. Nothing here reaches into the daemon's internals,
# so a refactor behind the seams cannot break this script; a broken contract can.
#
#   Usage: scripts/e2e.sh tier0|tier1|tier2|all [--yes] [--with-swift]
#
#     --yes         skip the interactive confirmation tier 2 needs before it
#                   wipes the root. Required when stdin is not a terminal.
#     --with-swift  after the daemon assertions, run `BS_LIVE=1 swift test`
#                   in BrightspaceBar/ — the app half of the tier.
#
#   Exit codes: 0 GREEN · 1 an assertion or step failed · 2 usage/refused ·
#               3 SKIPPED, the tier's precondition is not met (not a failure)
#
#   Environment:
#     BSB_ROOT          the root under test. UNSET (the default) means the real
#                       production root — that is the point of tier 2. Set it to
#                       a throwaway directory to rehearse the script's mechanics.
#     BSB_REFRESH_CLI   the daemon entry point (default src/refresh.mjs). Same
#                       override the Swift app honours; a stub CLI here is how
#                       this script is rehearsed without touching the tenant.
#     BS_EMAIL/BS_PASSWORD  required by tier 2 only (see the tier-2 preflight).
#     E2E_TIMEOUT       seconds for an unattended daemon run (default 180, the
#                       app's own spawn timeout — a run the app would tolerate
#                       must not fail here).
#     E2E_LOGIN_TIMEOUT seconds for the tier-2 headed login (default 600).
#     E2E_SWIFT_TIMEOUT seconds for `swift test` (default 900, it may build).
#
# NOT a node:test file and not matched by `npm test`'s glob (tests/**/*.test.mjs)
# on purpose: `npm test` must stay hermetic and instant on any machine.
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

TIMEOUT="${E2E_TIMEOUT:-180}"
LOGIN_TIMEOUT="${E2E_LOGIN_TIMEOUT:-600}"
SWIFT_TIMEOUT="${E2E_SWIFT_TIMEOUT:-900}"

# The layout duplicated from src/paths.mjs (a shell script cannot import it) —
# and duplicated ON PURPOSE rather than exported into the children: when BSB_ROOT
# is unset the daemon resolves the production default ITSELF, exactly as it does
# under launchd. If the two defaults ever disagree, the artifacts land where this
# script is not looking and the tier fails loudly, which is the honest outcome.
if [ -n "${BSB_ROOT:-}" ]; then
  case "$BSB_ROOT" in
    /*) ROOT="$BSB_ROOT" ;;
    *) ROOT="$PWD/$BSB_ROOT" ;;
  esac
  export BSB_ROOT="$ROOT"
  ROOT_ORIGIN="BSB_ROOT is set — this is a rehearsal root, not the production one"
else
  ROOT="$HOME/Library/Application Support/BrightspaceBar"
  ROOT_ORIGIN="BSB_ROOT is unset — the PRODUCTION default, resolved by each child itself"
fi

DATA_FILE="$ROOT/cache/data.json"
STATUS_FILE="$ROOT/cache/status.json"
SESSION_FILE="$ROOT/session.json"
PROFILE_DIR="$ROOT/profile"

# ─────────────────────────────────────────────────────────────────────────────
# Saying things
# ─────────────────────────────────────────────────────────────────────────────

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }

# Every failure names what was expected and what was found, because the operator
# reading this is mid-run and will not go source-diving to find out.
fail() {
  printf '\nFAIL: %s\n' "$1" >&2
  shift
  for line in "$@"; do printf '      %s\n' "$line" >&2; done
  printf '\nE2E %s: FAILED\n' "$(printf '%s' "$TIER" | tr '[:lower:]' '[:upper:]')" >&2
  exit 1
}

skip() {
  printf '\nSKIP: %s\n' "$1" >&2
  shift
  for line in "$@"; do printf '      %s\n' "$line" >&2; done
  printf '\nE2E %s: SKIPPED (precondition not met — this is not a failure)\n' \
    "$(printf '%s' "$TIER" | tr '[:lower:]' '[:upper:]')" >&2
  exit 3
}

usage() {
  sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

green() { printf '\nE2E %s: GREEN\n' "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"; }

# ─────────────────────────────────────────────────────────────────────────────
# Running things, bounded
# ─────────────────────────────────────────────────────────────────────────────

# `timeout` is not on a stock macOS, so the watchdog is a background PID plus a
# polling loop. SIGTERM first (playwright gets a chance to close its browser),
# SIGKILL after a grace period. Sets RUN_RC; returns 0 always so the caller can
# tell a timeout (124) from a daemon exit code.
RUN_RC=0
run_bounded() {
  limit="$1"; shift
  "$@" &
  pid=$!
  waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$limit" ]; then
      say "    (no answer after ${limit}s — sending SIGTERM)"
      kill -TERM "$pid" 2>/dev/null
      sleep 5
      kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      RUN_RC=124
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
  RUN_RC=$?
  return 0
}

# One daemon run. $1 = timeout, $2… = argv for refresh.mjs (may be empty).
run_daemon() {
  limit="$1"; shift
  say "    node $REFRESH_CLI $*"
  run_bounded "$limit" node "$REFRESH_CLI" "$@"
  if [ "$RUN_RC" -eq 124 ]; then
    fail "the daemon did not finish within ${limit}s" \
      "expected: an exit within this tier's bound (${limit}s)" \
      "found:    still running — SIGTERM, then SIGKILL" \
      "the app's own spawn timeout is 180s, so a run this slow would fail there too;" \
      "raise the bound with E2E_TIMEOUT (tier 0/1) or E2E_LOGIN_TIMEOUT (tier 2) if" \
      "this machine is genuinely slow rather than stuck"
  fi
}

assert_exit() {
  if [ "$RUN_RC" -ne "$1" ]; then
    fail "the daemon exited $RUN_RC" \
      "expected: exit $1 ($2)" \
      "found:    exit $RUN_RC (0 fresh · 2 needs-login · 1 error · 124 timeout)" \
      "status.json now says: $(status_line)"
  fi
  ok "exit $1"
}

# ─────────────────────────────────────────────────────────────────────────────
# Reading the artifacts
# ─────────────────────────────────────────────────────────────────────────────

# One field of status.json, or "" when the file is missing/corrupt/absent-key.
# Values arrive by environment, never argv, so a path with spaces (and the real
# root has two) cannot be mis-split.
status_field() {
  E2E_FILE="$STATUS_FILE" E2E_KEY="$1" node --input-type=module -e '
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
    "$(status_field state)" "$(status_field rungUsed)" "$(status_field error)"
}

assert_status() {
  found_state="$(status_field state)"
  found_rung="$(status_field rungUsed)"
  if [ ! -f "$STATUS_FILE" ]; then
    fail "no status.json was written" \
      "expected: $STATUS_FILE with state=$1 rungUsed=$2" \
      "found:    the file does not exist"
  fi
  if [ "$found_state" != "$1" ] || [ "$found_rung" != "$2" ]; then
    fail "status.json does not describe the run this tier asked for" \
      "expected: state=$1 rungUsed=$2" \
      "found:    state=${found_state:-<unreadable>} rungUsed=${found_rung:-<unreadable>}" \
      "error:    $(status_field error)" \
      "file:     $STATUS_FILE"
  fi
  ok "status.json: state=$1 rungUsed=$2 (lastSuccessAt=$(status_field lastSuccessAt))"
}

# mtime in milliseconds — seconds resolution is not enough to prove a rewrite
# when two runs land in the same second. "0" when the file is not there.
mtime_ms() {
  E2E_FILE="$1" node --input-type=module -e '
    import { statSync } from "node:fs";
    try { process.stdout.write(String(Math.trunc(statSync(process.env.E2E_FILE).mtimeMs))); }
    catch { process.stdout.write("0"); }
  ' 2>/dev/null
}

# data.json holds a payload the menu bar could actually render, stamped inside
# this run's window. $1 = epoch seconds when the run started.
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
    // Two minutes of slack at each end absorbs clock skew, not staleness: a
    // cache from the last run would miss this window by hours.
    if (stamped < since - 120000 || stamped > Date.now() + 120000) {
      bad("data.json was not written by THIS run",
        `fetchedAt within the run window (since ${new Date(since - 120000).toISOString()})`,
        `${payload.fetchedAt} — the daemon wrote no new cache, or preserved an old one`);
    }

    const courses = payload.courses;
    if (!Array.isArray(courses)) bad("courses is not an array", "an array of course objects", typeof courses);
    if (courses.length === 0) {
      bad("the cache holds no courses", "at least one course (the menu would be empty)", "courses: []");
    }

    for (const course of courses) {
      if (!Number.isInteger(course.id) || course.id <= 0) {
        bad("a course has a bad id", "a positive integer id", JSON.stringify(course.id));
      }
      if (typeof course.name !== "string" || course.name.length === 0) {
        bad(`course ${course.id} has no name`, "a non-empty name", JSON.stringify(course.name));
      }
    }

    const ids = new Set(courses.map((course) => course.id));
    if (ids.size !== courses.length) {
      bad("course ids repeat", `${courses.length} unique ids`, `${ids.size} unique of ${courses.length}`);
    }

    const withItems = Object.keys(payload.assignments ?? {}).length;
    console.log(`    ok: data.json fresh — ${courses.length} courses (${withItems} with items), fetchedAt ${payload.fetchedAt}`);
  '
  if [ $? -ne 0 ]; then
    fail "data.json did not satisfy the file contract" "see the expected/found above"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# The Swift half, and the app step a human has to do with their eyes
# ─────────────────────────────────────────────────────────────────────────────

swift_live() { ( cd "$SWIFT_DIR" && BS_LIVE=1 exec swift test ); }

run_swift_half() {
  step "Swift half — BS_LIVE=1 swift test (spawns the real daemon against this root)"
  if [ -n "${BRIGHTSPACEBAR_STUB:-}" ]; then
    fail "BRIGHTSPACEBAR_STUB is set in this environment" \
      "expected: unset — the live run must read the real daemon cache" \
      "found:    BRIGHTSPACEBAR_STUB=$BRIGHTSPACEBAR_STUB"
  fi
  if [ -z "${BSB_REFRESH_CLI:-}" ] && [ "$REFRESH_CLI" != "$HOME/PaperShelf/session-capture/src/refresh.mjs" ]; then
    say "    note: swift resolves its own CLI default ($HOME/PaperShelf/session-capture/src/refresh.mjs),"
    say "          which is NOT the one this script ran ($REFRESH_CLI)."
  fi
  run_bounded "$SWIFT_TIMEOUT" swift_live
  if [ "$RUN_RC" -ne 0 ]; then
    fail "BS_LIVE=1 swift test did not pass (exit $RUN_RC)" \
      "expected: the daemon sources satisfy the contract suite against $ROOT" \
      "found:    exit $RUN_RC — scroll up for the failing case" \
      "run it alone with: cd $SWIFT_DIR && BS_LIVE=1 swift test"
  fi
  ok "BS_LIVE=1 swift test passed"
}

# Printed, never executed: the last mile is David's eyes on the menu bar.
print_app_step() {
  cat <<EOF

--- MANUAL: see the courses in the menu bar (not automated, do it once) ---
  cd $SWIFT_DIR && ./Scripts/run.sh

  \`open -n\` does NOT inherit this shell's environment, so if you are running
  against a non-default root, run.sh's launch will read the PRODUCTION root.
  For a rehearsal root, launch one of these instead:

    BSB_ROOT="$ROOT" $SWIFT_DIR/.build/debug/BrightspaceBar
    open -n --env BSB_ROOT="$ROOT" $SWIFT_DIR/.build/debug/BrightspaceBar.app

  BRIGHTSPACEBAR_STUB must NOT be set, or the menu shows fabricated courses.
  Expected: the real course list, served from $DATA_FILE.
  Stop it with: pkill -f 'BrightspaceBar.app/Contents/MacOS/BrightspaceBar'
---------------------------------------------------------------------------
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# The tiers
# ─────────────────────────────────────────────────────────────────────────────

# Tier 2 — from nothing. The only tier that spends a human and an MFA, and the
# only one that destroys anything. Preconditions are checked BEFORE the wipe:
# discovering a missing password after deleting the wristband would strand the
# root with no way back that is not another tier 2.
tier2() {
  step "TIER 2 — from an empty root: headed login, one MFA, David present"

  say ""
  say "  DESTRUCTIVE. This deletes everything inside:"
  say "      $ROOT"
  say "    - profile/      the ~90-day Entra wristband (tier 1 needs it; this is the cost)"
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

  # The full-login rung tries silent SSO first and, when that fails, autofills
  # these two. It does NOT let a human type them into the window: with them
  # unset it returns "silent SSO failed and BS_EMAIL/BS_PASSWORD are not set"
  # and the ladder is exhausted (exit 2). After a --all wipe the profile is
  # gone, so silent SSO CANNOT succeed — which makes them mandatory here.
  if [ -z "${BS_EMAIL:-}" ] || [ -z "${BS_PASSWORD:-}" ]; then
    say "REFUSED: tier 2 needs BS_EMAIL and BS_PASSWORD in the environment." >&2
    say "         The full rung autofills them; it never waits for typing." >&2
    say "         Nothing has been deleted. Re-run as:" >&2
    say "           BS_EMAIL='you@purdue.edu' BS_PASSWORD='…' scripts/e2e.sh tier2 --yes" >&2
    exit 2
  fi
  ok "BS_EMAIL is set (${#BS_EMAIL} chars) and BS_PASSWORD is set (${#BS_PASSWORD} chars)"

  step "wiping the root: $RESET_SH --all"
  BSB_ROOT="$ROOT" "$RESET_SH" --all || fail "reset.sh --all failed" "the root was not emptied"

  cat <<EOF

  WHAT HAPPENS NEXT — read this before it starts:
    1. NO window opens — the login runs fully headless in the background.
    2. It fills in your email and password by itself.
    3. Microsoft shows a NUMBER. This script SHOUTS it at you (and, if the app
       is running, it appears on the menu-bar icon). Have your phone ready:
       approve the sign-in and type that number into the Authenticator prompt.
    4. If it offers "Stay signed in?" the script clicks Yes — that is the
       wristband every later tier-1 run lives on.
    5. Then ~55 requests fetch courses and assignments.
    (To watch the browser for debugging, re-run with BSB_FULL_HEADED=1.)
  Budget: up to ${LOGIN_TIMEOUT}s in total. Do not close the terminal.

EOF

  started="$(date +%s)"
  step "running the full ladder: refresh.mjs --allow-full-login"
  run_daemon "$LOGIN_TIMEOUT" --allow-full-login
  assert_exit 0 "a fresh cache was written"
  assert_status fresh full
  assert_data_fresh "$started"

  # The wristband is the whole return on the MFA that was just spent: without a
  # profile directory left behind, every later tier-1 run is another tier 2.
  [ -d "$PROFILE_DIR" ] || fail "the login left no persistent profile behind" \
    "expected: $PROFILE_DIR (the ~90-day Entra wristband)" \
    "found:    nothing — tier 1 will have nothing to re-mint from"
  ok "the Entra profile survives at $PROFILE_DIR"

  say ""
  say "  The wristband is seeded — tier 1 and tier 0 are free from here."
  green tier2
}

# Tier 1 — the silent re-mint. Zero human input: this function must never read
# from stdin, and the daemon runs WITHOUT --allow-full-login so a headed window
# is impossible even if the wristband turns out to be dead.
tier1() {
  step "TIER 1 — credentials deleted, Entra profile kept: the silent rung re-mints"

  [ -d "$PROFILE_DIR" ] || skip "there is no Entra profile to re-mint from" \
    "expected: a persistent profile at $PROFILE_DIR" \
    "found:    nothing — run: scripts/e2e.sh tier2" \
    "(tier 1 without the wristband IS tier 2, and needs a human.)"

  # rm, not `reset.sh --session`: that mode deletes profile/ as well, which is
  # precisely the thing this tier is proving still works. Deleting it would turn
  # a free run into an MFA — and the silent rung would fail, correctly.
  step "deleting ONLY the credential file (the profile survives): rm -f $SESSION_FILE"
  rm -f "$SESSION_FILE" || fail "could not delete session.json" "check the permissions on $ROOT"
  [ -d "$PROFILE_DIR" ] || fail "the profile disappeared with the session file" \
    "expected: $PROFILE_DIR still present" "found: gone"
  ok "session.json is gone, profile/ is intact"

  started="$(date +%s)"
  step "running the cron-safe ladder: refresh.mjs (NO --allow-full-login)"
  run_daemon "$TIMEOUT"
  assert_exit 0 "the silent rung restored the session and the fetch succeeded"
  assert_status fresh silent
  assert_data_fresh "$started"

  [ "$WITH_SWIFT" -eq 1 ] && run_swift_half
  green tier1
}

# Tier 0 — the cheap one: credentials already good, so the ladder is never
# climbed at all (rungUsed "none") and the only claim is that the cache moved.
tier0() {
  step "TIER 0 — a live session in place: plain refetch, the ladder stays put"

  [ -f "$SESSION_FILE" ] || skip "there are no credentials to refetch with" \
    "expected: $SESSION_FILE" \
    "found:    nothing — run: scripts/e2e.sh tier2 (or tier1 if the profile exists)"

  state="$(status_field state)"
  if [ "$state" = "needs-login" ]; then
    skip "the last run ended in needs-login — the session on disk is dead" \
      "expected: state=fresh in $STATUS_FILE" \
      "found:    state=needs-login" \
      "run: scripts/e2e.sh tier1 (silent re-mint), or tier2 if that skips too"
  fi

  before="$(mtime_ms "$DATA_FILE")"
  say "    data.json mtime before: $before"
  started="$(date +%s)"

  step "running: refresh.mjs (NO flag — nothing may open a window)"
  run_daemon "$TIMEOUT"
  assert_exit 0 "the existing credentials still work"
  assert_status fresh none
  assert_data_fresh "$started"

  after="$(mtime_ms "$DATA_FILE")"
  if [ "$after" -le "$before" ]; then
    fail "data.json was not rewritten" \
      "expected: an mtime later than $before" \
      "found:    $after — the run reported fresh but the cache did not move" \
      "file:     $DATA_FILE"
  fi
  ok "data.json mtime advanced: $before → $after"

  [ "$WITH_SWIFT" -eq 1 ] && run_swift_half
  green tier0
}

# ─────────────────────────────────────────────────────────────────────────────
# Argv, preflight, go
# ─────────────────────────────────────────────────────────────────────────────

TIER=""
ASSUME_YES=0
WITH_SWIFT=0

[ "$#" -ge 1 ] || usage
for arg in "$@"; do
  case "$arg" in
    tier0|tier1|tier2|all) [ -z "$TIER" ] || usage; TIER="$arg" ;;
    --yes) ASSUME_YES=1 ;;
    --with-swift) WITH_SWIFT=1 ;;
    --help|-h) usage ;;
    *) say "unknown argument: $arg" >&2; usage ;;
  esac
done
[ -n "$TIER" ] || usage

say "session ladder E2E — $TIER"
say "  root:        $ROOT"
say "               ($ROOT_ORIGIN)"
say "  daemon CLI:  $REFRESH_CLI"
say "  swift half:  $([ "$WITH_SWIFT" -eq 1 ] && echo "yes — BS_LIVE=1 swift test in $SWIFT_DIR" || echo "no (pass --with-swift)")"
say "  bounds:      unattended ${TIMEOUT}s · headed login ${LOGIN_TIMEOUT}s · swift ${SWIFT_TIMEOUT}s"

command -v node >/dev/null 2>&1 || fail "node is not on PATH" "expected: a node binary" "found: none"
[ -f "$REFRESH_CLI" ] || fail "the daemon CLI is missing" \
  "expected: a file at $REFRESH_CLI" "found: nothing (BSB_REFRESH_CLI overrides this path)"
[ -x "$RESET_SH" ] || [ ! "$TIER" = "tier2" ] || fail "reset.sh is not executable" \
  "expected: an executable $RESET_SH" "found: not executable"

case "$TIER" in
  tier0) tier0 ;;
  tier1) tier1 ;;
  tier2) tier2 ;;
  all)
    # Seeding order: tier 2 fills the root, then each cheaper tier consumes what
    # the one above it left. Reversing this would run tier 0 against a root that
    # tier 2 is about to delete.
    TIER=tier2; tier2
    TIER=tier1; tier1
    TIER=tier0; tier0
    TIER=all
    print_app_step
    green all
    ;;
esac

[ "$TIER" = "all" ] || print_app_step
