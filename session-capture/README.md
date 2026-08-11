# session-capture

Gets a live Brightspace session **without ever handling your password.**

This is live tooling, not an experiment — it is the supply side of
`BrightspaceBar`'s `SessionProviding` seam, and the thing you run when the app
starts showing stale data.

## Use

```sh
npm run capture     # opens a browser; YOU sign in, including MFA
npm run xsrf        # re-derive just the CSRF token for a still-live cookie
```

Then install it into the app:

```sh
cd ../BrightspaceBar && ./Scripts/refresh-session.sh ../session-capture/artifacts/session.json
```

The app re-reads that file on every fetch, so a running app picks up a fresh
session on its next poll — no relaunch needed.

## Why two scripts

**`manual-capture.mjs`** opens a headed Chromium at the tenant and then just
waits. You pick your campus, type your credentials, and approve MFA yourself.
Nothing is typed for you and no credential is ever read, stored, or logged.

That is the point. `experiment-1-fresh-cookie` automates the whole login, which
means it needs `BS_EMAIL` and `BS_PASSWORD` in the environment — fine when a human
runs it, but it puts a password into shell history and into the transcript of any
agent that invokes it. This path has no password to leak. It is also the closer
analogue of where the app is heading: an in-app `WKWebView` login window where the
user signs in and the app only reads the resulting cookie store.

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

`node_modules` is a symlink to `experiment-1-fresh-cookie`'s Playwright install so
there is one 300 MB browser download in this repo, not two. `npm install` here
works if that ever breaks.
