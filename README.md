# Brightspace Bar 📅 — No More Login. No More Friction.

[![CI](https://img.shields.io/github/actions/workflow/status/DavidChen-006/Brightspace-Bar/ci.yml?branch=main&label=ci)](https://github.com/DavidChen-006/Brightspace-Bar/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/DavidChen-006/Brightspace-Bar?label=release&color=orange)](https://github.com/DavidChen-006/Brightspace-Bar/releases/latest)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

Menu bar app for Brightspace (D2L). Never log in again. See every due date on
one calendar. Click a course. Go straight there. Agents can read your courses
and add assignments.

<img src="docs/screenshot.png" alt="Brightspace Bar menu" width="382">

## What it does

- **A heatmap per course** — each current course is a row with a
  GitHub-contributions-style grid of the coming weeks: darker squares mean
  heavier work (assignment < quiz < test), today is outlined.
- **An "All classes" aggregate** on top, folding every course's grid into one.
- **Hover a day, see the work** — a popup lists that day's items; clicking one
  opens it in a persistent, already-signed-in Chromium (each click adds a tab).
- **"This week" at a glance** — per-course counts and the next due item, right
  beside the grid.
- **Your own items** — add assignments/quizzes/tests with a date picker from
  each course's submenu; they render in the grid like fetched ones and delete
  with an ✕ from the popup.
- **Agent-native** — a `bsb` CLI and a matching skill let an AI agent read
  your courses, syllabi, files and grades through the app's own session and
  put syllabus dates on the heatmap. See [Agents](#agents).
- **Background refresh** every 30 minutes, silently, via a session the app
  never sees.

## How it stays safe

The app is two halves with a deliberate wall between them:

- A **Swift menu-bar app** that renders cached JSON. It contains no network
  code and no credentials — it cannot log in *by construction*.
- A **Node daemon** (`session-capture/`) that owns the browser session: a
  one-time interactive login into a persistent Chromium profile, then silent
  cookie/JWT renewal on a ladder that only escalates as far as it must.

Your email and password are typed into Microsoft's real login page in a real
(headless) Chromium. They live only in the daemon's world — `credentials.json`,
mode 0600, under `~/Library/Application Support/BrightspaceBar` — never in the
repo, never in logs, and never in the Swift process (invariant **D7**). The
app spawns the daemon with no arguments and lets it climb its whole ladder,
full login included, so a dead session heals itself from a timer tick; the
MFA number reaches you on the menu-bar icon (invariant **D8**). The daemon
attempts that full login at most once per four hours, so a night away is a
push or two, not a phone that will not stop.

## Supported

- macOS 14+
- Xcode Command Line Tools with Swift 6.2+ (`xcode-select --install`)
- Node 22+ (`brew install node`)
- Purdue Brightspace via Entra specifically — the SAML entityId is
  Purdue-hardcoded today; PRs generalising it are welcome.

This is a build-from-source app today — no binary release yet. The latest
tagged state is
[`v0.2.0`](https://github.com/DavidChen-006/Brightspace-Bar/releases/tag/v0.2.0)
([release notes](docs/release-notes-v0.2.0.md)).

## Quick Start

```sh
git clone https://github.com/DavidChen-006/Brightspace-Bar.git
cd BrightspaceBar
make setup    # checks prerequisites, installs the daemon's dependencies and the agent skill
make start    # THE one command — see below
```

`make start` does everything: it builds the app, prompts for your credentials
in the terminal on first run, launches the menu bar, and performs the headless
login — no browser window; the MFA verification number appears **on the
menu-bar icon**, you type it into Authenticator on your phone, and the icon
reverts. After that, the daemon refreshes the session silently for weeks. If
courses ever stop refreshing, run `make start` again.

There are two ways to sign in, and the rule for choosing is short:

- **`make start`** — the default. No browser window; the MFA number goes on
  the icon. Use it first, and every time after.
- **`make login`** — the same flow with the browser visible. Use it when
  `make start` put no number on the icon and the menu stayed empty, when
  your Microsoft sign-in is not an Authenticator number match (a text, a
  code, a "choose a method" page, a setup step), or when you simply want to
  watch the sign-in happen.

`make login` opens a Chromium window, types your stored credentials in for
you, and you finish whatever Microsoft asks in that window. It stores the
same credentials and writes the same session and browser profile as
`make start`, so everything after it — the silent refresh, the next
automatic login — works exactly as if the headless login had succeeded. Both
paths are tested end to end from an empty install.

Day to day, `make start` (or `make login`) is needed once. When the session
later dies, the app's own timer signs in again and puts the number on the
icon; you only run a command if that did not work for you, and then it is
`make login`. If you've quit the app and just want it back, `make run` is the
"reopen" gesture: build and launch, nothing else (there's no `.app` bundle to
double-click yet).

## Agents

The app is deterministic on purpose: it shows what the D2L API reports as
work. An AI agent can read a syllabus — and most professors put half their
deadlines there and nowhere else. `bsb` is the bridge:

```sh
./bsb courses                                  # your current courses and their ids
./bsb syllabus --course 1641791 --out ./syl    # overview text + every syllabus file, downloaded
./bsb work --course 1641791                    # what Brightspace already lists as due
./bsb add --course 1641791 --kind assignment --title "First Critical Response" --due 2026-10-19
./bsb add --batch items.json                   # many at once, validated as a whole
./bsb --help                                   # content, fetch, overview, grades, api, …
```

Items an agent adds appear on the heatmap the moment the file lands — no
relaunch, no click — and delete like hand-entered ones. The rules are
structural: every Brightspace call `bsb` makes is a GET, the only file it
writes is the app's own `manual-items.json`, and the bearer token never
leaves your tenant.

### The skill — how your agent learns this

An agent does not know `bsb` exists until it reads the skill in
[`skills/brightspace/`](skills/brightspace/SKILL.md): the commands,
the read endpoints, the write contract, and the syllabus-to-calendar recipe.
It follows the [Agent Skills](https://agentskills.io) format, so any agent
that reads skills can use it. Three ways to install it, pick one:

| You use… | Do this |
| --- | --- |
| `make setup` (already ran it) | Done — setup symlinks the skill into `~/.claude/skills`, `~/.agents/skills` and `~/.codex/skills`. `make skill` re-runs just that step. |
| Claude Code, Codex, Cursor, Gemini CLI, Copilot, OpenCode… without cloning | `npx skills add DavidChen-006/Brightspace-Bar` — the [skills](https://github.com/vercel-labs/skills) CLI installs it into each agent's skills folder. Run `make setup` in your checkout once, so the copied skill can find the CLI. |
| Claude Code inside this repo | Nothing — `.claude/skills/brightspace` is in the repo, so it is a project skill the moment you open the folder. |

Then start a new agent session and ask in plain words: "read my PHIL 219
syllabus and put the due dates on my calendar", or "what's due this week in
CS 252". In Claude Code you can also invoke it directly as
`/brightspace`. The skill tells the agent to show you the list before it
writes anything, and how you undo it.

### Environment configuration

See [`session-capture/.env.example`](session-capture/.env.example) for the
knobs. Normally you never touch env vars: credentials are entered once via the
`make start` prompt and stored with mode 0600 under
`~/Library/Application Support/BrightspaceBar` — never in the repo. When
`BS_EMAIL` and `BS_PASSWORD` are both set in the environment, they override
the stored file.

## Project layout

| Path | What it is |
| --- | --- |
| `BrightspaceBar/` | The Swift package: the menu-bar app and its modules (`Modules/<Name>/`), tests included |
| `session-capture/` | The Node daemon: login ladder, data fetch, deep-link opener — and `src/bsb.mjs`, the agent CLI |
| `skills/brightspace/` | The agent skill: how to use `bsb`, the read endpoints, the write contract |
| `bsb` | The CLI's entry point (`./bsb --help`) |
| `docs/` | Design documents |

The numbered `experiment-*` probes that de-risked each design decision live on
the [`experiments` branch](https://github.com/DavidChen-006/Brightspace-Bar/tree/experiments/experiments)
— kept as engineering notes, off the main tree.

## Architecture

The deep dive lives in [docs/architecture.md](docs/architecture.md) and
[BrightspaceBar/ARCHITECTURE.md](BrightspaceBar/ARCHITECTURE.md). The short
version, enforced by tests: the GUI imports only the `CourseMenu` contract
module; adapters translate between pipelines and the menu model; the
composition root is `main.swift`. See [CONTRIBUTING.md](CONTRIBUTING.md).

Looking for something to pick up? The
[open issues](https://github.com/DavidChen-006/BrightspaceBar/issues) include
`good first issue`s with acceptance criteria spelled out.

## Development

```sh
make -C BrightspaceBar build  # build the Swift app (or: cd BrightspaceBar && swift build)
make test                     # full suite, from the repo root
make -C BrightspaceBar run    # run the app from source
```

## License

[MIT](LICENSE).
