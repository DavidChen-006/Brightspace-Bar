# Experiment 1 — fresh Brightspace session cookie via headed Entra SSO

## Run it

```sh
BS_EMAIL='you@purdue.edu' BS_PASSWORD='your-password' npm test
```

Credentials are read from the environment only — no `.env`, nothing written to disk.

## What you must do while it runs

1. A **headed Chromium window opens**, picks **Purdue West Lafayette / Indianapolis**
   on the campus selector, and types your email and password into the Microsoft
   login automatically. Don't touch it.
2. **Approve the MFA prompt in Microsoft Authenticator on your phone** (push or
   number-match — the number to match is shown in the browser window).
3. If a **"Stay signed in?"** page appears, the run may click "Yes" itself; if it
   sits there, click **Yes**.
4. Wait until the browser lands on Brightspace and closes. You have up to
   5 minutes; the test will not fail early while waiting for you.

## Output

On success: `artifacts/session.json` (live session cookie + CSRF token — consumed
by Experiment 2; never commit it), plus `artifacts/run.log` and per-phase
screenshots `artifacts/NN-phase-name.png`.
