import Foundation
import AssignmentPipeline
import CourseMenu
import CoursePipeline

// ─────────────────────────────────────────────────────────────────────────────
// SEAM: this actor is where the two packages meet.
//
//   CourseMenu.MenuDataSource        ← the frontend contract this actor conforms to
//   CoursePipeline.Poller/Cache      ← the course machinery this actor drives
//   AssignmentPipeline.Fetcher/Store ← the assignment machinery, via AssignmentFeed
//
// Imperative shell only. Every decision is owned elsewhere: "should we fetch?"
// belongs to `PollPolicy`, "what survives a failure?" to `CourseCache` and
// `AssignmentStore`, "which courses are worth a request?" to
// `MenuTranslation.visibleCourses`, and "what does the menu say?" to
// `MenuTranslation` / `AssignmentTranslation`. This actor just reads the facts
// and hands them across the seam.
// ─────────────────────────────────────────────────────────────────────────────
public actor MenuAdapter: MenuDataSource {
    private let poller: Poller
    private let cache: CourseCache
    private let baseURL: URL
    private let clock: any Clock
    /// SEAM: the assignments half, or nil for a build without the feature —
    /// which is how every pre-assignment call site keeps its exact old behaviour.
    private let assignments: AssignmentFeed?
    /// Which zone deadline dates render in. Ambient config belongs in the shell;
    /// the pure layer takes it as a parameter.
    private let timeZone: TimeZone

    /// One disk read per process lifetime, performed lazily on first use so
    /// construction stays effect-free.
    private var loadedFromDisk = false

    public init(
        poller: Poller,
        cache: CourseCache,
        baseURL: URL,
        clock: any Clock,
        assignments: AssignmentFeed? = nil,
        timeZone: TimeZone = .current
    ) {
        self.poller = poller
        self.cache = cache
        self.baseURL = baseURL
        self.clock = clock
        self.assignments = assignments
        self.timeZone = timeZone
    }

    // SEAM: contract method — the GUI's menu-open path. Serves memory/disk only;
    // by design there is no code path from here to a socket.
    public func currentMenu() async -> MenuModel {
        await self.loadIfNeeded()
        return await self.snapshot()
    }

    // SEAM: contract method — the GUI's Refresh click. Maps to `.manual`, which
    // `PollPolicy` ALWAYS honours: a user who explicitly asked gets a fetch,
    // even one second after the last. A future timer path must NOT reuse this
    // method — it would inherit `.manual` and bypass the policy's staleness
    // rule entirely. Give a timer its own `tick(.timer)` call instead.
    public func refresh() async -> MenuModel {
        await self.loadIfNeeded()
        // The poller folds the result into the cache; failure preserves the old
        // list (`.preservedStale`), so there is nothing to catch here and the
        // snapshot below is always the best available data.
        _ = await self.poller.tick(.manual)
        // Courses first, then assignments: the assignment fan-out is driven by the
        // course list, so refreshing it before the courses land would fetch against
        // last cycle's courses.
        await self.refreshAssignments()
        return await self.snapshot()
    }

    /// SEAM: the launch path. Separate from `refresh()` because it must use the
    /// `.launch` trigger, which `PollPolicy` may decline when a recent relaunch
    /// left the cache fresh — `refresh()` maps to `.manual`, which always fetches.
    ///
    /// Assignments are refreshed unconditionally afterwards, and that asymmetry is
    /// deliberate: they are not persisted, so a warm start has courses on disk but
    /// never assignments, and skipping the fetch would leave every submenu empty
    /// for the whole session.
    public func launch() async {
        await self.loadIfNeeded()
        _ = await self.poller.tick(.launch)
        await self.refreshAssignments()
    }

    /// SEAM: the production timer's path. Separate from `refresh()` because
    /// `.manual` always fetches — a timer wired through it would spawn the daemon
    /// every interval whether or not anything could have changed — and separate
    /// from `launch()` because the trigger is part of the meaning.
    ///
    /// Assignments refresh unconditionally, even when the policy declines the
    /// courses: they are not persisted, so nothing else can bring them back
    /// mid-session, and the fan-out costs no spawn (`DaemonAssignmentSource` reads
    /// the cache the course fetch already wrote). Same asymmetry as `launch()`.
    public func timerTick() async {
        await self.loadIfNeeded()
        _ = await self.poller.tick(.timer)
        await self.refreshAssignments()
    }

    /// One request per course that will actually render.
    ///
    /// The course list is filtered through the same `visibleCourses` the menu uses,
    /// so the app never spends a request on a course it will not show — which
    /// matters concretely: 27 enrollments narrow to a handful, and the ended ones
    /// answer 403 (experiment 6). Failures need no handling here; `AssignmentStore`
    /// preserves what each course already had.
    private func refreshAssignments() async {
        guard let assignments = self.assignments else { return }
        let visible = MenuTranslation.visibleCourses(await self.cache.courses, now: self.clock.now)
        _ = await assignments.fetcher.refresh(courses: visible)
    }

    /// Warm start: pull the previous run's courses off disk before the first
    /// answer, so a relaunch shows data before any network round trip. Loading
    /// before `refresh()` too means even a failing first refresh cannot blank
    /// a menu that disk could have filled.
    private func loadIfNeeded() async {
        guard !self.loadedFromDisk else { return }
        self.loadedFromDisk = true
        await self.cache.load()
    }

    /// Shell reads the facts (cache state, assignment states, clock), core
    /// translates. The one crossing from backend state to frontend model.
    private func snapshot() async -> MenuModel {
        let courses = await self.cache.courses
        return MenuTranslation.menu(
            courses: courses,
            lastFetch: await self.cache.lastFetch,
            now: self.clock.now,
            baseURL: self.baseURL,
            assignments: await self.assignmentStates(for: courses),
            timeZone: self.timeZone
        )
    }

    /// What is known about each course's assignments, keyed by course id.
    ///
    /// Reading the store per course rather than exposing its whole dictionary keeps
    /// the store's storage private; courses with no entry answer `.neverFetched`,
    /// which the translation renders as no submenu at all.
    private func assignmentStates(for courses: [Course]) async -> [Int: AssignmentsState] {
        guard let assignments = self.assignments else { return [:] }
        var states: [Int: AssignmentsState] = [:]
        for course in courses {
            states[course.id] = await assignments.store.state(for: course.id)
        }
        return states
    }
}
