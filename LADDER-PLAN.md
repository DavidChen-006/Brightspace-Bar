# LADDER-PLAN — the session ladder + daemon build

**This file is the ground truth.** Every subagent brief references it; every phase
checks back against it. Add nuances as they're discovered — never rewrite the
phases themselves without David's say-so.

## The success story (what "done" means)

A timer (or launch, or David clicking Refresh) fires in the Swift app. The app
spawns the Node daemon. The daemon climbs the ladder — existing credentials →
rung 1 (silent Entra SSO) → rung 2 (headed login, David types the MFA number
from the browser into his phone) — then fetches courses + assignments with
David's own proven endpoints and atomically writes the data cache. The Swift
app reads the cache and renders it. Verified by a tiered E2E:

- **Tier 0** — live session in place → daemon refetches → cache updated. Zero human.
- **Tier 1** — credentials deleted, Entra profile kept → rung 1 re-mints silently → cache updated. Zero human.
- **Tier 2** — empty root → rung 2 headed login, David present → cache updated. One MFA (= one unit of k).

Each E2E run costs at most what its tier says. Tier 2 is run rarely by design.

## Architecture (the four parts)

```
SWIFT APP (BrightspaceBar)                NODE DAEMON (session-capture grows into it)
 triggers: launch / timer / manual        refresh.mjs (orchestrator entry, run-and-exit)
 DaemonCourseSource.fetchCourses()  ──spawns──►  ladder: creds → rung1 → rung2 (seams)
 DaemonAssignmentSource             ◄──reads──  fetcher: David's endpoints (JWT mint, enrollments, dropbox, quizzes)
 Poller / CourseCache / MenuAdapter                 │
 (ALL UNCHANGED — fold keeps                        ▼
  .preservedStale semantics)              BSB_ROOT/cache/data.json + status.json  (data, app-readable)
                                          BSB_ROOT/session.json + profile/        (secrets, daemon-only)
```

### BSB_ROOT (the test-isolation dial)

Every path hangs off one root. Env `BSB_ROOT`, default
`~/Library/Application Support/BrightspaceBar`. Contents:

| Path | What | Writer | Reader |
|---|---|---|---|
| `profile/` | persistent Chromium profile (Entra wristband) | daemon | daemon |
| `session.json` | cookies + XSRF (0600) | daemon | daemon |
| `cache/data.json` | courses + assignments | daemon | Swift app |
| `cache/status.json` | ladder outcome, freshness | daemon | Swift app |

Tests point `BSB_ROOT` at a temp dir. Production credentials are never touched
by tests (experiment 10 proved concurrent Entra profiles don't revoke each other).

### File contracts

`cache/data.json` (atomic write: temp file + rename):
```json
{
  "fetchedAt": "2026-08-15T14:00:00Z",
  "courses": [{ "id": 412690, "name": "…", "code": "MA 26100", "role": "Student",
                "isActive": true, "homeUrl": null, "startDate": null, "endDate": null }],
  "assignments": { "412690": [{ "id": 1, "title": "HW 3", "dueDate": "2026-08-20T04:59:00Z",
                                 "url": "https://…", "kind": "assignment" }] }
}
```
Course fields mirror Swift `Course` (Contracts.swift:21-58). Assignment fields
mirror the Swift `Assignment` model (AssignmentPipeline/Sources/Assignment.swift) —
phase 2/3 builders read that file and keep the shapes aligned. Dates are ISO-8601
strings (Swift side decodes with `.iso8601` — do NOT reuse `CourseCache`'s
default-encoder file, which uses Apple reference-date doubles).

`cache/status.json`:
```json
{ "state": "fresh" | "needs-login" | "error",
  "rungUsed": "none" | "silent" | "full",
  "lastAttemptAt": "ISO", "lastSuccessAt": "ISO|null", "error": "string|null" }
```

Daemon exit codes: `0` fresh cache written · `2` needs-login (ladder exhausted
without permission or success) · `1` unexpected error. A failed run NEVER
deletes or truncates an existing `data.json` (mirror of `.preservedStale`).

Rung 2 permission: CLI flag `--allow-full-login`. Timer/launch spawns omit it
(cron may only ever climb rung 1); the manual Refresh click passes it (the
click is the proof of presence).

## Decisions (locked unless David unlocks them)

- **D1 — Daemon home = `session-capture/`**, David's own package. Do NOT use the
  `brightspace-mcp-server` fork's tools/client/auth (David's explicit call:
  his endpoints only; the fork can be swapped in later behind the fetcher seam).
