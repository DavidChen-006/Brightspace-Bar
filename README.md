# BrightspaceBar

Experiments validating a simpler authentication path for a Brightspace (D2L) MCP
server. Two experiments, both green, that together show JWT renewal needs no
browser.

## The problem

The reference implementation
([RohanMuppa/brightspace-mcp-server](https://github.com/RohanMuppa/brightspace-mcp-server),
MIT) renews its 60-minute Brightspace API JWT by launching a headless Chromium
every hour and evaluating
`D2L.LP.Web.Authentication.OAuth2.GetToken()` in the page context. That is
roughly 1,300 lines of browser machinery on the hot path, and in practice it
corrupts its own persistent browser profile.

## The finding

That JavaScript call is a plain HTTP request underneath:

```
POST /d2l/lp/auth/oauth2/token
cookie: d2lSessionVal=…; d2lSecureSessionVal=…
x-csrf-token: …

scope=*:*:*
```

Response: `{ access_token, expires_at }`.

So JWT renewal is one HTTP POST. No browser, no page context, no Chromium.

## Resulting architecture

A browser is needed **once per session** — the interactive SSO + MFA flow,
roughly weekly — to obtain the session cookie and CSRF token. Every JWT renewal
after that is a single HTTP POST against the stored cookie.

## Experiment 1 — fresh cookie (`experiment-1-fresh-cookie/`)

Headed Playwright drives the real login: Purdue's campus selector →
`sso.purdue.edu` SAML → Microsoft Entra → Authenticator MFA approved by the
human on their phone. Runs in a **non-persistent** browser context (no profile
to corrupt) and captures a fresh session cookie plus the XSRF token.

Result: **2/2 green**, ~31s wall clock including human MFA approval.

## Experiment 2 — cookie to JWT (`experiment-2-cookie-to-jwt/`)

Pure HTTP, no Playwright: cookie → JWT → authenticated GET.

Result: **8/8 green**. Verified `whoami.Identifier === jwt.sub` and retrieved 27
real course enrollments.

## Findings

Measured, not inferred:

- **`x-csrf-token` is required.** Omitting it is refused.
- **The cookie is reusable.** Repeated mints return different, valid JWTs.
- **A fresh XSRF token could not be re-fetched over plain HTTP** with only the
  two session cookies, so the CSRF token must be persisted alongside the cookie.
  (Untested hypothesis for why: the `d2lSameSiteCanaryA`/`B` cookies were not
  captured.)
- **Brightspace returns HTTP 200 on auth failure, not 401.** The body is an HTML
  stub containing `sessionExpired=1`. Any refresh implementation keying on
  `res.status === 200` will silently treat an expired session as success. Every
  check in these experiments keys on token/JSON presence instead.
- **The JWT lifetime is exactly 3600s, and no `refresh_token` is ever issued.**
  The session cookie is the only renewable credential.

## Unmeasured

How long the session cookie actually remains valid is **not known**. Re-running
experiment 2 periodically against the same `session.json` until it fails would
establish it.

## Security notes

`artifacts/session.json` is gitignored because it holds a live credential (an
active session cookie and CSRF token). Only `fixture-session.json`, which
contains fake values, is committed. These experiments run against the author's
own account only.

## Credit

Reference implementation:
[RohanMuppa/brightspace-mcp-server](https://github.com/RohanMuppa/brightspace-mcp-server)
(MIT).
