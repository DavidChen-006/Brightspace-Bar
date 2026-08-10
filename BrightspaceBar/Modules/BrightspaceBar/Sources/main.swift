import AppKit
import AssignmentPipeline
import BrightspaceSession
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

let app = NSApplication.shared
// Menu-bar-only at runtime — LSUIElement's twin, so even the bare `swift build`
// executable stays out of the Dock.
app.setActivationPolicy(.accessory)

let dataSource: any MenuDataSource
/// Set only in the live path: the launch fetch needs the poller directly, and it
/// must not go through `MenuDataSource.refresh()`, which maps to `.manual`.
var launchFetch: (@Sendable () async -> Void)?

// Escape hatch: BRIGHTSPACEBAR_STUB=1 launches against the phase-2 seeded stub —
// no session file, no network — so the GUI stays demoable offline.
if ProcessInfo.processInfo.environment["BRIGHTSPACEBAR_STUB"] == "1" {
    dataSource = StubMenuDataSource()
} else {
    // ── The backend stack, assembled bottom-up ────────────────────────────────
    //
    //   BrightspaceCourseSource     → Poller ⇄ CourseCache      ─┐
    //                                 (PollPolicy decides)       ├→ MenuAdapter
    //   BrightspaceAssignmentSource → AssignmentFetcher ⇄ Store ─┘
    //                                 (one request per visible course)
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

    // SEAM: session acquisition. Today `FileSessionProvider.standard` — the JSON
    // that `Scripts/refresh-session.sh` writes to
    // `~/Library/Application Support/BrightspaceBar/session.json` (`SESSION_JSON`
    // overrides). Later, a `WKWebView` login window conforms to the same
    // `SessionProviding` and this is the ONLY line that changes.
    //
    // The provider is consulted per fetch and its failures are typed: no file →
    // `.transport`, dead cookie → `.sessionExpired` — both of which the cache
    // folds into `.preservedStale`, so cached courses still render with an honest
    // staleness line instead of the app dying at launch.
    // One provider serves both sources, so courses and assignments always
    // authenticate with the same session and a refreshed cookie reaches both.
    let sessionProvider = FileSessionProvider.standard
    let source = BrightspaceCourseSource(provider: sessionProvider)

    let poller = Poller(
        source: source,
        cache: cache,
        policy: PollPolicy(interval: pollInterval),
        clock: clock
    )

    // SEAM: the assignments half. `AssignmentFeed` builds the fetcher and its
    // store together — passing them separately would allow a fetcher wired to a
    // different store than the adapter reads, which fails silently as
    // permanently-empty submenus.
    //
    // Not persisted, deliberately: courses are the warm-start data, and
    // assignments are cheap to refetch once the course list is known. A dead
    // session surfaces as `.failed(lastKnown:)`, which still renders the last
    // known assignments plus an honest staleness note.
    let assignmentFeed = AssignmentFeed(
        source: BrightspaceAssignmentSource(provider: sessionProvider),
        clock: clock
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
        timeZone: .current
    )

    // SEAM: the launch trigger. `MenuAdapter.launch()` — NOT
    // `MenuDataSource.refresh()`, which maps to `.manual` and would bypass
    // `PollPolicy` entirely. `.launch` fetches when the cache is stale or empty
    // and declines when a recent relaunch left it fresh, so a warm start costs
    // nothing. A dead session yields `.preservedStale`, leaving cached courses
    // intact — which is why an expired cookie shows stale data, not an empty menu.
    // Assignments always fetch, because nothing on disk can supply them.
    launchFetch = { await adapter.launch() }

    dataSource = adapter
}

// Top-level `let` keeps the controller (and its status item) alive for the
// life of the process.
let controller = StatusBarController(
    dataSource: dataSource,
    opener: WorkspaceURLOpener()
)

// The controller's own init already pulls `currentMenu()`, which serves the
// cache off disk — so courses appear without waiting for the network. This Task
// adds the launch fetch on top and repaints if it changed anything.
Task { @MainActor in
    await controller.reload()          // disk first: instant, offline-safe
    await launchFetch?()               // then the network, if the policy agrees
    await controller.reload()          // repaint only if the model actually changed
}

app.run()
