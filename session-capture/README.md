# session-capture

Gets a live Brightspace session **without ever handling your password.**

This is live tooling, not an experiment — it is the supply side of
`BrightspaceBar`'s `SessionProviding` seam, and the thing you run when the app
starts showing stale data.

## Use

```sh
npm run start       # what `make start` runs: credentials, app, one headless refresh
npm run login       # what `make login` runs: the same, with a VISIBLE browser window
npm run refresh     # one climb of the ladder, nothing else (the app's timer runs this)
npm run xsrf        # re-derive just the CSRF token for a still-live cookie
```

Everything lives under one root, `BSB_ROOT` (default
`~/Library/Application Support/BrightspaceBar`): the persistent Chromium
profile (`profile/`, a credential store — it holds the Microsoft Entra cookie
from your last real login, so most refreshes complete **silently in seconds**),
`session.json`, `credentials.json`, and the `cache/` the app renders.

`refresh.mjs` climbs the ladder: silent SSO on the profile first; if that is
dead, the full login types the stored credentials into Microsoft's page
headless and puts the MFA number on the menu-bar icon. `--visible` is the
same rung with a window, for the accounts whose sign-in the headless flow
cannot read (a method chooser, a code prompt, an MFA setup page): the
credentials are typed in for you, you finish the rest in the window, and the
profile and session file it writes are the ones every later refresh uses.

## `bsb` — the same session, opened to an agent

```sh
npm run bsb -- courses                       # or ../bsb courses from the repo root
npm run bsb -- syllabus --course 1641791 --out ./syl
npm run bsb -- add --course 1641791 --kind test --title "Final" --due 2026-12-14
npm run bsb -- --help
```

`src/bsb.mjs` is a second entry point of this package for AI agents (and
terminals). It reads the cache the daemon wrote, reads Brightspace through
the daemon's own `session.json` — GET only, `/d2l/api/` only, this tenant
only (`src/agent/api.mjs`) — and writes exactly one file, the app's
`manual-items.json`, after validating every item against the Swift decoder's
contract (`src/agent/manual-items.mjs`). `bsb refresh` runs `refresh.mjs`.
The skill that teaches an agent to use it lives in
`../skills/brightspace/`; `make skill` at the repo root installs it.

## How authentication is judged

Authentication is detected **positively** — the `d2lSessionVal` cookie must exist
*and* `window.D2L.LP` must be reachable. "The URL no longer looks like a login
page" is not a signal; the login stub sets cookies too.

**`refresh-xsrf.mjs`** exists because a session cookie alone is not enough. The
token mint (`POST /d2l/lp/auth/oauth2/token`) answers **`403 Not authenticated`**
when the `x-csrf-token` header is missing, even with a perfectly good cookie —
measured, not assumed. And the token is not always readable on whatever page an
SSO redirect happens to land on.

So rather than making you log in twice, this injects the saved cookie into a
headless browser, loads `/d2l/home` where D2L's JS context is fully initialised,
reads the token, and merges it back into `session.json`. No re-login, no MFA.
Useful on its own too: XSRF tokens rotate independently of the cookie.

## What we know about session lifetime

| Age | State |
|---|---|
| 4.4 h | alive |
| 15.6 h | dead — mint returned `200` + a `sessionExpired=1` HTML stub |
| 28.4 h | dead — mint returned a hard `403 Not authenticated` |

The D2L cookie dying daily no longer matters much: with the persistent
profile, a capture re-mints it silently for as long as the Entra session
lives. The Entra cookie claims 90 days; its *real* honored lifetime is being
measured by `experiment-10-entra-silent-sso`'s daily journal.

Note the two different death signatures on the same endpoint; code that keys on
status alone will misread one of them. Whether expiry is idle-based or absolute is
still unmeasured — it would take a fresh cookie polled on a schedule to find out.

## Files

```
src/start.mjs            make start / make login: credentials, app, one refresh
src/refresh.mjs          the daemon entry point: climb the ladder, exit 0/2/1
src/orchestrate.mjs      the ladder itself, behind injected seams
src/rungs/               silent.mjs, full-login.mjs, browser.mjs (playwright)
src/login-flow.mjs       silent SSO, the auth check, the XSRF read
src/session.mjs          the session.json contract, as pure functions
src/refresh-xsrf.mjs     live cookie -> fresh CSRF token, merged in place
src/bsb.mjs, src/agent/  the agent CLI
$BSB_ROOT/session.json   the capture. A CREDENTIAL — 0600, never committed
```
