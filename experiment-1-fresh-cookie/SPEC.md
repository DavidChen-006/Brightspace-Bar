# Experiment 1 — Acquire a fresh Brightspace session cookie via headed Entra SSO

## Hypothesis

Playwright can drive a **headed** Chromium through Purdue's Microsoft Entra ID login
(email + password typed automatically, MFA approved by the human on their phone) and
capture a **fresh** Brightspace session cookie plus the XSRF token, using a
**non-persistent** browser context (no `userDataDir`).

## Why non-persistent

The MCP codebase uses `launchPersistentContext` with a `userDataDir` and has produced
three `~/.d2l-session/browser-data.corrupted.*` directories on this machine. A
non-persistent context (`chromium.launch()` + `browser.newContext()`) eliminates that
failure mode and guarantees the captured session is new. Verified working:
headed launch, Chromium 145.0.7632.6, clean close.

## Scope

- This folder only. **Never write to `../brightspace-mcp-server`** — read it freely for
  reference (`src/auth/browser-auth.ts`, `src/auth/entra-sso.ts` are the relevant files).
- Runtime: Node ESM JavaScript (`.mjs` / `"type": "module"`). No TypeScript.
- Test runner: vitest.

## Credentials — never written to disk

Read from the environment at run time:

- `BS_EMAIL`
- `BS_PASSWORD`

If either is missing, the test must fail fast with a clear message. Do **not** create a
`.env` file, do not hardcode, do not log the password (mask it if it must appear).

## Output contract (consumed by Experiment 2)

On success write `artifacts/session.json`:

```json
{
  "capturedAt": 1786230000000,
  "baseUrl": "https://purdue.brightspace.com",
  "cookieHeader": "d2lSessionVal=...; d2lSecureSessionVal=...",
  "cookies": [{ "name": "d2lSessionVal", "value": "..." }],
  "csrfToken": "b02i...",
  "landedUrl": "https://purdue.brightspace.com/d2l/home"
}
```

`capturedAt` is ms epoch. `cookieHeader` is ready to use as an HTTP `Cookie` header
value. This file holds live credentials — it stays in `artifacts/`, never in git
(PaperShelf is not a git repo).

## How to capture the two values

Both techniques already exist in the MCP codebase; read them rather than inventing:

- **Cookies** — `await context.cookies(baseUrl)`, filter for `d2lSessionVal` and
  `d2lSecureSessionVal`. Reference: `browser-auth.ts:782` (`extractCookieToken`).
- **XSRF token** — `await page.evaluate(() => D2L.LP.Web.Authentication.Xsrf.GetXsrfToken())`.
  Reference: `browser-auth.ts:714` (`extractXsrfToken`). Fall back to the
  `meta[name="d2l-xsrf-token"]` tag if the JS global is absent.

## Login flow requirements

1. Launch headed (`headless: false`). Never headless — MFA needs a human.
2. Navigate to `https://purdue.brightspace.com/d2l/home`.
3. Expect a redirect to Microsoft (`login.microsoftonline.com`). Type `BS_EMAIL`,
   submit, type `BS_PASSWORD`, submit.
4. **Then wait for the human.** MFA (Microsoft Authenticator number-match or push) must
   be approved on the user's phone. There may also be a "Stay signed in?" prompt — the
   human may click it, or the test may click "Yes". Log clearly what the user must do.
5. Poll until the URL settles on a real Brightspace page (`/d2l/home`) — do not conclude
   success from an early `page.url()` read. Purdue serves a JS stub at `/d2l/home` that
   redirects to `/d2l/login`; see the fork's `navigateAndLogin()` notes in the README
   (change #4). Confirm authentication by a positive signal, not absence of a login URL.
6. Allow up to 5 minutes of human time. Do not fail early.

## Observability — a hard requirement, not a nicety

The user must be able to see exactly what happened and where it broke:

- Timestamped stderr log of every phase, every `framenavigated` URL, and every redirect.
- Screenshot at each phase and on any failure → `artifacts/NN-phase-name.png`.
- Capture page `console` messages and `pageerror` events.
- Log auth-relevant network requests (`login.microsoftonline.com`, `purdue.brightspace.com`)
  as `METHOD status url` — never log request bodies or headers containing secrets.
- On failure, dump: final URL, page title, visible text of the body (first ~500 chars),
  and the screenshot path.
- Write the full log to `artifacts/run.log` as well as stderr.

## Assertions — the test is green only if both hold

1. **It has the cookie.** `d2lSessionVal` and `d2lSecureSessionVal` are both present and
   non-empty; `csrfToken` is present and non-empty.
2. **The cookie is fresh.** All three of:
   - `capturedAt` falls within this test run (record the run's start time and assert
     `capturedAt >= runStart`);
   - the context was non-persistent and newly created, so the value cannot be a carried-over
     session — assert the cookie value differs from any value in a pre-existing
     `artifacts/session.json` from a prior run, if one exists;
   - the cookie is **live right now**: `GET {baseUrl}/d2l/api/lp/1.62/users/whoami` with
     only the `Cookie` header returns HTTP 200 and a JSON body containing an `Identifier`.

Assertion 2's third clause is the one that actually matters — it proves the captured
cookie is usable, not merely present.

## Deliverables

- `package.json` (`"type": "module"`, pinned `playwright@1.58.2`, `vitest@^4.0.18`)
- The test file, e.g. `tests/fresh-cookie.e2e.test.mjs`, with a ≥300s test timeout
- Whatever implementation module the test drives (keep it small — a single
  `src/acquire-session.mjs` exporting one function is ideal)
- `README.md`: the one command to run it, and what the human must do during the run