- **D2 — Rungs are seams.** A rung is a value implementing one interface (below);
  swap-in/swap-out is data, not surgery. Login/security surfaces change; seams absorb it.
- **D3 (amended by BUILD 3, 2026-08-16)** — Rung 2 autofills `BS_EMAIL`/
  `BS_PASSWORD` and is **HEADLESS by default** (`BSB_FULL_HEADED=1` is the
  debugging escape hatch): with the number on the status icon (BUILD 2), the
  browser window is redundant — the product moment is icon-shows-number →
  phone tap → icon reverts, nothing else visible. Original D3 (headed, number
  read from the window) applied only while the window was the display.
- **D4 — The Swift pipeline survives intact.** No changes to `Poller`, `PollPolicy`,
  `CourseCache`, `MenuAdapter`, `CourseMenu`, or any contract in `Contracts.swift`
  (that file is frozen — its header says so). The daemon enters as new
  `CourseSource`/`AssignmentSource` conformers + main.swift wiring.
- **D5 — Daemon tests use `node:test`** (builtin, zero new deps, plain .mjs like
  the rest of session-capture).
- **D6 — `reset.sh` lives outside the architecture** (a dev tool in
  `session-capture/scripts/`), implemented as deletion: `--cache`, `--session`, `--all`.
- **D7 — Secrets never enter `cache/`**, never appear in logs (lengths only),
  never cross into Swift. Swift's old session.json read path retires with the swap.
- **D8 — The app NEVER passes `--allow-full-login` in this build.**
  `CourseSource.fetchCourses()` carries no trigger context and Contracts.swift is
  frozen, so the app cannot distinguish manual from timer at the source. All app
  spawns are cron-safe (rung 1 max). Full login is terminal-initiated
  (`npm run refresh -- --allow-full-login`, David present — phase 4 tier 2 runs
  it this way). Wiring a presence-gated full login into the Refresh click (or a
  dedicated "Log in…" menu item) is an open item, not this build.

### The rung seam

```js
// A rung takes the world, tries to produce live credentials, reports honestly.
// kind: "silent" (no human, cron-safe) | "full" (needs a present human)
{ kind, async attempt({ paths, log }) -> { ok: true } | { ok: false, reason } }
```
Credentials land in `BSB_ROOT/session.json` as a side effect of a successful
attempt (same shape `buildSession` writes today).

## Inventory

**Exists, proven, reuse as-is or extract:**
- Rung 1 mechanics: `session-capture/src/login-flow.mjs` (`trySilentLogin`,
  `isAuthenticated`, `extractXsrf`, `clickThroughSilentSurfaces`).
