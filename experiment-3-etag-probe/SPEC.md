# Experiment 3 — Does Brightspace support HTTP conditional requests?

## Question

RepoBar keeps polling cheap by sending `If-None-Match: <etag>` and accepting `304 Not
Modified`. Does the D2L Valence API give us that lever at all?

Three possible outcomes, all useful:

- **A. Full support** — responses carry `ETag`, and a conditional re-request returns `304`
  with an empty body. Cheap polling is available.
- **B. Header present, ignored** — `ETag` (or `Last-Modified`) comes back, but a
  conditional re-request still returns `200` with the full body. The header is decorative;
  no savings.
- **C. Absent** — no validator headers at all. Cache by timestamp instead.

There is no "right" answer to hunt for. Report what is true.

## Scope

- **This folder only.** Self-contained so it can be deleted wholesale. Never write to
  `../brightspace-mcp-server`, `../experiment-1-fresh-cookie`, or `../experiment-2-cookie-to-jwt`
  — read them freely.
- **No Playwright, no browser.** Node built-in `fetch` only.
- **GET only** against `/d2l/api/**`. The single permitted POST is the token mint itself.
- Runtime: Node ESM (`.mjs`). Runner: vitest. No new dependencies beyond vitest.

## Input

Read `../experiment-1-fresh-cookie/artifacts/session.json` (override with `SESSION_JSON`).
Reuse the proven mint/call code — import from
`../experiment-2-cookie-to-jwt/src/mint-and-call.mjs` rather than rewriting it.

### The cookie may be dead — that is a result, not a failure

`session.json` was captured 2026-08-08 ~18:44 local. If the mint now fails, you have
measured **cookie lifetime**, which is a genuinely open question in this project.

Remember: **Brightspace signals auth failure as HTTP 200 plus an HTML stub containing
`sessionExpired=1`, never 401.** Detect that explicitly — do not treat a 200 as success.

If the cookie is dead: write `artifacts/findings.json` with
`{ "outcome": "SESSION_EXPIRED", "capturedAt": ..., "diedWithinMs": ..., "ageHours": ... }`,
log loudly that Experiment 1 must be re-run, and make the suite **skip** (not fail) the
ETag assertions. Report the age in hours — that is the number worth knowing.

## Probes — run against each of these endpoints

```
/d2l/api/lp/1.62/users/whoami
/d2l/api/lp/1.62/enrollments/myenrollments/?orgUnitTypeId=3&isActive=true
/d2l/api/versions/
```

`myenrollments` is the one that actually matters (it backs the course list); the other two
tell us whether behaviour is endpoint-specific or tenant-wide.

For each endpoint:

1. **Baseline GET** with `Authorization: Bearer <jwt>`. Record status, byte count, elapsed
   ms, and these response headers verbatim if present: `etag`, `last-modified`,
   `cache-control`, `expires`, `vary`, `age`, `x-request-id`, `content-encoding`.
2. **Conditional by ETag** — only if an `etag` came back. Repeat the GET with
   `If-None-Match: <etag exactly as received, quotes and any W/ prefix preserved>`.
   Record status and byte count.
3. **Conditional by date** — only if `last-modified` came back. Repeat with
   `If-Modified-Since: <value exactly as received>`. Record status and byte count.
4. **Bogus validator control** — repeat with `If-None-Match: "definitely-not-a-real-etag"`.
   Expect `200`. If this returns `304`, the server is broken/ignoring the value and any
   `304` above is meaningless. This control is what separates outcome A from a false
   positive.

Classify each endpoint as `FULL_SUPPORT`, `HEADER_IGNORED`, or `NO_VALIDATOR`, and derive
one overall verdict. Quantify the saving: baseline bytes vs conditional bytes, and the
percentage avoided.

## Assertions — green means "we determined the answer", not "ETags work"

1. The JWT minted, **or** the run correctly identified `SESSION_EXPIRED`.
2. Every endpoint produced a baseline result with a recorded status.
3. Every endpoint carries a classification from the three allowed values.
4. An overall verdict exists and is one of `FULL_SUPPORT`, `HEADER_IGNORED`,
   `NO_VALIDATOR`, `MIXED`.
5. If any `304` was observed, the bogus-validator control for that endpoint returned
   `200` — i.e. the `304` is trustworthy.

Do **not** assert that ETags are supported. Outcome C is a perfectly green run.

## Observability

- Timestamped stderr line per request: `METHOD path → status, N bytes, M ms`.
- Never log the cookie, the CSRF token, or the JWT body — JWT length only.
- Dump the full recorded header set per endpoint into the log.
- Write `artifacts/findings.json` and `artifacts/run.log`.

## Deliverables

- `package.json` (`"type": "module"`, `vitest@^4.0.18`, no other deps)
- `src/etag-probe.mjs` — the probe logic, exporting a callable function
- `tests/etag.e2e.test.mjs`
- `README.md` — the one command to run it, the Experiment 1 prerequisite, and a
  **Findings** section stating the verdict in plain language plus what it implies for
  refresh strategy (cheap conditional polling vs timestamp cache).
