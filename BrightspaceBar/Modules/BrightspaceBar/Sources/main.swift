import AppKit
import AssignmentPipeline
import CourseMenu
import CoursePipeline
import MenuAdapter

// ═════════════════════════════════════════════════════════════════════════════
// COMPOSITION ROOT — the one file allowed to see both sides of the contract.
//
// Everything below builds the backend stack (experiment 4) and hands it to the
// GUI behind the `MenuDataSource` seam. `StatusBarController` and the rest of
// the view code import `CourseMenu` only; `ArchitectureTests` enforces that
// this file stays the single point of wiring.
//
// ⚠️ THIS FILE MUST STAY SYNCHRONOUS AT TOP LEVEL — no top-level `await`.
//
// A single top-level `await` turns this into an async main, which means
// `app.run()` is called from a job that holds the MainActor and never returns.
// Every other MainActor job is then starved forever: `StatusBarController`
// paints its placeholder synchronously and its follow-up `Task` never starts,
// so the menu shows "No courses yet" permanently AND the Refresh click (also a
// `Task`) silently does nothing. This was a real bug, diagnosed the hard way —
// symptom was an empty menu while the backend demonstrably held 27 courses.
//
// All async work therefore goes inside a `Task` that runs once `app.run()` is
// pumping the run loop.
// ═════════════════════════════════════════════════════════════════════════════

/// How often a non-manual trigger may fetch, and when cached data counts as
/// stale. A manual Refresh click always fetches regardless (see `PollPolicy`).
private let pollInterval: TimeInterval = 15 * 60

/// The tenant. Also the base every course row's click URL is derived from —
/// `MenuTranslation` builds `{baseURL}/d2l/home/{id}` because D2L's own
/// `HomeUrl` field is null for nearly every real enrollment.
private let brightspaceBaseURL = URL(string: "https://purdue.brightspace.com")!

/// The daemon CLI this app spawns: `BSB_REFRESH_CLI` when set — which is how a
/// test or a moved checkout points elsewhere — otherwise David's own
/// `session-capture` package.
///
/// Run through `/usr/bin/env` so `node` is found on PATH rather than pinned to
/// one installation.
private let daemonCLI = ProcessInfo.processInfo.environment["BSB_REFRESH_CLI"]
    ?? NSHomeDirectory() + "/PaperShelf/session-capture/src/refresh.mjs"

/// How long a spawn may take before it is killed. Generous: a run that has to
/// climb the silent rung launches a headless browser and waits on a real Entra
/// round trip, and the cost of being wrong in the short direction is a refresh
/// that can never succeed. Comfortably inside `pollInterval`, so a stuck run can
/// never overlap the next one.
private let daemonTimeout: TimeInterval = 3 * 60

/// The install both halves mean, resolved once and shared: the daemon is handed
/// this root and writes `cache/` under it, and the MFA watcher watches that same
/// `cache/`. Resolved out here rather than inside the live branch because the
/// watcher is wired in both modes — resolution is pure and creates nothing, so
/// the stub path pays only the string.
let daemonPaths = DaemonPaths.resolve()

let app = NSApplication.shared
// Menu-bar-only at runtime — LSUIElement's twin, so even the bare `swift build`
// executable stays out of the Dock.
app.setActivationPolicy(.accessory)

let dataSource: any MenuDataSource
/// Set only in the live path: the launch fetch needs the poller directly, and it
/// must not go through `MenuDataSource.refresh()`, which maps to `.manual`.
var launchFetch: (@Sendable () async -> Void)?
/// Set only in the live path: what the production timer fires. Separate from
/// `launchFetch` for the same reason — the trigger is part of the meaning, and
/// `.timer` must reach `PollPolicy` as `.timer`.
var timerFetch: (@Sendable () async -> Void)?

/// The timer, created up here — before the adapter — so the adapter can be
/// handed a live `nextFireDate` reader for the menu's "Refreshes in N min" row.
/// Nothing is scheduled until `restart` at the bottom, so until then the
/// provider honestly answers nil and the menu shows no countdown. Top-level
/// `let` keeps it (and its timer) alive for the life of the process.
let refreshTimer = RefreshScheduler()