- Rung 2 mechanics: `session-capture/src/auto-capture.mjs` (headed autofill + MFA wait).
- Session shape: `session-capture/src/session.mjs` (`buildSession`, `buildCookieHeader`).
- Endpoints (David's own, in Swift, port to Node in phase 2):
  cookie+XSRF → `POST /d2l/lp/auth/oauth2/token` → JWT (dead session = HTTP 200 +
  `sessionExpired=1` stub — classify as sessionExpired, see
  `BrightspaceCourseSource.swift`); JWT → `GET …/myenrollments/` (parse rules in
  `EnrollmentParser`); assignments/quizzes endpoints in
  `Modules/AssignmentPipeline/Sources/BrightspaceAssignmentSource.swift` + quiz source.
- Swift seams: `CourseSource` (one method), `AssignmentSource`, contract suite
  (`CourseSourceContractTests.swift` — new sources must pass `assertCourseSourceContract`),
  `FileSessionProvider.standard`'s env-override precedent (`SESSION_JSON`),
  `.preservedStale` fold, `BRIGHTSPACEBAR_STUB`, ArchitectureTests (wiring only in main.swift).
- Test env vars precedent: `BS_LIVE=1` gates live-tenant tests (`make live`).

**Missing (the build):**
- `paths.mjs` (BSB_ROOT resolution), the rung interface, `orchestrate.mjs`
  (`runRefresh(deps)`), `refresh.mjs` CLI, atomic cache writes, `status.json`,
  `reset.sh` — phase 1.
- Real rungs conforming to the seam + Node fetcher (mint, enrollments,
  assignments, quizzes) — phase 2.
- `DaemonCourseSource` + `DaemonAssignmentSource` + spawn helper + production
  timer (none exists today — `.timer` fires only in tests) + main.swift swap — phase 3.
- Tiered E2E — phase 4.

**Refactor/retire (only after green):**
- Swift network path: `BrightspaceCourseSource`, JWT mint, `BrightspaceAssignmentSource`,
  `BrightspaceQuizSource`, `FileSessionProvider` wiring — deleted in phase 3 once
  the contract suite passes against the daemon sources. Their live-contract tests
  (`BS_LIVE`) migrate to the daemon sources.
- `session-capture`'s `manual-capture.mjs`/`auto-capture.mjs` CLIs remain as
  standalone tools (they now share rung modules instead of owning the logic).

## Phases

Each phase = two subagents, in order: **test-writer** (red) then **builder**
(green). Full protocol in the "Subagent protocol" section below.

### Phase 1 — the orchestrator spine  ← THE BOTTLENECK, build first
Everything else plugs into this; its interfaces (rung seam, file contracts,
exit codes) are the load-bearing decisions.
- `session-capture/src/paths.mjs` — BSB_ROOT resolution + subpaths.
- Rung seam (interface above) + `runRefresh(deps)` in `src/orchestrate.mjs`:
  deps-injected (`rungs`, `fetcher`, `paths`, `clock`, `allowFullLogin`).
  Logic: fetch with existing creds → on sessionExpired walk rungs in order
  (skip `full` unless allowed) → refetch after a rung succeeds → write
  `data.json`+`status.json` atomically → typed result. Ladder exhausted →
  status `needs-login`, old data preserved.
- `src/refresh.mjs` CLI wrapper (exit codes, `--allow-full-login`), `npm run refresh`.
- `scripts/reset.sh`.
- Tests (node:test, hermetic): temp BSB_ROOT, fake rungs (scripted
  succeed/fail), fake fetcher (scripted courses/sessionExpired/transport-error).
  Assert: rung ordering, full-rung permission gate, atomic write (no partial
  file on injected crash), old-data preservation on failure, status truthfulness,
  exit codes.
- Done when: `npm test` green in session-capture; `refresh.mjs --help` runs; reset.sh works on a temp root.
- **Contract nuances pinned by the red suite (c709524) — binding on all later phases:**
  `clock()` returns a `Date` (orchestrator calls `.toISOString()`); `runRefresh`
  never throws and RETURNS exactly the status object it wrote; a failed run
  carries `lastSuccessAt` forward from the previous status.json (corrupt
  status.json tolerated, → null); a rung whose `attempt()` throws counts as a
  failed rung and the ladder continues; still-sessionExpired after a successful
  rung keeps climbing; failure with no prior data.json writes no data.json.
  npm test uses the glob form (`node --test "tests/**/*.test.mjs"`) — bare
  `tests/` breaks on node 26.

### Phase 2 — real rungs + real fetcher behind the seams
- `src/rungs/silent.mjs` — wraps `trySilentLogin` path; writes session.json on success.
- `src/rungs/full-login.mjs` — auto-capture mechanics as a rung (headed, autofill, MFA wait).
- `src/fetch-engine.mjs` — David's endpoints (mint → enrollments → per-course
  assignments + quizzes), sessionExpired stub detection, parse to the file contract.
- Tests: seam-contract tests run every fake AND real rung/fetcher through the
  same assertions (shape honesty, no-secret-logging); fixture tests for parsers
  (record real payload shapes — `BrightspaceBar/Modules/CoursePipeline/Tests/Fixtures/
  myenrollments-200.json` already exists, reuse it); live tests gated `BS_LIVE=1`.
