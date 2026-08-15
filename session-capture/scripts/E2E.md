# E2E runbook — the tiered session-ladder run

`scripts/e2e.sh` is the phase-4 acceptance test from `LADDER-PLAN.md`. It runs the
real daemon against the real tenant and asserts only on artifacts: the exit code,
`cache/status.json`, `cache/data.json`, and file mtimes.

| Tier | Precondition | What it proves | Human cost |
|---|---|---|---|
| `tier0` | `session.json` present, last status not `needs-login` | live credentials still fetch; the cache advances (`rungUsed: none`) | none |
| `tier1` | `profile/` present (the Entra wristband) | the silent rung re-mints a deleted `session.json` (`rungUsed: silent`) | none |
| `tier2` | none — it wipes the root | the headed login climbs from nothing (`rungUsed: full`) | **one MFA, David present** |

Exit codes: **0** green · **1** an assertion or step failed · **2** usage or a
refused wipe · **3** skipped, the precondition is not met (not a failure).

## Before tier 2 — read this

- **`BS_EMAIL` and `BS_PASSWORD` are mandatory for tier 2.** The full-login rung
  (`src/rungs/browser.mjs:60-64`) tries silent SSO first and, when that fails,
  *autofills* those two variables. It never waits for a human to type them: with
  them unset it returns "silent SSO failed and BS_EMAIL/BS_PASSWORD are not set",
  the ladder is exhausted, and the daemon exits 2. After the `--all` wipe the
  profile is gone, so silent SSO cannot succeed — hence mandatory. The script
  checks for them *before* deleting anything and refuses (exit 2) if they are
  missing.
- **Tier 2 deletes the production credentials**: `profile/`, `session.json`, and
  `cache/`. The menu bar has nothing to show until the run finishes. It requires
  `--yes`, or typing `WIPE` at the prompt when stdin is a terminal.
- The MFA number appears **in the Chromium window**; approve it on the phone.
  Answer **Yes** to "Stay signed in?" — that is the ~90-day wristband every later
  tier-1 run depends on. Tier 2 fails if no `profile/` is left behind.

## Commands

```sh
cd ~/PaperShelf/session-capture

# tier 2 — the one that costs an MFA. David present.
BS_EMAIL='you@purdue.edu' BS_PASSWORD='…' scripts/e2e.sh tier2 --yes

# tier 1 — silent re-mint, zero human input
scripts/e2e.sh tier1
scripts/e2e.sh tier1 --with-swift      # + BS_LIVE=1 swift test

# tier 0 — plain refetch, zero human input
scripts/e2e.sh tier0
scripts/e2e.sh tier0 --with-swift

# everything, in seeding order (tier2 → tier1 → tier0); needs --yes
BS_EMAIL='you@purdue.edu' BS_PASSWORD='…' scripts/e2e.sh all --yes --with-swift
```

`--with-swift` runs `BS_LIVE=1 swift test` in `BrightspaceBar/`, which spawns the
real daemon (cron-safe, no `--allow-full-login`) against the same root. It cannot
pass until a tier-2 login has seeded that root.

## When a tier skips (exit 3)

- `tier0` skipped, no `session.json` → run `tier1`, or `tier2` if that skips too.
- `tier0` skipped, status is `needs-login` → the credential on disk is dead; run `tier1`.
- `tier1` skipped, no `profile/` → the wristband is gone; this is tier 2 territory.

## The manual last mile

The script prints, but never runs, the app check. `open -n` does **not** inherit
the shell environment, so a non-default root needs the binary or an explicit
`--env`:

```sh
cd ~/PaperShelf/BrightspaceBar && ./Scripts/run.sh          # production root
BSB_ROOT="$ROOT" .build/debug/BrightspaceBar                # rehearsal root
open -n --env BSB_ROOT="$ROOT" .build/debug/BrightspaceBar.app
```

`BRIGHTSPACEBAR_STUB` must not be set, or the menu renders fabricated courses.
Done means: the real course list, served from `cache/data.json`.

## Environment

| Variable | Meaning |
|---|---|
| `BSB_ROOT` | root under test. **Unset = the production root**, which is what tiers are for. Set it to a throwaway directory to rehearse. |
| `BSB_REFRESH_CLI` | daemon entry point, default `src/refresh.mjs`. Same override the Swift app honours. |
| `E2E_TIMEOUT` | bound on an unattended daemon run, default 180s (the app's own spawn timeout — a run the app tolerates must not fail here). |
| `E2E_LOGIN_TIMEOUT` | bound on the tier-2 headed login, default 600s (the rung waits up to 5 minutes for the MFA). |
| `E2E_SWIFT_TIMEOUT` | bound on `swift test`, default 900s (it may build first). |

`timeout(1)` is not on a stock macOS, so the bounds are a background PID plus
SIGTERM-then-SIGKILL.

## Rehearsing without a tenant

Point both dials away from production and hand it a stub CLI that writes canned
cache files into `$BSB_ROOT/cache/`:

```sh
export BSB_ROOT="$(mktemp -d)"
export BSB_REFRESH_CLI=/path/to/stub-refresh.mjs
BS_EMAIL=x@y.edu BS_PASSWORD=z scripts/e2e.sh all --yes
```

The stub must write `data.json` (`fetchedAt` = now, non-empty `courses` with
unique positive ids), `status.json` (`state`, `rungUsed`), `session.json`, and a
`profile/` directory, then exit 0. That is exactly what the assertions read.
