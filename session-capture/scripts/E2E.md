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

## The MFA-icon E2E — `scripts/e2e-icon.sh`

The BUILD 2 acceptance run: the number Entra shows lands on the **status-bar
icon**, David types it into Authenticator, and the icon goes back to the logo.
It is `tier2` plus the icon claim — same cost (one MFA, the root is wiped, the
wristband is re-seeded), same artifact-only discipline.

```sh
cd ~/PaperShelf/BrightspaceBar && ./Scripts/run.sh      # the app must already be running
cd ~/PaperShelf/session-capture
BS_EMAIL='you@purdue.edu' BS_PASSWORD='…' scripts/e2e-icon.sh --yes
```

What it does, in order: check the preconditions (credentials, a running app) →
wipe the root → start `refresh.mjs --allow-full-login` in the **background** →
poll for `cache/mfa.json` → the instant it appears, print an unmissable banner
with the number and measure the icon → wait for the login → assert exit 0,
`mfa.json` **gone**, the icon back to logo width, `status.json` `fresh`/`full`,
a fresh non-empty `data.json`, and `profile/` re-seeded.

The banner is the point: the number it shouts is read from `mfa.json`, and the
icon must be showing that same number. Look up before you touch your phone —
the badge is only good for **60 seconds** (`MfaBadge.ttl`), whatever the phone
is doing.

### The icon witness

`screencapture` is TCC-denied in the session this was written in, so the
automated evidence is the status item's **window geometry**: `ICON_WITNESS`
points at a helper that prints BrightspaceBar's window bounds (logo ≈ 30pt
wide, a two-digit badge ≈ 62pt). Three readings — before the wipe, with the
number live, after the login — give two assertions: the item **grew** for the
badge, and **shrank back** afterwards. When the helper is missing or prints no
status-item window, both checks report `skipped: no witness` and the run can
still green. **David's eyes are the primary verification**; the witness only
catches a regression when nobody is looking.

### Exit codes and preconditions

Same alphabet as `e2e.sh`: **0** green · **1** an assertion failed · **2** usage
or a refused wipe · **3** a precondition is not met. One deliberate difference:
missing `BS_EMAIL`/`BS_PASSWORD` is a **3** here (a precondition, like the app
not running), where `e2e.sh tier2` calls it a refusal (**2**). Both check before
deleting anything.

The script never launches the app: `run.sh` rebuilds, which is not a test
script's decision. If nothing is running it prints the command and exits 3.

Note that the running app polls on its own every 15 minutes without
`--allow-full-login`. Such a tick cannot touch `mfa.json` (the full rung is
skipped before it is entered), but it *can* overwrite `status.json` with
`needs-login` while the root is empty — a `status.json` assertion that fails
that way is a collision, not a regression. Re-run.

| Variable | Meaning |
|---|---|
| `ICON_WITNESS` | the window-geometry helper. Missing → the width checks skip. |
| `ICON_MFA_TIMEOUT` | seconds to wait for `cache/mfa.json`, default 90. |
| `ICON_LOGIN_TIMEOUT` | seconds for the whole run, default 600 (mostly your phone). |
| `ICON_REQUIRE_APP` | 1 (default) demands a running app; 0 is for rehearsals only. |

`BSB_ROOT` and `BSB_REFRESH_CLI` mean what they mean above, and rehearsing is
the same trick: a throwaway root plus a stub CLI that writes `mfa.json`, sleeps,
deletes it, writes a good cache and exits 0 (with `ICON_REQUIRE_APP=0`, since a
rehearsal has no icon).