- Done when: hermetic suite green; `BS_LIVE=1` tier-0/tier-1 manual check green.

### Phase 3 — the Swift swap
- New backend module (or CoursePipeline addition): `DaemonRunner` (spawns
  `node src/refresh.mjs` via `Process`, coalesced, timeout, exit-code → typed
  result) + `DaemonCourseSource: CourseSource` + `DaemonAssignmentSource:
  AssignmentSource` reading `cache/data.json`/`status.json` (fresh read every
  call, like FileSessionProvider). Exit 2 / status needs-login → throw
  `.sessionExpired` (fold then yields `.preservedStale` — menu never blanks).
- Production timer: a repeating task in main.swift driving `Poller.tick(.timer)`
  at the existing `pollInterval`. Per D8, no app spawn ever passes
  `--allow-full-login` — manual Refresh and timer both run the cron-safe ladder.
- Wiring swap in main.swift ONLY (ArchitectureTests enforce this). Stub mode untouched.
- Delete the retired Swift network path; migrate its BS_LIVE contract runs to the daemon sources.
- Tests first: daemon sources through the existing contract suite
  (`assertCourseSourceContract`) with a fake daemon (a stub script writing canned
  cache files); decode tests incl. ISO-8601 dates; needs-login mapping test.
- Done when: `swift test` (all 131+new) green; `make live` green with daemon sources.

### Phase 3 outcomes (binding facts for phases 4-5)
- Pinned API landed: `DaemonPaths` / `DaemonOutcome` / `DaemonRunner` /
  `DaemonCourseSource` / `RefreshScheduler` (CoursePipeline) +
  `DaemonAssignmentSource(paths:)` (AssignmentPipeline, structurally spawn-free).
  `DaemonCache.swift` is the single reader of status/data.json.
- main.swift wiring: `/usr/bin/env node <cli>`, cli = env `BSB_REFRESH_CLI` else
  `$HOME/PaperShelf/session-capture/src/refresh.mjs`; spawn timeout 180s; no
  extra argv ever (D8; refresh.mjs rejects unknown argv anyway).
- ~~The timer refreshes COURSES ONLY~~ DONE in phase 5: `MenuAdapter.timerTick()`
  drives courses (policy-gated) + assignments (unconditional — they cost no
  spawn and nothing else restores them mid-session). main.swift timer uses it.
- `open -n` does NOT inherit shell env: E2E must use `open -n --env BSB_ROOT=…`
  or run the built binary directly.
- `BS_LIVE=1 swift test` now spawns the real daemon (cron-safe) twice — it IS
  the Swift half of tier 0/1, and cannot green until a tier-2 login has seeded
  the root.
- DELETION DEFERRED to phase 5: retired sources are production-dead but kept
  alive by tests outside phase-3 authorization (CompositeSourceTests suite;
  EndToEndTests.swift:351; AssignmentSourceContractTests.swift:144;
  QuizSourceContractTests.swift:45-46). ARCHITECTURE.md rewrite rides with it.

### Phase 4 — tiered E2E (test-writer only; orchestrator runs it to green)
- `session-capture/tests/e2e.sh` (or .mjs): tier 0/1 automated against the real
  tenant, tier 2 interactive (prints instructions, waits for David).
  Asserts on artifacts only: exit codes, status.json state/rungUsed,
  data.json freshness + non-empty courses, and for the app half: launch the
  built app pointed at the test BSB_ROOT and assert the menu model renders
  (or, minimum: swift contract live-run against the same root).
- No builder. If E2E finds bugs → fix via a targeted builder against the failing test.
- Done when: tier 0 + tier 1 green with zero human input; tier 2 green with
  exactly one MFA; David sees his real courses in the menu bar served from the daemon cache.