// Escape hatch: BRIGHTSPACEBAR_STUB=1 launches against the phase-2 seeded stub —
// no session file, no network — so the GUI stays demoable offline.
if ProcessInfo.processInfo.environment["BRIGHTSPACEBAR_STUB"] == "1" {
    dataSource = StubMenuDataSource()
} else {
    // ── The backend stack, assembled bottom-up ────────────────────────────────
    //
    //   DaemonRunner → DaemonCourseSource → Poller ⇄ CourseCache  ─┐
    //     (spawns node src/refresh.mjs)     (PollPolicy decides)   ├→ MenuAdapter
    //   DaemonAssignmentSource → Fetcher ⇄ Store  ─────────────────┘
    //     (reads the same cache; no spawn)
    //
    // Every constructor here is synchronous by design, which is what lets this
    // file stay a sync main. The only async steps (load + tick + fan-out) run in
    // the Task at the bottom.
    let clock = SystemClock()

    // Cache file under ~/Library/Caches/BrightspaceBar/, so a relaunch shows
    // courses before the network answers.
    let cacheDirectory = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "BrightspaceBar")
    try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    let cache = CourseCache(
        fileURL: cacheDirectory.appending(path: "courses.json"),
        clock: clock,
        staleAfter: pollInterval
    )

    // SEAM: where data comes from. The app does not fetch, hold a cookie, or mint
    // a JWT any more — it spawns the Node daemon, which owns the login ladder
    // (existing credentials → silent Entra SSO → headed login) and David's own
    // endpoints, and writes `$BSB_ROOT/cache/`. Secrets stay on that side of the
    // boundary entirely (D7).
    //
    // `BSB_ROOT` is resolved once, at the top of this file, exactly as
    // `session-capture/src/paths.mjs` resolves it, and the same value is both
    // handed to the child and read back from — so the writer and the reader
    // cannot disagree about which install they mean.
    //
    // ⚠️ D8: no argument is passed, and in particular never --allow-full-login.
    // `CourseSource.fetchCourses()` carries no trigger context, so the app cannot
    // tell a manual click from a timer tick at the source; every spawn it can make
    // is therefore a cron-safe one, which may climb the silent rung and no
    // further. A headed login is terminal-initiated, with David present:
    // `npm run refresh -- --allow-full-login`.
    let source = DaemonCourseSource(runner: DaemonRunner(
        executable: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: ["node", daemonCLI],
        paths: daemonPaths,
        timeout: daemonTimeout
    ))

    let poller = Poller(
        source: source,
        cache: cache,
        policy: PollPolicy(interval: pollInterval),
        clock: clock
    )

    // SEAM: a course's work — assignments and quizzes both, merged by the daemon
    // before it ever reaches disk, which is why there is no composite here any
    // more. This source takes paths and no runner: every course's answer is
    // already inside the one `data.json` the course fetch just produced, so the
    // fan-out over 27 courses costs 27 file reads and not one extra spawn.
    let workSource = DaemonAssignmentSource(paths: daemonPaths)

    // SEAM: the assignments half. `AssignmentFeed` builds the fetcher and its
    // store together — passing them separately would allow a fetcher wired to a
    // different store than the adapter reads, which fails silently as
    // permanently-empty submenus.
    //
    // Not persisted, deliberately: courses are the warm-start data, and
    // assignments are cheap to refetch once the course list is known. A dead
    // session surfaces as `.failed(lastKnown:)`, which still renders the last
    // known assignments plus an honest staleness note.
    let assignmentFeed = AssignmentFeed(source: workSource, clock: clock)

    // SEAM: the announcements half — the same pairing argument as
    // `AssignmentFeed`, over the same `data.json` (its own `announcements`
    // field, written by the same daemon run; no extra spawn).
    let announcementFeed = AnnouncementFeed(
        source: DaemonAnnouncementSource(paths: daemonPaths), clock: clock
    )

    // SEAM: from here down the stack is only ever seen as `MenuDataSource`.
    // `timeZone` is `.current` — read once here, in the shell, because
    // `AssignmentTranslation` must stay pure and take it as a parameter.
    let adapter = MenuAdapter(
        poller: poller,
        cache: cache,
        baseURL: brightspaceBaseURL,
        clock: clock,
        assignments: assignmentFeed,
        announcements: announcementFeed,
        timeZone: .current,
        // Read live on every snapshot — never a copy — so the countdown row
        // always reflects the timer's actual schedule, tolerance and
        // sleep-coalescing included.
        nextRefresh: { refreshTimer.nextFireDate }
    )

    // SEAM: the launch trigger. `MenuAdapter.launch()` — NOT
    // `MenuDataSource.refresh()`, which maps to `.manual` and would bypass
    // `PollPolicy` entirely. `.launch` fetches when the cache is stale or empty
    // and declines when a recent relaunch left it fresh, so a warm start costs
    // nothing. A dead session yields `.preservedStale`, leaving cached courses
    // intact — which is why an expired cookie shows stale data, not an empty menu.
    // Assignments always fetch, because nothing on disk can supply them.
    launchFetch = { await adapter.launch() }

    // SEAM: the timer trigger. `MenuAdapter.timerTick()` — NOT
    // `MenuDataSource.refresh()`, which maps to `.manual` and always fetches:
    // `.timer` is the trigger `PollPolicy` may decline when the cache is still
    // fresh, and the whole point of a trigger is that it reaches the policy
    // intact. Both halves refresh: driving the poller directly would refresh
    // courses only, leaving a laptop left open all day showing submenus from
    // whenever it was last clicked.
    timerFetch = { await adapter.timerTick() }

    dataSource = adapter
}

