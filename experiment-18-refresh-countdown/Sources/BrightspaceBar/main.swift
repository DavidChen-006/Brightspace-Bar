import AppKit
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
/// `BSB_INTERVAL` (seconds) overrides for demos — a 90-second interval makes the
/// countdown observable without waiting a quarter hour.
private let pollInterval: TimeInterval = ProcessInfo.processInfo
    .environment["BSB_INTERVAL"].flatMap(TimeInterval.init) ?? 15 * 60

/// The tenant. Also the base every course row's click URL is derived from —
/// `MenuTranslation` builds `{baseURL}/d2l/home/{id}` because D2L's own
/// `HomeUrl` field is null for nearly every real enrollment.
private let brightspaceBaseURL = URL(string: "https://purdue.brightspace.com")!

/// Stand-in source for when the captured session file is missing or unreadable.
/// Refreshes fail as `.transport`, which the cache answers with
/// `.preservedStale` — so previously cached courses still render, with an
/// honest staleness line, instead of the app dying at launch.
private struct UnavailableSessionSource: CourseSource {
    func fetchCourses() async throws -> [Course] {
        throw CourseSourceError.transport("session file unavailable")
    }
}

let app = NSApplication.shared
// Menu-bar-only at runtime — LSUIElement's twin, so even the bare `swift build`
// executable stays out of the Dock.
app.setActivationPolicy(.accessory)

let dataSource: any MenuDataSource
/// Set only in the live path: the launch fetch needs the poller directly, and it
/// must not go through `MenuDataSource.refresh()`, which maps to `.manual`.
var launchFetch: (@Sendable () async -> Void)?
/// Set only in the live path: what the production timer fires. Separate from
/// `launchFetch` because the trigger is part of the meaning — `.timer` must
/// reach `PollPolicy` as `.timer`.
var timerFetch: (@Sendable () async -> Void)?

/// The timer, created before the adapter so the adapter can be handed a live
/// `nextFireDate` reader. Nothing is scheduled until `restart` at the bottom, so
/// until then the provider honestly answers nil and the menu shows no countdown.
let refreshTimer = RefreshScheduler()

// Escape hatch: BRIGHTSPACEBAR_STUB=1 launches against the phase-2 seeded stub —
// no session file, no network — so the GUI stays demoable offline.
if ProcessInfo.processInfo.environment["BRIGHTSPACEBAR_STUB"] == "1" {
    dataSource = StubMenuDataSource()
} else {
    // ── The backend stack, assembled bottom-up ────────────────────────────────
    //
    //   BrightspaceCourseSource → Poller ⇄ CourseCache → MenuAdapter
    //                              (PollPolicy decides, SystemClock ticks)
    //
    // Every constructor here is synchronous by design, which is what lets this
    // file stay a sync main. The only async steps (load + tick) run in the Task
    // at the bottom.
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

    // The captured session (experiment 1) is read inside this initializer —
    // `SESSION_JSON` overrides the default path. Never copied, never logged;
    // the fallback error message carries no secret.
    let source: any CourseSource
    do {
        source = try BrightspaceCourseSource()
    } catch {
        FileHandle.standardError.write(Data(
            "BrightspaceBar: no usable session (\(error)); serving cached courses only\n".utf8
        ))
        source = UnavailableSessionSource()
    }

    let poller = Poller(
        source: source,
        cache: cache,
        policy: PollPolicy(interval: pollInterval),
        clock: clock
    )

    // SEAM: the launch trigger, driven against the poller directly — NOT via
    // `MenuDataSource.refresh()`, which maps to `.manual` and would bypass
    // `PollPolicy` entirely. `.launch` fetches when the cache is stale or empty
    // and declines when a recent relaunch left it fresh, so a warm start costs
    // nothing. A dead session yields `.preservedStale`, leaving cached courses
    // intact — which is why an expired cookie shows stale data, not an empty menu.
    launchFetch = { _ = await poller.tick(.launch) }

    // SEAM: from here down the stack is only ever seen as `MenuDataSource`.
    // The adapter reads `nextFireDate` live on every snapshot — never a copy —
    // so the countdown row always reflects the timer's actual schedule,
    // tolerance and sleep-coalescing included.
    let adapter = MenuAdapter(
        poller: poller, cache: cache, baseURL: brightspaceBaseURL, clock: clock,
        nextRefresh: { refreshTimer.nextFireDate }
    )
    timerFetch = { await adapter.timerTick() }
    dataSource = adapter
}

// Top-level `let` keeps the controller (and its status item) alive for the
// life of the process.
let controller = StatusBarController(
    dataSource: dataSource,
    opener: WorkspaceURLOpener()
)

// The production timer. Scheduled BEFORE the launch-fetch Task below runs, so
// the very first repaint already has a `nextFireDate` to show. The tick handler
// stays synchronous — a `Timer` cannot await — and hands the work to a Task.
refreshTimer.restart(interval: pollInterval) {
    Task { @MainActor in
        await timerFetch?()
        await controller.reload()
    }
}

// The controller's own init already pulls `currentMenu()`, which serves the
// cache off disk — so courses appear without waiting for the network. This Task
// adds the launch fetch on top and repaints if it changed anything.
Task { @MainActor in
    await controller.reload()          // disk first: instant, offline-safe
    await launchFetch?()               // then the network, if the policy agrees
    await controller.reload()          // repaint only if the model actually changed
}

app.run()
