# Brightspace Bar v0.2.0

The first release that is usable day to day: the login heals itself, and an
AI agent can read your courses and put syllabus dates on the calendar.

## What's new

- **Self-healing login (D8 inverted).** The app now spawns the daemon with no
  arguments and lets it climb its whole ladder, full login included, so a
  dead session recovers from an ordinary 30-minute tick. The MFA number
  reaches you on the menu-bar icon. The full login runs at most once every
  four hours, so a night away is a push or two, not a phone that will not
  stop.
- **An agent surface: `bsb` and the `brightspace-bar` skill.** `./bsb` is a
  second entry point of the daemon that reads Brightspace through the app's
  own session — courses, what is due, announcements, the table of contents,
  any content file, the course overview, grades, and any other read route —
  and adds assignments, quizzes and tests to the heatmap. The skill in
  `skills/brightspace-bar/` (Agent Skills format) teaches an agent all of it,
  including the syllabus-to-calendar recipe. It installs three ways: `make
  setup`, `npx skills add DavidChen-006/Brightspace-Bar`, or nothing at all
  inside the repo. Invariant **D9**: every Brightspace call `bsb` makes is a
  GET, the only file it writes is the app's own `manual-items.json`, and no
  cookie, CSRF token or bearer token ever appears in its output.
- **Hot repaint.** Items that land in `manual-items.json` — from `bsb add`
  or anything else — appear on the heatmap the moment the file is written.
  No relaunch, no click.
- **Clicks sign in from the session, not from Entra.** A click transplants
  the daemon's D2L cookies into the view browser and opens the raw deep link,
  which fixes the password page that used to appear when the profile's Entra
  cookies aged out.
- **The Motion P** replaces the placeholder book icon, as a template image
  that tints correctly in Light Mode, Dark Mode and while the menu is open.
- **Term codes read as seasons** — "Fall 2026 All classes" instead of a raw
  `202710` header row — and the hairlines sit between courses only.

## Upgrading from v0.1.0

- **Node 22 or newer is required** (Node 20 reached end of life on
  2026-04-30). `make setup` checks and says so.
- Run `make setup` again: it installs the daemon's dependencies, links the
  skill into `~/.claude/skills`, `~/.agents/skills` and `~/.codex/skills`,
  and records the checkout's path for a copied skill to find.
- Nothing on disk changes shape. `cache/data.json` and `manual-items.json`
  are read as before; `status.json` gains one field, the last full-login
  attempt.

## How your credentials are handled

Unchanged, and now with a third wall. Credentials are typed once at the
`make start` prompt, stored with mode `0600` under
`~/Library/Application Support/BrightspaceBar`, and never committed, never
logged, and never passed into the Swift app (D7). The app never caps the
daemon's ladder, so recovery needs no terminal (D8). The agent surface reads
only and writes only the app's own item list (D9).

## Known limitations

- **Build-from-source only** — no prebuilt `.app` binary yet. Requires macOS
  14+, Swift 6.2+ (Command Line Tools), and Node 22+.
- **Purdue-specific** — the SAML entityId is hardcoded to Purdue's Entra IdP.
  Other D2L schools are not yet supported (contributions welcome).
- The `bsb` command set is new; flags may still move before 1.0.

## What kind of contributions we're looking for

Generalising the login beyond Purdue, a signed binary release, a transparent
menu background, and quieting the ended-course 403 noise. See the open issues
and `CONTRIBUTING.md`.
