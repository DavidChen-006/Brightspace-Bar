# Brightspace Bar v0.1.0

The first working baseline — a macOS menu-bar app for Purdue Brightspace, run
from source.

## What it does

- A GitHub-style due-date heatmap per current course, plus an "All classes"
  aggregate on top.
- Hover a day to see that day's items; click one to open it in a persistent,
  already-signed-in Chromium (each click adds a tab).
- A "This week" summary beside each grid; add your own assignments/quizzes/tests
  with a date picker and delete them with an ✕.
- One command — `make start` — prompts for your credentials once, launches the
  app, and performs a fully headless login. When Microsoft asks for MFA
  number-matching, the number appears **on the menu-bar icon**; you approve on
  your phone. The session then refreshes silently in the background.

## How your credentials are handled

Credentials are typed once at the `make start` prompt, stored with mode `0600`
under `~/Library/Application Support/BrightspaceBar`, and never committed, never
logged, and never passed into the Swift app (invariant D7). The app only ever
spawns the daemon in its non-interactive mode (invariant D8).

## Known limitations

- **Build-from-source only** — no prebuilt `.app` binary yet. Requires macOS
  14+, Swift 6.2+ (Command Line Tools), and Node 20+.
- **Purdue-specific** — the SAML entityId is hardcoded to Purdue's Entra IdP.
  Other D2L schools are not yet supported (contributions welcome).
- **No screenshot in the README yet.**
- A click that fires during the periodic background refresh (which briefly
  holds the browser profile) is dropped with a clear message; rare and
  self-healing.

## What kind of contributions we're looking for

Generalising the login beyond Purdue, a binary release pipeline, a nicer app
icon, and quieting the ended-course 403 noise. See the good-first-issues and
`CONTRIBUTING.md`.
