# Experiment 2 — Cookie → JWT → authenticated GET, over plain HTTP only

## Hypothesis

Given only a Brightspace session cookie and an XSRF token, a **pure HTTP** client (no
Playwright, no browser, no Chromium) can mint a fresh 60-minute JWT and use it to call
the Valence REST API.

This has already been confirmed once by hand. The mechanism:

```
POST https://purdue.brightspace.com/d2l/lp/auth/oauth2/token
content-type: application/x-www-form-urlencoded
cookie: d2lSessionVal=...; d2lSecureSessionVal=...
x-csrf-token: ...

scope=*:*:*
```

→ `200 OK`, `{"access_token": "<812-char JWT>", "expires_at": <unix seconds>}`

The observed JWT had `sub: 375951`, `scope: *:*:*`, and a lifetime of exactly 60 minutes
(`exp - nbf == 3600`). No `refresh_token` is returned.

## Scope

- This folder only. **Never write to `../brightspace-mcp-server`** — read it freely
  (`src/api/client.ts` shows the header-building and 401/403 handling).
- **Playwright must not be imported.** If this test needs a browser, the experiment has
  failed. Use Node's built-in `fetch`.
- Runtime: Node ESM JavaScript (`.mjs`). Test runner: vitest.

## Input contract (produced by Experiment 1)

Read `../experiment-1-fresh-cookie/artifacts/session.json`, overridable via the
`SESSION_JSON` env var. Shape:

```json
{
  "capturedAt": 1786230000000,
  "baseUrl": "https://purdue.brightspace.com",
  "cookieHeader": "d2lSessionVal=...; d2lSecureSessionVal=...",
  "csrfToken": "...",
  "landedUrl": "..."
}
```

If the file is missing, fail fast: "Run experiment 1 first."

## The three stages to prove

1. **Mint** — POST the token endpoint exactly as above. Assert HTTP 200 and an
   `access_token` in the response.
2. **Decode** — base64url-decode the JWT payload (middle segment; pad with `=`, and
   translate `-`→`+`, `_`→`/`). Assert `scope === "*:*:*"`, `exp - nbf === 3600`, and
   that `exp` is in the future.
3. **Spend** — call a **non-destructive GET** with `Authorization: Bearer <jwt>`:
   `GET {baseUrl}/d2l/api/lp/1.62/users/whoami`

   Assert HTTP 200 and that the response `Identifier` **equals the JWT's `sub` claim**.
   That cross-check is the strongest available proof the token is genuinely ours and
   genuinely accepted — not merely that some 200 came back.

   Then one real-data GET as a second, weaker check:
   `GET {baseUrl}/d2l/api/lp/1.62/enrollments/myenrollments/?orgUnitTypeId=3&isActive=true`
   Assert HTTP 200 and that the body has an `Items` array. Log the course count and the
   `OrgUnit.Id` + `OrgUnit.Name` of each. Do not assert a specific count.

**GET only.** No POST/PUT/DELETE against `/d2l/api/**` — the only POST permitted in this
experiment is the token-mint call itself, which creates nothing user-visible.

## Secondary questions worth answering in the same run

These are cheap and decide the real architecture. Report results; do not fail the test
on them — assert only that the answer was determined.

- **Is `x-csrf-token` required?** Repeat the mint with the header omitted. Record the
  status. If it still returns 200, the stored recipe is cookie-only.
- **Is the mint repeatable?** Mint twice. Record whether the two JWTs differ and whether
  both validate. (Confirms the cookie is reusable, not single-use.)
- **Can a fresh XSRF token be obtained over plain HTTP?** `GET {baseUrl}/d2l/home` with
  only the cookie, then search the HTML for an XSRF token (look for
  `meta[name="d2l-xsrf-token"]` or a `XSRF`/`Xsrf` JS assignment). If found, the CSRF
  token is derivable from the cookie alone and need not be stored.

Write findings to `artifacts/findings.json` and echo them in the test output.

## Observability

- Timestamped stderr log of each stage: method, URL, status, byte count, elapsed ms.
- Never log the cookie, the CSRF token, or the full JWT. Log the JWT's **length** and its
  decoded claims (`sub`, `scope`, `exp`, `nbf`) only.
- On any non-2xx, log the status, the response headers of interest
  (`content-type`, `x-request-id`), and the first ~300 chars of the body.
- Write the full log to `artifacts/run.log`.

## Assertions — green only if all hold

1. Mint returns 200 with an `access_token`.
2. JWT decodes; `scope === "*:*:*"`; lifetime is 3600s; `exp` is in the future.
3. `whoami` returns 200 **and** `Identifier === sub`.
4. `myenrollments` returns 200 with an `Items` array.
5. Playwright is never imported (assert this structurally if you can — e.g. the test
   asserts no `playwright` entry in this folder's `package.json` dependencies).

## Deliverables

- `package.json` (`"type": "module"`, `vitest@^4.0.18`, **no playwright**)
- `tests/cookie-to-jwt.e2e.test.mjs`
- A small `src/mint-and-call.mjs` with the two functions (`mintJwt`, `callApi`)
- `README.md`: the one command to run it, and the prerequisite that experiment 1 ran first
