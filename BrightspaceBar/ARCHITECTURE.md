# Brightspace Bar — how the app actually works

One Swift package, six modules, zero external dependencies. Each module lives in
`Modules/<Name>/` with its own `Sources/`, `Tests/`, and `Makefile`. Logging in
and fetching are not this package's job at all: a Node daemon next door
(`../session-capture`) owns both, and the app reads what it wrote.

## The map

```
┌─────────────────────────────────────────────────────────────────────┐
│                        main.swift  (composition root)               │
│      the ONE file allowed to see everything; wires the stack        │
└─────────────────────────────────────────────────────────────────────┘

  triggers                CoursePipeline            CourseMenu    Brightspace Bar
  launch / timer / manual (the backend)            (the contract)   (the GUI)
       │                                                 ↑              │
       ▼                                                 │   depends on │
  MenuAdapter ──► Poller ⇄ CourseCache ──► MenuModel ─────┴──────────────┘
       │          (PollPolicy decides)
       ▼
  DaemonCourseSource ──spawns──► node refresh.mjs ──writes──► $BSB_ROOT/cache/
  DaemonAssignmentSource ◄──────────────── reads ────────────────┘ (no spawn)
```

Arrows are the only dependencies that exist. **`BrightspaceBar` (the GUI) depends
on `CourseMenu` only** — it cannot name a cookie, a JWT, a `Course`, or
`URLSession`, because `Package.swift` does not grant it access and
`ArchitectureTests` fails if any view file tries. The GUI was built and tested
against `StubMenuDataSource` before the backend was ever attached, and that
remains possible today (`BRIGHTSPACEBAR_STUB=1`).

## The six modules

| Module | Owns | Key fact |
|---|---|---|
| `CoursePipeline` | Cache, poll, spawn: `PollPolicy`, `CourseCache`, `DaemonRunner`, `DaemonCourseSource`, `DaemonPaths`, `RefreshScheduler` | Pure decision functions (`PollPolicy`, `CourseCache.fold`) with the one spawn at the edge |
| `AssignmentPipeline` | A course's work items: `AssignmentFetcher` ⇄ `AssignmentStore`, `DaemonAssignmentSource` | Structurally spawn-free — it reads the cache the course fetch already wrote, so 27 courses cost 27 file reads and no extra process |
| `QuizPipeline` | `QuizParser`, `QuizLink` | The merge moved to the daemon; what stayed is the deep-link template and a parser the tests use against recorded payloads |
| `CourseMenu` | The backend↔GUI contract: `MenuModel`, `MenuRow`, `MenuDataSource` | Plain `Equatable` values. This *is* the API — in types, not JSON (nothing serializes) |
| `MenuAdapter` | The wiring: `[Course] → MenuModel`, URL derivation, staleness line | The only module that sees both sides |
| `BrightspaceBar` | `NSStatusItem`, `NSMenu` rendering, `main.swift` | `main.swift` must stay **synchronous at top level** — a top-level `await` starves the MainActor and blanks the menu (real bug, documented in the file) |

There is no session module any more. Credentials never enter Swift (LADDER-PLAN
D7), so there is no credential type here to leak.

## One fetch, end to end

1. A trigger fires: `launch()` at startup, `timerTick()` every 30 minutes
   (`RefreshScheduler`), or `refresh()` from the Refresh click. Each maps to its
   own `PollTrigger` — manual always fetches, launch/timer only when stale.
2. `DaemonCourseSource` spawns `/usr/bin/env node <refresh.mjs>` with `BSB_ROOT`
   in the child's environment (`BSB_REFRESH_CLI` overrides which CLI), 180s
   timeout, stderr to a temp file — never a `Pipe`, which deadlocks once a
   chatty child fills the buffer. **No argument is ever added** (D8): the app
   cannot tell a click from a timer at the source, so every spawn it can make is
   cron-safe and can never open a login window with nobody present.
3. The daemon climbs its ladder — existing credentials → silent Entra SSO →
   headed login (that last rung only when a human passed `--allow-full-login` in
   a terminal) — fetches courses, assignments and quizzes, and atomically writes
   `$BSB_ROOT/cache/data.json` + `status.json`. Exit `0` fresh · `2` needs-login
   · `1` unexpected; a failed run never truncates an existing `data.json`.
4. `DaemonCache` reads both files fresh, every time — a daemon run landing while
   the app is up takes effect on the next fetch, no relaunch. Exit 2 or a
   `needs-login` status becomes `.sessionExpired`; a success that wrote no cache
   becomes `.malformedBody`, because a failure that reads as an empty course
   list would blank the menu.
5. `CourseCache.fold` decides what survives: success → `.updated`/`.unchanged`
   (+ atomic write to `~/Library/Caches/BrightspaceBar/courses.json`); **any
   failure → `.preservedStale`** — the menu keeps its courses and shows an honest
   staleness line. Failure can never blank the menu.
6. `MenuAdapter` snapshots cache + clock through `MenuTranslation` into a
   `MenuModel`; `MenuAssembler` renders it; unchanged models skip the rebuild
   (`Equatable`).

`currentMenu()` (menu open) serves memory/disk only — there is deliberately no
code path from it to a socket, and now not to a subprocess either.

## Sessions: someone else's problem now

The D2L cookie still dies in hours (measured alive at 4.4h, dead at 15.6h). What
changed is who handles it. The daemon holds a persistent Chromium profile and a
`session.json` under `$BSB_ROOT`, both 0600, both daemon-only, and climbs the
ladder itself when the cookie is dead. The app spawns it and reads `cache/`.

The ladder, the rung seam, and the file contracts are specified in
[`../docs/LADDER-PLAN.md`](../docs/LADDER-PLAN.md); the daemon lives in
`../session-capture/`. Open item, written down rather than pretended away: a
headed login can only be started from a terminal
(`npm run refresh -- --allow-full-login`), so a session that has fallen past the
silent rung shows stale data until David runs it.

## Tests (518, hermetic by default)

`swift test` needs no network, no cookie, and no daemon. Time is injected
(`Clock` protocol; `TestClock` advances by hand — nothing may call `Date()`
except `SystemClock`), and the daemon is faked with a stub CLI writing canned
cache files. `BS_LIVE=1` (`make live`) adds the live-tenant runs, which spawn the
**real** daemon (cron-safe) and therefore need a `BSB_ROOT` a login has already
seeded — they are the app half of tiers 0 and 1 in
`../session-capture/scripts/e2e.sh`, which drives the whole ladder end to end
and asserts on artifacts only.

Two suites enforce structure, not behavior: `ArchitectureTests` reads import
lines so view code can never see backend modules, and the contract suites run
fake and real sources through the same assertions.

## Provenance

Built from the experiment chain in the repo root — exp 1 (cookie capture), exp 2
(cookie→JWT mint), exp 3 (no ETags exist; polling must be interval-based), exp 4
(pipeline), exp 5 (GUI + contract), exp 10 (concurrent Entra profiles do not
revoke each other, which is what makes hermetic test roots safe). Those folders
remain as runnable references; this app is a consolidation, not a link against
them. The Swift network path they seeded — cookie handling, JWT mint, the
enrollment/dropbox/quiz fetches — was deleted once the daemon passed the same
contract suites.