## RepoBar reference patterns (professional prior art — cite these in phase-3 briefs)
- **Timer**: `RepoBar/Sources/RepoBar/Support/RefreshScheduler.swift` (45 lines,
  near-verbatim reusable): `Timer.scheduledTimer`, tolerance = 10% of interval
  clamped to [1s, 30s], `restart()` always invalidates first (idempotent),
  `stop()` nils the tick handler too (no retain cycle), `isRunning` derived from
  `timer?.isValid` (no desyncable bool).
- **Spawning an external CLI**: `RepoBarCore/LocalProjects/GitProcessRunner.swift:41-91`
  — redirect stdout/stderr to TEMP FILES, not `Pipe` (a Pipe + `waitUntilExit()`
  deadlocks once the child fills the ~64KB buffer — a Node CLI will); semaphore
  + `terminationHandler` for timeout; SIGTERM then 1s grace. Resolve `node` via
  `/usr/bin/env` (PATH) or a resolved-once locator (`GitExecutable.swift`).
  Harden env so the child can never block on an interactive prompt.
- **JSON cache decode (writer is another program!)**: `RepoDetailCacheStore.swift:38-61`
  — `.iso8601` date strategies both directions, `.atomic` writes,
  **delete-on-corrupt read** (poison-pill), never throws to caller. Versioned
  envelope + migrate-on-read (`SettingsStore.swift:29-56`). With a Node writer
  there's no compiler-enforced schema, so these defensive habits are load-bearing.
