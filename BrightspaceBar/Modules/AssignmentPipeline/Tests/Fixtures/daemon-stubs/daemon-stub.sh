#!/bin/sh
#
# The stub daemon — a stand-in for `node src/refresh.mjs` that the Swift tests
# spawn instead of the real thing. Deliberately dumb: it does what
# `$BSB_ROOT/plan.txt` tells it to, and records what it was handed so a test can
# make claims about the spawn without a browser, a network, or even node
# installed (CI without node still runs the whole Swift suite).
#
#   plan.txt line 1   the mode (default "ok")
#   plan.txt line 2   that mode's argument: stderr text, or seconds to sleep
#
# The modes mirror the daemon's real contract (LADDER-PLAN, "File contracts"):
#
#   ok            publish the staged cache files, exit 0        (fresh)
#   ok-no-data    exit 0 having written nothing                 (a liar)
#   needs-login   publish the staged STATUS only, exit 2 — a failed run must
#                 never touch an existing data.json
#   error         print to stderr, exit 1                       (unexpected)
#   hang          sleep, then leave a marker; proves the timeout kills the child
#   chatty        flood stdout AND stderr past any pipe buffer, then exit 0
#
# Evidence left in $BSB_ROOT for the tests: recorded-root.txt, recorded-args.txt
# and spawns.txt (incremented once per run — the counter that proves the
# assignment source never spawns).
#
# No `set -u`: macOS /bin/sh is bash 3.2, where `"$@"` with no arguments trips
# the unbound-variable check.

root="${BSB_ROOT:-}"
if [ -z "$root" ]; then
  echo "stub daemon: BSB_ROOT was not passed through" >&2
  exit 1
fi
mkdir -p "$root/cache"

printf '%s\n' "$root" > "$root/recorded-root.txt"
: > "$root/recorded-args.txt"
for arg in ${1+"$@"}; do
  printf '%s\n' "$arg" >> "$root/recorded-args.txt"
done

spawns=0
if [ -f "$root/spawns.txt" ]; then spawns=$(cat "$root/spawns.txt"); fi
echo $((spawns + 1)) > "$root/spawns.txt"

mode="ok"
argument=""
if [ -f "$root/plan.txt" ]; then
  mode=$(sed -n 1p "$root/plan.txt")
  argument=$(sed -n 2p "$root/plan.txt")
fi

publish_data() {
  if [ -f "$root/next-data.json" ]; then
    cp "$root/next-data.json" "$root/cache/data.json"
  fi
}

publish_status() {
  if [ -f "$root/next-status.json" ]; then
    cp "$root/next-status.json" "$root/cache/status.json"
  fi
}

case "$mode" in
  ok)
    publish_data
    publish_status
    exit 0
    ;;
  ok-no-data)
    exit 0
    ;;
  needs-login)
    publish_status
    exit 2
    ;;
  error)
    if [ -n "$argument" ]; then
      echo "$argument" >&2
    else
      echo "the ladder broke" >&2
    fi
    exit 1
    ;;
  hang)
    sleep "${argument:-5}"
    : > "$root/finished.txt"
    exit 0
    ;;
  chatty)
    publish_data
    publish_status
    # ~1.3KB per line by doubling, then 200 lines to each stream: comfortably
    # past the ~64KB pipe buffer a `Pipe` + `waitUntilExit()` deadlocks on.
    chunk="0123456789"
    i=0
    while [ $i -lt 7 ]; do
      chunk="$chunk$chunk"
      i=$((i + 1))
    done
    i=0
    while [ $i -lt 200 ]; do
      printf '%s\n' "$chunk"
      printf '%s\n' "$chunk" >&2
      i=$((i + 1))
    done
    exit 0
    ;;
  *)
    echo "stub daemon: unknown mode '$mode'" >&2
    exit 1
    ;;
esac
