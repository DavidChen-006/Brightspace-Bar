#!/bin/bash
#
# reset.sh — put BSB_ROOT back to a known state, so an E2E tier can be staged.
#
#   --cache    drop the course cache      (the app forgets what it knew)
#   --session  drop credentials + profile (forces the ladder to climb)
#   --all      empty the root entirely    (a first-ever run)
#
# Tier 1 of the tiered E2E is literally "--session, then prove the daemon
# re-mints silently", so precision matters in both directions: over-delete and
# a cheap tier-1 run turns into an MFA prompt; under-delete and the tier passes
# for the wrong reason.
#
# Deletion only — this script never writes, and never reaches outside the root
# (rm and find are both given paths INSIDE it, and neither follows a symlink
# out, so a link planted in the root loses the link and nothing else).
set -eu

# Duplicated from src/paths.mjs, which owns the layout — a shell script cannot
# import it. If the default root moves, it moves in both places.
ROOT="${BSB_ROOT:-$HOME/Library/Application Support/BrightspaceBar}"

usage() {
  cat >&2 <<EOF
Usage: scripts/reset.sh --cache | --session | --all

  --cache    delete cache/ (data.json + status.json)
  --session  delete session.json and profile/
  --all      delete everything inside the root, keeping the root

Acts on BSB_ROOT (currently: $ROOT). Deletes nothing without one of the modes.
EOF
}

# A deletion tool with a garbled target is the one thing worse than no tool.
case "$ROOT" in
  /) echo "reset.sh: refusing to act on / " >&2; exit 2 ;;
  /*) ;;
  *) echo "reset.sh: BSB_ROOT must be an absolute path (got: $ROOT)" >&2; exit 2 ;;
esac

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi

case "$1" in
  --cache)
    rm -rf "$ROOT/cache"
    echo "reset: cache cleared ($ROOT/cache)"
    ;;
  --session)
    rm -f "$ROOT/session.json"
    rm -rf "$ROOT/profile"
    echo "reset: credentials cleared (session.json + profile/) — the ladder must climb"
    ;;
  --all)
    if [ -d "$ROOT" ]; then
      find "$ROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    fi
    echo "reset: root emptied ($ROOT)"
    ;;
  *)
    echo "reset.sh: unknown mode: $1" >&2
    usage
    exit 2
    ;;
esac
