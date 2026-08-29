# Experiment 20 — the cookie transplant

**Question.** Can the daemon's `session.json` cookies (renewed every 30 min by
the refresh loop) be injected into a browser context so a page navigation lands
signed in **without touching Entra at all** — no SAML `initiate-login` wrap, no
SSO cookies, no KMSI?

**Why it matters.** The click path (`browser-open.mjs`) currently authenticates
via the profile's Entra SSO cookies. Those age on their own clock, and the
2026-08-24 headless login never landed `ESTSAUTHPERSISTENT` (KMSI didn't
persist), so every fresh browser launch hit Microsoft's password page while the
daemon's API fetches stayed green. Two sources of truth; one quietly dead.
If the transplant works, `session.json` becomes the **single** source of truth
and the browser a derivation of it.

**Falsifier.** D2L might bind the session to the client (the cookies were
minted by a Node HTTP client; the browser presents a Chromium UA). If bound,
the navigation bounces to `/d2l/login`.

**Method** (`probe.mjs`). A fresh **profile-less** context — deliberately, so
nothing but the injected cookies can explain a signed-in page — then
`context.addCookies()` with the four `session.json` cookies
(`d2lSessionVal`, `d2lSecureSessionVal`, two SameSite canaries) scoped to
`purdue.brightspace.com`, then `goto` the bare deep link.

**Result — CONFIRMED (2026-08-29).**

```
landed: https://purdue.brightspace.com/d2l/home
title:  Homepage - Purdue University System
login markers: 0 | navigation chrome: 56
```

`artifacts/landing.png` shows the homepage rendered signed-in ("David Chen" in
the header). No UA/fingerprint binding fired.

**Consequence.** `browser-open.mjs` should inject the current `session.json`
cookies before navigating and go straight to the deep link. Entra then matters
only to the daemon's ladder, and the click path can never see a login page
while the refresh loop is healthy. The SAML wrap can remain as a fallback for
a stale `session.json`.

Run it: `node probe.mjs` (needs a seeded `$BSB_ROOT/session.json`;
`node_modules` is a symlink into `../session-capture`).
