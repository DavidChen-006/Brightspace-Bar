import Foundation
import Testing

import AssignmentPipeline
import CourseMenu
import CoursePipeline
import MenuAdapter

// ═════════════════════════════════════════════════════════════════════════════
// MenuAdapter.timerTick() — the production timer's entry point.
//
// Until now the timer was wired straight to `Poller.tick(.timer)` in main.swift,
// which refreshes COURSES ONLY (LADDER-PLAN, "Phase 3 outcomes"). Assignments are
// deliberately not persisted, so the only things that ever refresh them are
// `launch()` and a manual `refresh()` — and a laptop left open for a day therefore
// shows submenus from whenever it was last clicked. `timerTick()` closes that gap.
//
// PRIORITIES (the 1–2 carrying 80% of the value):
//
//   1. THE TIMER KEEPS ALL OF THE DATA FRESH, not half of it. The gap being closed
//      is specifically the assignment half, so the claim is observed where the user
//      would see it: the rows in the next `currentMenu()`.
//
//   2. THE TIMER IS STILL GOVERNED BY PollPolicy. `refresh()` maps to `.manual`,
//      which ALWAYS fetches; the whole reason `timerTick()` may not be spelled
//      `refresh()` is that a timer firing every 15 minutes against a cache that is
//      still fresh would spawn the daemon for nothing. `.timer` must reach the
//      policy intact.
//
// CULLED: the daemon's argv (D8) — a `CourseSource` carries no spawn, so at this
// layer there is nothing to observe and a fake that pretended otherwise would test
// itself; `DaemonRunner`'s own suite owns that claim. Also culled: timing (call
// counts instead), coalescing (`Poller` owns and tests it), and disk format.
//
// SCOPE: medium — the real Poller, the real PollPolicy, a real CourseCache on a
// real file, the real EnrollmentParser and the real AssignmentFetcher/Store. Only
// the two sources are doubles.
// ═════════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────
// PINNED POLICY — the builder implements exactly this.
//
//   public func timerTick() async
//
// Same shape as `launch()`, one trigger different:
//
//   1. load from disk if that has not happened yet (as every entry point does),
//   2. `poller.tick(.timer)` — NOT `.manual`, NOT `.launch`,
//   3. refresh the assignments.
//
// It returns nothing for the same reason `launch()` does: the caller repaints by
// asking `currentMenu()` afterwards, so the trigger path and the read path stay
// separate. What `timerTick()` does when the policy DECLINES the course fetch is
// deliberately not pinned here — the assignment fan-out costs no spawn either way
// (`DaemonAssignmentSource` reads the cache the course fetch already wrote), so
// that is the builder's call.
// ─────────────────────────────────────────────────────────────────────────────

/// Mid Fall 2025, where `RealData`'s transcribed visible set applies — the
/// currentness filter makes `now` part of the expected output, and the assignment
/// fan-out only visits courses that pass it.
private let epoch = RealData.midFall2025

/// The production interval, so "inside the interval" means what it means in the app.
private let interval: TimeInterval = 15 * 60

/// The one assignment the fake tenant holds, in the one course that is both
/// visible at `epoch` and real (`RealData.visibleIDsAtMidFall2025` contains it).
private enum Work {
    static let courseID = 440_703
    static let id = 445_296
    static let name = "Upload your CITI Certificate to Complete Module 2"

    static let item = Assignment(
        id: id, courseId: courseID, name: name,
        dueDate: nil, isHidden: false, groupTypeId: nil
    )
}

/// An `AssignmentSource` that answers for one course and counts every call.
///
/// Call counts again, never elapsed time: "the timer refreshed the assignments" is
/// a claim about the source being asked and the rows arriving, and a timing
/// assertion would be flaky without testing either.
private actor CountingWorkSource: AssignmentSource {
    private(set) var calls = 0

    func fetchAssignments(courseId: Int) async throws -> [Assignment] {
        self.calls += 1
        return courseId == Work.courseID ? [Work.item] : []
    }

    func callCount() -> Int { self.calls }
}