// SEAM: which browser a click opens in. The switch defaults to `.chromium` —
// clicks land in the daemon's signed-in profile with no login — and flips to the
// default browser with `BSB_BROWSER_TARGET=system`. The composition root asks
// for a target and never names a concrete opener.
//
// Top-level `let` keeps the controller (and its status item) alive for the life
// of the process.
let controller = StatusBarController(
    dataSource: dataSource,
    opener: BrowserTarget.resolve().makeOpener()
)

// SEAM: the login challenge. The daemon writes the Entra verification number to
// `cache/mfa.json` mid-login and deletes it when the challenge resolves; the
// watcher turns that file into `IconState` and this is the one place allowed to
// know both that word and `show(code:)` — `IconState` is a CoursePipeline type
// and no view file may import a backend module.
//
// Wired in both modes, stub included: it is a reader of one file and spawns
// nothing (D8), so the cost of running it against a stub install is a kqueue
// descriptor, and the reward is that the demo path exercises the same wiring the
// live one does. Top-level `let` because a watcher bound inside a branch is
// deallocated at the end of it, cancelling its source — the app would launch,
// wire everything, and never see a challenge.
let mfaWatcher = MfaWatcher(paths: daemonPaths)
mfaWatcher.start { state in
    switch state {
    case .code(let number): controller.show(code: number)
    case .logo: controller.show(code: nil)
    }
}

// The controller's own init already pulls `currentMenu()`, which serves the
// cache off disk — so courses appear without waiting for the network. This Task
// adds the launch fetch on top and repaints if it changed anything.
Task { @MainActor in
    await controller.reload()          // disk first: instant, offline-safe
    await launchFetch?()               // then the daemon, if the policy agrees
    await controller.reload()          // repaint only if the model actually changed
}

// The production timer's schedule (the `RefreshScheduler` itself is created at
// the top of this file, so the adapter could capture its `nextFireDate`).
// Scheduling is synchronous and top-level, so it happens before the launch
// Task's body ever runs — the very first repaint already has a countdown.
if let timerFetch {
    refreshTimer.restart(interval: pollInterval) {
        // The tick handler stays synchronous — a `Timer` cannot await — and hands
        // the work to a Task, which is also what keeps this file a sync main.
        Task { @MainActor in
            await timerFetch()
            await controller.reload()
        }
    }
}

app.run()
