# Security Policy

BrightspaceBar handles university credentials. If you find a way to make it
mishandle them — or any other vulnerability — please report it privately.

## Reporting a vulnerability

**Preferred:** open a private security advisory via the repository's
**Security tab** on GitHub ("Report a vulnerability"). This keeps the report
between you and the maintainer until a fix ships.

Optionally, you may also email `<maintainer contact>`.
<!-- placeholder: replace with a real contact, or delete this line -->

Please do not open a public issue for security problems. You should hear back
within a few days; a fix or a mitigation plan within two weeks for anything
that touches credentials.

## Scope

Reports are especially welcome on:

- **Credential handling** — `session-capture/src/credentials.mjs` (the prompt,
  the 0600 `credentials.json`), the env-var override path, and anything that
  could log, echo, or exfiltrate an email/password.
- **The daemon** — the login ladder (`refresh.mjs`, `src/rungs/`), the session
  store (`session.json`, the Chromium `profile/`), and the cache it writes for
  the app.
- **The deep-link opener** — `src/browser-open.mjs` and the CDP tab-adding
  path (a localhost debug port on a signed-in browser is a sensitive surface).
- The Swift↔daemon boundary: any way for credential material to reach the
  Swift process or the `cache/` directory.

Out of scope: vulnerabilities in Brightspace/D2L or Microsoft Entra themselves
(report those to their vendors), and issues requiring an already-compromised
local account (files under `BSB_ROOT` are 0600 by design, not encrypted at
rest).

## Security model, briefly

- **D7 — credentials never leave the daemon's world.** The Swift menu-bar app
  contains no network code and no credential types; it renders cached JSON.
  Email/password live only in the Node daemon: in memory during a login, and
  in `credentials.json` (mode 0600) under
  `~/Library/Application Support/BrightspaceBar` — never in the repo, never in
  logs (lengths only), never in `cache/`.
- **D8 — the app can only run the cron-safe ladder.** No spawn from the app
  ever passes `--allow-full-login`; an interactive login is always
  human-initiated from a terminal.
- **MFA stays with Microsoft.** Sign-in happens on Microsoft's real Entra
  page in a real Chromium; this project never sees or handles the second
  factor, only displays the number-matching digits.

## Supported versions

| Version | Supported |
| ------- | --------- |
| v0.1.x  | yes       |
| earlier | no        |
