# Security Policy

Brightspace Bar handles university credentials. If you find a way to make it
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
- **The agent surface** — `bsb` (`session-capture/src/bsb.mjs`,
  `src/agent/api.mjs`): any way to make it send a non-GET to the tenant,
  send the bearer token to another host, reach a path outside `/d2l/api/`,
  write a file other than `manual-items.json`, or surface a cookie, CSRF
  token or bearer in its output. A `Content-Disposition` that steers a
  download outside the target directory counts too.

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
- **D8 — the app never caps the daemon's ladder.** No spawn from the app
  ever passes `--no-full-login`; the daemon climbs to the full headless login
  on its own, and rate-limits it to one attempt per four hours so an
  unattended machine cannot flood a phone with MFA pushes. The opt-out exists
  for callers that must never reach a phone (the live test suites).
- **MFA stays with Microsoft.** Sign-in happens on Microsoft's real Entra
  page in a real Chromium; this project never sees or handles the second
  factor, only displays the number-matching digits.
- **D9 — agents read Brightspace, and write only the bar.** The `bsb` CLI
  an AI agent uses has no way to send anything but a GET to the tenant, only
  under `/d2l/api/` on the session's own origin; the one file it writes is
  the app's `manual-items.json`. An agent with shell access already has the
  session files — `bsb` adds no new exposure of them and prints none of
  their contents.

## Supported versions

| Version | Supported |
| ------- | --------- |
| v0.1.x  | yes       |
| earlier | no        |