/// The real stack, with both halves wired — the shape `main.swift` builds.
private func makeAdapter(
    courses: CountingSource,
    work: CountingWorkSource,
    file: URL,
    clock: ManualClock
) -> MenuAdapter {
    let cache = CourseCache(fileURL: file, clock: clock, staleAfter: interval)
    let poller = Poller(
        source: courses,
        cache: cache,
        policy: PollPolicy(interval: interval),
        clock: clock
    )
    return MenuAdapter(
        poller: poller,
        cache: cache,
        baseURL: RealData.baseURL,
        clock: clock,
        assignments: AssignmentFeed(source: work, clock: clock),
        timeZone: TimeZone(identifier: "UTC")!
    )
}

@Suite("MenuAdapter.timerTick — the timer refreshes both halves, and still asks the policy")
struct TimerTickTests {

    // ── Priority 1: the timer keeps all of the data fresh ────────────────────

    @Test("a timer tick over a stale cache fetches the courses")
    func timerTickFetchesCoursesWhenStale() async throws {
        // Arrange — nothing on disk, so `lastFetch` is nil and the cache is
        // infinitely stale: the policy has no reason to decline.
        let scratch = try ScratchDir()
        let clock = ManualClock(epoch)
        let courses = CountingSource([.bytes(try CrossPackageFixture.enrollmentBytes)])
        let work = CountingWorkSource()
        let adapter = makeAdapter(courses: courses, work: work, file: scratch.file(), clock: clock)

        // Act
        await adapter.timerTick()

        // Assert
        #expect(await courses.callCount() == 1)
    }

    @Test("a timer tick refreshes the assignments, so a submenu stops going stale")
    func timerTickRefreshesAssignments() async throws {
        // Arrange — THE gap this method exists to close. The timer used to drive
        // the poller directly, which never touches the assignment half, so every
        // submenu held whatever the last click had fetched.
        let scratch = try ScratchDir()
        let clock = ManualClock(epoch)
        let courses = CountingSource([.bytes(try CrossPackageFixture.enrollmentBytes)])
        let work = CountingWorkSource()
        let adapter = makeAdapter(courses: courses, work: work, file: scratch.file(), clock: clock)

        // Act — the tick, then the menu-open that follows it.
        await adapter.timerTick()
        let model = await adapter.currentMenu()

        // Assert — the row is in the course's submenu, named, so an empty submenu
        // or a submenu of placeholders cannot pass.
        let course = try #require(model.courses.first { $0.id == Work.courseID })
        let rows = course.submenu.assignments
        #expect(rows.map(\.id) == [Work.id])
        #expect(rows.first?.title == Work.name)
    }

    // ── Priority 2: the timer is still governed by PollPolicy ────────────────

    @Test("a timer tick inside the poll interval does not fetch")
    func timerTickInsideTheIntervalDeclines() async throws {
        // Arrange — one fetch just happened, and the clock has not moved. This is
        // what separates `timerTick()` from `refresh()`: `.manual` would fetch
        // again here, and a timer that always fetched would spawn the daemon every
        // 15 minutes whether or not anything could have changed.
        let scratch = try ScratchDir()
        let clock = ManualClock(epoch)
        let courses = CountingSource([.bytes(try CrossPackageFixture.enrollmentBytes)])
        let work = CountingWorkSource()
        let adapter = makeAdapter(courses: courses, work: work, file: scratch.file(), clock: clock)
        _ = await adapter.refresh()
        try #require(await courses.callCount() == 1)

        // Act
        await adapter.timerTick()

        // Assert — still one. The control for this test is
        // `timerTickFetchesCoursesWhenStale`: without it, a `timerTick()` that did
        // nothing at all would pass here perfectly.
        #expect(await courses.callCount() == 1)
    }
}
