# session-capture

Gets a live Brightspace session **without ever handling your password.**

This is live tooling, not an experiment — it is the supply side of
`BrightspaceBar`'s `SessionProviding` seam, and the thing you run when the app
starts showing stale data.

## Use

```sh
npm run capture     # silent if possible; otherwise YOU sign in, including MFA
npm run auto        # silent if possible; otherwise types BS_EMAIL/BS_PASSWORD for you
npm run xsrf        # re-derive just the CSRF token for a still-live cookie
```

Both capture scripts run on a **persistent browser profile**
(`artifacts/profile/`, gitignored — it is a credential store). The profile
keeps the Microsoft Entra cookie (`ESTSAUTHPERSISTENT`, ~90-day lifetime) from
your last real login, so most captures complete **silently in seconds** — the
dead D2L session re-mints itself through SSO with no password and no MFA
(proven in `../experiments/experiment-10-entra-silent-sso`). You are only asked to sign in
when the Entra session itself has expired.

Then install it into the app:

```sh
cd ../BrightspaceBar && ./Scripts/refresh-session.sh ../session-capture/artifacts/session.json
```

The app re-reads that file on every fetch, so a running app picks up a fresh
session on its next poll — no relaunch needed.

## Why two capture scripts

Both try the silent path first; they differ only in the **fallback** when a
real login is due:

**`manual-capture.mjs`** waits for YOU. You pick your campus, type your
credentials, and approve MFA yourself. Nothing is typed for you and no
credential is ever read, stored, or logged — which makes it the only capture
path safe to run from an agent's shell. It is also the closer analogue of
where the app is heading: an in-app `WKWebView` login window where the user
signs in and the app only reads the resulting cookie store.

**`auto-capture.mjs`** (ported from `../experiments/experiment-1-fresh-cookie`, which stays
frozen as the experiment record) types `BS_EMAIL`/`BS_PASSWORD` for you, so a
full login costs only the MFA tap on your phone. Credentials are demanded only
*after* the silent path has actually failed — a cron can run it with no
environment at all, and it only errors on the rare day a real login is due.
The cost: a password in the environment lands in shell history and in the
transcript of any agent that invokes it. Prefer `capture` from an agent's
shell.

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
measured by `../experiments/experiment-10-entra-silent-sso`'s daily journal.

Note the two different death signatures on the same endpoint; code that keys on
status alone will misread one of them. Whether expiry is idle-based or absolute is
still unmeasured — it would take a fresh cookie polled on a schedule to find out.

## Files

```
src/session.mjs          the session.json contract, as pure functions
src/manual-capture.mjs   headed browser + human login -> session.json
src/refresh-xsrf.mjs     live cookie -> fresh CSRF token, merged in place
artifacts/session.json   the capture. A CREDENTIAL — gitignored, never committed
```

`node_modules` is a symlink to `../experiments/experiment-1-fresh-cookie`'s Playwright install so
there is one 300 MB browser download in this repo, not two. `npm install` here
works if that ever breaks.
