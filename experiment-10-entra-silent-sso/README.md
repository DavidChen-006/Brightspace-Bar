# Experiment 10 — can a persistent Entra session silently mint D2L sessions?

## The hypothesis

Every earlier capture script launched an **amnesiac** browser (no
`userDataDir`), so the Microsoft Entra session — the long-lived credential
that "Stay signed in? → Yes" creates — was destroyed on every run. If instead
the browser profile persists, a dead D2L cookie should be renewable with
**zero human input**, because the SSO redirect completes against the still-live
Entra session:

```
Entra cookie → (silent SSO) → d2lSessionVal → (page load) → XSRF
             → (POST mint) → JWT → (Bearer) → whoami 200
```

Two questions, in order:

1. **Is the lineage real?** Does a dead D2L cookie + live Entra cookie
   actually produce a fresh authenticated session with no password, no MFA?
2. **For how long?** The MCP fork's README claims ~7-day re-auth windows —
   a claim, not a measurement. The journal measures it: the `hoursSinceSeed`
   of the first `password-required`/`mfa-required` outcome is the real number.

## Run it

```sh
npm install

npm run seed      # ONCE: headed browser, YOU log in fully.
                  # Click YES on "Stay signed in?" — that page IS the experiment.

npm run attempt   # DAILY (or whenever): headless, zero-human. Classifies and journals.
HEADED=1 npm run attempt   # same, but watch it happen
```

`seed` records which Entra cookies the profile now holds (names + expiry only)
and warns if `ESTSAUTHPERSISTENT` — the persistent one — is missing.

`attempt` navigates to `/d2l/home` and classifies what happens:

| Outcome | Meaning |
|---|---|
| `already-alive` | D2L cookie still valid; SSO never exercised. Rerun after ~15h. |
| `silent-sso` | **The hypothesis confirmed**: dead D2L cookie, Microsoft visited, landed authenticated, no human. |
| `password-required` | Entra session dead — this timestamp bounds the wristband's life. |
| `mfa-required` | Password skipped but number-match demanded — partial silence. |
| `stalled` | Unclassified; screenshot saved for diagnosis. |

On any authenticated outcome it proves the rest of the chain live: XSRF read →
JWT minted (`POST /d2l/lp/auth/oauth2/token`) → `whoami` called with the
Bearer token. A `silent-sso` line with `whoamiStatus: 200` is the full
zero-human lineage in one JSON record.

## Reading the journal

`artifacts/journal.jsonl`, one line per event. The success story is a run of
`silent-sso` lines with growing `hoursSinceSeed`, ended by the first
`password-required` — that gap is the Entra session's true lifetime, and
therefore the real MFA cadence (k) any automation can achieve without TOTP.

## Secrets discipline

- `artifacts/profile/` **is a credential store** (live Entra + D2L cookies).
  Gitignored; never commit, never copy elsewhere.
- The journal and console never contain cookie values, tokens, or JWTs —
  outcomes, statuses, names, and lengths only.
- The only click the headless script allows itself is "Stay signed in? → Yes",
  which involves no secret.

## Relationship to the app

This is disposable measurement tooling. If the hypothesis holds, the live
consequence is small and lands in `session-capture/`: capture scripts adopt a
persistent profile, and a cron probe runs the attempt logic to keep
`session.json` fresh — MFA recurring only at the wristband's own cadence.
