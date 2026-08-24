# Experiment 2 — Cookie → JWT → authenticated GET (pure HTTP)

Proves that a Brightspace session cookie + XSRF token can mint a fresh 60-minute
JWT and call the Valence REST API using **only** Node's built-in `fetch` — no
Playwright, no browser.

## Prerequisite

Run **Experiment 1** first. It produces the session this experiment consumes:

    ../experiment-1-fresh-cookie/artifacts/session.json

The test reads that path by default; override it with the `SESSION_JSON` env var.

## Run

    npm install
    npm test

Or against an explicit session file:

    SESSION_JSON=../experiment-1-fresh-cookie/artifacts/session.json npm test

## What it checks (green only if all hold)

1. Mint returns 200 with an `access_token`.
2. JWT decodes; `scope === "*:*:*"`, lifetime is 3600s, `exp` is in the future.
3. `whoami` returns 200 **and** `Identifier === sub` — the strongest proof the
   token is genuinely ours and accepted.
4. `myenrollments` returns 200 with an `Items` array.
5. Playwright is never a dependency (asserted structurally against `package.json`).

Three secondary questions are also determined and written to
`artifacts/findings.json` (is the CSRF header required, is the mint repeatable,
can a fresh XSRF token be pulled from `/d2l/home` over plain HTTP). They are
recorded, not gated on.

Logs: `artifacts/run.log` (timestamped per-stage; never contains the cookie,
CSRF token, or full JWT — length and decoded claims only).

## Quirk: a 200 is not proof of success

When the cookie is dead, the token endpoint (and `/d2l/home`) do **not** return
401/403. They return **HTTP 200** with an HTML stub that JS-redirects to
`/d2l/login?sessionExpired=1`. So every success check requires more than the
status: a mint succeeded only if an actual `access_token` came back, and the
findings record whether a 200 was really that sessionExpired stub
(`csrfOmittedWasSessionStub`, `freshXsrfWasSessionStub`).

## Red-verification fixture

`artifacts/fixture-session.json` holds **fake** values and exists solely to prove
the test is red for the right reason (the unimplemented seam), not because an
input file is missing:

    SESSION_JSON=./artifacts/fixture-session.json npm test

The real run uses Experiment 1's `session.json`, not this fixture.