- **Paint disk → then network**: one `updateSession` publish function serves both
  the cached paint and the live result (`AppState+Refresh.swift:312-333`).
  (BrightspaceBar's `CourseCache.load()` already does the equivalent.)
- **Menu-open staleness gate**: 1s debounce + 30s snapshot gate + in-flight gate
  + 250ms deferred kick so the menu paints before network (`AppState+Refresh.swift:5-29`).
- **Status channel**: one `session.lastError` written on failure, cleared on
  success, rendered as a non-clickable banner; error string also feeds the menu
  signature so appearing/clearing forces a rebuild.
- **ANTI-pattern to avoid**: the auth trapdoor — `handleAuthenticationFailure`
  wipes keychain + cache with no ladder. Our `needs-login` state must preserve data.

## Subagent protocol
- Fresh agents, never forks. Every brief points at this file and the relevant
  skill: test-writer spikes read `~/.claude/skills/test-writer/SKILL.md`,
  builder spikes read `~/.claude/skills/code-writer/SKILL.md`, both may consult
  `~/.claude/skills/tdd/SKILL.md`.
- Test-writer writes ONLY tests (+ test scripts/fixtures); red = failing for the
  right reason. Builder makes them green without editing the tests' assertions
  (renames/API drift negotiated through the orchestrator).
- **Every spike commits AND pushes its own work when done** — test-writer pushes
  the red commit, builder pushes the green commit. Message prefixes:
  `test(phase-N): …` / `feat(phase-N): …`. End commit messages with the
  Co-Authored-By Claude trailer.
- The orchestrator (main session) verifies red/green personally by running the
  suites before advancing a phase — an agent's claim is never sufficient.

### Phase 5 outcomes (2026-08-16 — BUILD COMPLETE)
- All 5 phases + tiered E2E green. Tier 2 cost exactly one MFA; tiers 1/0 ran
  with zero human input (27 courses). App verified live in the menu bar.
- Deleted: the entire Swift network path INCLUDING the BrightspaceSession
  module (Package.swift down to six modules), refresh-session.sh, SESSION_JSON.
  Kept: EnrollmentParser/QuizParser (test helpers), QuizLink (production).
- Suite: 518 tests / 68 suites, green hermetic AND under BS_LIVE=1
  (live cases spawn the real daemon; needs a seeded BSB_ROOT).

## BUILD 2 — the MFA number on the icon (started 2026-08-16 — **COMPLETE, E2E GREEN same night**)

Live pass evidence (scripts/e2e-icon.sh, one MFA): number "72" published 69s
into the run; status item measured GROWING 30pt→62pt while the number was
live and SHRINKING back 62pt→30pt after the login; mfa.json deleted by the
rung's finally; status fresh, rungUsed full, 27 courses, wristband re-seeded.
Suites: session-capture 166 (162 pass/4 BS_LIVE-skip) · Swift 561/74 green.

The finished form of the login story: during a full login, the status-bar icon
becomes the verification number; the human types it into Authenticator on their
phone; the icon returns to the logo. No visible browser needed eventually.

Pipeline: full rung scrapes `#idRichContext_DisplaySign` (proven in
experiment-10/prove-number.mjs, plain DOM text) → writes `cache/mfa.json`
`{"number":"20","mintedAt":"<ISO>"}` (single writer; deleted on every exit
path) → Swift watcher on cache/ → `StatusBarController.show(code:)` (flip
proven 1-4ms in experiment 12) → icon = PURE FUNCTION of
(mfa.json exists && now-mintedAt < 60s) — stateless; TTL at render time means
a crashed rung can never wedge a stale number.

Why a file, not stdout events: D8 — the app is not always the spawner
(terminal-initiated full login), so the transport must not assume a parent
pipe. `cache/mfa.json` is ephemeral STATUS: not course data, not a secret
(the number is display-by-design and useless without the phone).

- Experiment 17 (experiment-17-mfa-icon-watch/, commit 66205f0): VERDICT —
  **kqueue DispatchSource on the cache DIRECTORY**: 2.6ms median / 3.8ms max
  end-to-end (write→repaint), 5x faster than FSEvents at median, no cold-start
  tail (FSEvents' first delivery after idle = 117-257ms — and one-write-after-
  hours-idle is this feature's only traffic pattern). Binding traps for
  Phase B: (1) watch the DIRECTORY, never the file — a rename unlinks the
  watched inode and the watcher goes deaf after one write (measured);
  (2) one atomic write = two dir events, the first a lie — re-read the file
  and compare content before rendering; (3) warm the font with a throwaway
  render at startup (first attributedTitle costs 19ms once); (4) revert-check
  timers in .common run-loop mode; (5) re-arm the watcher if cache/ itself is
  deleted (reset.sh --cache); (6) delete is a first-class event (icon revert).
  Untested, accepted: kqueue across sleep/wake.
- Phase A (daemon): test-writer pins the mfa.json contract in the full rung —
  written on scrape (mintedAt from clock), deleted on success/expiry/error/
  crash-path, never any credential material; hermetic via the rung's injected
  browser. Builder ports the prove-number scrape into full-login.mjs.
- Phase B (Swift): test-writer pins the icon pure function + watcher (canned
  cache roots; technique per exp 17) + StatusBarController.show(code:) wiring.
  Builder implements.
- Phase C (E2E, test-writer only): wipe root → `refresh.mjs --allow-full-login`
  → assert mfa.json appears (orchestrator relays the number to David in chat —
  he is remote; he types it into Authenticator on his phone) → assert success
  path deletes mfa.json, status fresh, icon back to logo (screencapture of the
  menu bar as evidence). Costs one MFA, re-seeds the wristband.
- Not in scope: running the full rung headless (works headed today; headless
  flag is the follow-up once the icon replaces the window), resend-on-expiry
  policy (designed earlier: one resend max, then degrade).

## Open items / not in scope now
- Wake-from-sleep trigger (`NSWorkspace.didWakeNotification`) — add after E2E greens.
- Menu-open trigger (`.menuOpened` exists in `PollTrigger` but is unwired in
  production; RepoBar's debounce+gate pattern above is the reference) — after E2E.
- MFA number on the status-bar icon (exp 12) — separate build; rung 2 currently
  shows the number in the headed browser window.
- Overrides layer (`overrides.json`, rotate tool) — separate build; schema
  already reserves the seam (data.json is fetched-layer only).
- Breadth endpoints (grades, announcements…) — later, behind the fetcher seam.
- `make live` now spawns the real daemon 5× (courses contract, assignments
  contract, fixture pin, quiz live, live menu — each self-contained by phase-3
  convention). If too slow, memoize one daemon run per invocation behind a
  lazily-initialized actor; every live case is happy with one run's cache.
- Known coverage gap (named, accepted): no concurrency witness on the daemon's
  two per-course routes — Node's Promise.all fan-out has no high-water-mark test.
