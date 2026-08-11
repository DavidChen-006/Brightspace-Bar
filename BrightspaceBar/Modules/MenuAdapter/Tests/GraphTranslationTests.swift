import Foundation
import Testing

import AssignmentPipeline
import CourseMenu
import CoursePipeline
import MenuAdapter

// ═════════════════════════════════════════════════════════════════════════════
// THE GRAPH MAPPING — due-date instants → a 28-cell strip of local days.
//
// This is the arithmetic half of the activity graph: everything between "D2L
// said this is due at instant X" and "the renderer fills cell N". It is a pure
// function of `(state, now, timeZone)`, which is the whole reason it can be
// pinned this densely — no clock, no calendar of the machine, no stored window
// to drift.
//
// PRIORITIES:
//
//   1. THE BUCKETING IS SILENTLY WRONG WHEN IT IS WRONG. A deadline is a UTC
//      instant; a cell is a LOCAL calendar day. `2026-02-13T04:30:00Z` is 23:30
//      on **February 12** in Indiana, and an implementation that reads the UTC
//      day, or that walks the window in 86_400-second steps, draws that work on
//      the wrong square. Nothing downstream can catch it: a filled cell one
//      column over is still a perfectly plausible-looking strip, and the student
//      reads it as "not due until tomorrow". Every date literal below is
//      therefore stated twice — as its UTC instant and as its local wall time —
//      and the expectations were derived from the local side.
//
//   2. NO REGRESSION OF THE SHIPPED MENU. `CourseRow.graph` defaults to `[]`,
//      and a course that has never been fetched must keep it. That is what makes
//      every pre-graph expectation in `MenuTranslationTests`, `CurrentnessTests`,
//      and `AssignmentWiringTests` still describe the menu this build produces.
//
// CULLED: anything about how a cell is DRAWN (colour, size, the today outline's
// geometry) — that is Part D and unobservable from here; and the strip's
// orientation, which the renderer owns. Also culled: fetching, folding, and
// staleness, all already pinned by `AssignmentStore`'s own suite. This file only
// asks where a date lands.
//
// SCOPE: all small. Pure translation over plain values, `now` and `timeZone`
// supplied. No `TimeZone.current`, no `Date()`, anywhere.
// ═════════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────
// PINNED POLICY — the builder implements exactly this.
//
//     public enum GraphTranslation {
//         public static let windowDays = 28
//         /// AssignmentsState + now + timeZone → the 28-cell strip. Pure.
//         public static func strip(
//             state: AssignmentsState, now: Date, timeZone: TimeZone
//         ) -> [GraphCell]
//     }
//
// A new file in `MenuAdapter`, sibling of `AssignmentTranslation` — same shape of
// responsibility (backend values + now + timeZone → contract values), same
// purity rules.
//
// ── The window: 28 local calendar days, forward ─────────────────────────────
//   Cell index = the whole-day offset from the local start of `now`'s day in
//   `timeZone`. Cell 0 is today, cell 27 is the last day shown. Recomputed from
//   `now` on every call — that is RepoBar's range shape with the sign flipped,
//   and it is why the window "shifts" at midnight with no stored state to move.
//
//   Whole CALENDAR days, not 86_400-second steps. The two disagree across a DST
//   transition, and `daysCrossingTheSpringForwardStayWholeDays` is the test that
//   separates them.
//
// ── Bucketing: an instant lands on its LOCAL day ────────────────────────────
//   `dueDate` is a UTC instant; the cell is the local calendar day it falls on
//   in `timeZone`. 23:30 local on day N buckets to day N even though its UTC
//   representation reads day N+1. This is priority 1 and the classic off-by-one.
//
// ── Fill: highest tier wins ─────────────────────────────────────────────────
//   `.assignment → CellTier.assignment`, `.quiz → CellTier.quiz`; a day holding
//   several items renders as `itemsDueThatDay.map(\.tier).max()`. Assignment plus
//   quiz on one day is `.quiz`, because `2 > 1`. Nothing due is `nil` — an empty
//   day, not a zero-th tier, and it still occupies its index.
//
// ── Excluded from the fill (never from the count) ───────────────────────────
//   • `isHidden` items — the same policy the submenu already applies, so a
//     student never sees a square for work D2L is hiding from them.
//   • `dueDate == nil` items — the normal case in every currently reachable
//     course; there is no day to draw them on.
//   • Anything due before today, or on/after day 28.
//   The strip is ALWAYS 28 cells regardless: exclusion empties a cell, it never
//   shortens the strip.
//
//   "Before today" is day-granular, not instant-granular. Work that was due at
//   08:00 this morning still fills today's cell even when `now` is 10:00 —
//   today's square shows what today holds, and `dueDate >= now` would blank it
//   as the day wore on.
//
// ── isToday: exactly index 0, always ────────────────────────────────────────
//   Set on cell 0 and no other, whether or not that cell has a tier. It is
//   orthogonal to the fill — a separate field, never a fill value — which is
//   what makes "the today indicator must not obscure the activity state" hold by
//   construction rather than by careful drawing.
//
// ── States ─────────────────────────────────────────────────────────────────
//     .neverFetched  →  []            (no strip at all; the pre-graph row)
//     .loaded(_)     →  28 cells      (an empty list is data: 28 empty days)
//     .failed(_, _)  →  28 cells      built from `lastKnown`
//   A preserved-stale course keeps drawing its strip, for the same reason its
//   submenu keeps its rows: a failed refresh must never blank work that was
//   there a minute ago.
//
// ── Wiring ─────────────────────────────────────────────────────────────────
//   `MenuTranslation.menu` hands each `CourseRow` a
//   `graph: GraphTranslation.strip(state:now:timeZone:)` for that course's state.
//   A course absent from the assignments map is `neverFetched`, so it keeps
//   `graph == []` and renders exactly as it did before this feature — the
//   guarantee that keeps the existing suite valid.
// ─────────────────────────────────────────────────────────────────────────────

private enum Pinned {
    /// Stated as a literal rather than read from the production constant, so the
    /// window cannot be resized and re-blessed in one edit.
    static let windowDays = 28

    /// A real zone with a real DST rule, chosen over UTC deliberately: in UTC the
    /// local day and the instant's day always agree, so every bucketing bug in
    /// priority 1 would pass. Indiana is five hours behind UTC in February and
    /// four hours behind after March 8.
    static let zone = TimeZone(identifier: "America/Indianapolis")!

    /// `2026-02-10T15:00:00Z` — **10:00 on Feb 10** in Indiana.
    ///
    /// Mid-morning on purpose: it leaves earlier-today and later-today on
    /// opposite sides of `now` while both belong to cell 0.
    static let now = Date(timeIntervalSince1970: 1_770_735_600)

    // ── The window this `now` implies, transcribed by hand from the calendar ──
    //
    //   cell  0 → Feb 10 2026 (today)      cell 27 → Mar  9 2026 (last day)
    //   cell  1 → Feb 11                   cell 28 → Mar 10      (out)
    //
    // Every literal below is the local wall time named in its comment, converted
    // once, by an independent tool. None of them is computed the way the code
    // under test computes it.

    /// 15:00 local on Feb 10 = `2026-02-10T20:00:00Z`. Cell 0.
    static let todayAfternoon = Date(timeIntervalSince1970: 1_770_753_600)
    /// 08:00 local on Feb 10 = `2026-02-10T13:00:00Z`. Cell 0, but BEFORE `now`.
    static let todayMorning = Date(timeIntervalSince1970: 1_770_728_400)
    /// 15:00 local on Feb 11 = `2026-02-11T20:00:00Z`. Cell 1.
    static let tomorrowAfternoon = Date(timeIntervalSince1970: 1_770_840_000)
    /// **23:30 local on Feb 12** = `2026-02-13T04:30:00Z`. Cell 2 — the UTC day
    /// reads Feb 13, the local day is Feb 12. This is the off-by-one.
    static let lateNightOnDayTwo = Date(timeIntervalSince1970: 1_770_957_000)
    /// 01:00 local on Feb 13 = `2026-02-13T06:00:00Z`. Cell 3 — 90 minutes after
    /// `lateNightOnDayTwo`, and a different cell, because the day rolled over.
    static let earlyMorningOnDayThree = Date(timeIntervalSince1970: 1_770_962_400)
    /// 12:00 local on Feb 13 = `2026-02-13T17:00:00Z`. Cell 3.
    static let noonOnDayThree = Date(timeIntervalSince1970: 1_771_002_000)
    /// **00:30 local on Mar 9** = `2026-03-09T04:30:00Z`. Cell 27.
    ///
    /// The hour after the spring-forward, which is why it is here: counting the
    /// window in 86_400-second steps puts this instant at offset 26.98 and files
    /// it under cell 26. Counting calendar days puts it on Mar 9, which is 27.
    static let justAfterSpringForward = Date(timeIntervalSince1970: 1_773_030_600)
    /// 12:00 local on Mar 9 = `2026-03-09T16:00:00Z`. Cell 27 — the last cell.
    static let noonOnTheLastDay = Date(timeIntervalSince1970: 1_773_072_000)
    /// 12:00 local on Mar 10 = `2026-03-10T16:00:00Z`. Day 28 — one past the end.
    static let noonOneDayPastTheWindow = Date(timeIntervalSince1970: 1_773_158_400)
    /// 12:00 local on Feb 9 = `2026-02-09T17:00:00Z`. Yesterday.
    static let noonYesterday = Date(timeIntervalSince1970: 1_770_656_400)

    /// A deadline inside the window from `RealData.midFall2025`, for the wiring
    /// tests: 12:00 local on Oct 2 2025 = `2025-10-02T16:00:00Z`. That instant is
    /// 20:00 on Sep 30 in Indiana, so cell 0 is Sep 30 and this is cell 2.
    static let duringMidFall2025 = Date(timeIntervalSince1970: 1_759_420_800)
}

private enum Real {
    static let scholarlyID = 440_703
    static let civicsID = 412_690
    static let citiID = 445_296
    static let moduleOneQuizID = 476_481
}

private func work(
    _ id: Int,
    _ kind: ItemKind,
    due dueDate: Date?,
    isHidden: Bool = false,
    courseId: Int = Real.scholarlyID
) -> Assignment {
    Assignment(
        id: id, courseId: courseId, name: "Item \(id)", dueDate: dueDate,
        isHidden: isHidden, groupTypeId: nil, kind: kind
    )
}

/// The strip for a successful fetch of `items`, at the pinned instant and zone.
private func strip(_ items: [Assignment]) -> [GraphCell] {
    GraphTranslation.strip(state: .loaded(items), now: Pinned.now, timeZone: Pinned.zone)
}

/// Which cells carry work, as `index: tier`. Empty days are absent rather than
/// present-and-nil, so an assertion states the whole fill in one literal and a
/// stray filled cell anywhere in the 28 fails it.
private func filled(_ cells: [GraphCell]) -> [Int: CellTier] {
    cells.enumerated().reduce(into: [:]) { result, pair in
        if let tier = pair.element.tier { result[pair.offset] = tier }
    }
}

private func realMenu(assignments: [Int: AssignmentsState]) throws -> MenuModel {
    MenuTranslation.menu(
        courses: try CrossPackageFixture.realCourses,
        lastFetch: RealData.midFall2025,
        now: RealData.midFall2025,
        baseURL: RealData.baseURL,
        assignments: assignments,
        timeZone: Pinned.zone
    )
}

private extension MenuModel {
    func course(id: Int) -> CourseRow? { self.courses.first { $0.id == id } }
}

@Suite("Graph mapping — due dates into the 28-day strip")
struct GraphTranslationTests {

    // MARK: - The window exists, and is always the same size

    @Test("a course that has never been fetched gets no strip at all")
    func neverFetchedDrawsNothing() {
        // Arrange / Act — the launch state of every course, since assignments are
        // deliberately not persisted.
        let cells = GraphTranslation.strip(
            state: .neverFetched, now: Pinned.now, timeZone: Pinned.zone
        )

        // Assert — empty, not 28 empty days. A strip of blank squares would claim
        // "nothing is due for the next four weeks", which nothing here knows.
        #expect(cells.isEmpty)
    }

    @Test("a loaded course gets 28 cells even when it has no work at all")
    func aLoadedCourseAlwaysGetsTheWholeWindow() {
        // Arrange / Act — an empty list here is data: the server said there is
        // nothing due.
        let cells = strip([])

        // Assert — the window is a fixed 28 days, and every one of them is empty.
        #expect(cells.count == Pinned.windowDays)
        #expect(GraphTranslation.windowDays == Pinned.windowDays)
        #expect(filled(cells).isEmpty)
    }

    // MARK: - Today

    @Test("today is cell 0 and no other cell claims to be today")
    func todayIsMarkedOnceAtTheStart() {
        // Arrange / Act — no work at all, so nothing can confuse the marker with
        // a fill.
        let cells = strip([])

        // Assert
        #expect(cells.map(\.isToday) == [true] + Array(repeating: false, count: 27))
    }

    @Test("the today marker does not displace today's work")
    func todaysMarkerCoexistsWithTodaysTier() {
        // Arrange — the invariant the whole two-field design exists for: the
        // indicator must not destroy or obscure the underlying activity state.
        let items = [work(Real.citiID, .assignment, due: Pinned.todayAfternoon)]

        // Act
        let cells = strip(items)

        // Assert — both, on the same cell.
        #expect(cells[0] == GraphCell(tier: .assignment, isToday: true))
    }

    // MARK: - Where a deadline lands

    @Test("an assignment due today fills today's cell")
    func assignmentDueTodayFillsCellZero() {
        // Arrange
        let items = [work(Real.citiID, .assignment, due: Pinned.todayAfternoon)]

        // Act
        let cells = strip(items)

        // Assert — cell 0, and nothing else touched.
        #expect(filled(cells) == [0: .assignment])
    }

    @Test("a quiz due tomorrow fills the next cell along")
    func quizDueTomorrowFillsCellOne() {
        // Arrange
        let items = [work(Real.moduleOneQuizID, .quiz, due: Pinned.tomorrowAfternoon)]

        // Act
        let cells = strip(items)

        // Assert — the kind maps to its tier, and today stays empty.
        #expect(filled(cells) == [1: .quiz])
    }

    @Test("work due earlier today still fills today's cell")
    func workDueThisMorningStillFillsToday() {
        // Arrange — due at 08:00 local, with `now` at 10:00. The exclusion is
        // "before today", a whole day; `dueDate >= now` would blank today's
        // square as the morning wore on.
        let items = [work(Real.citiID, .assignment, due: Pinned.todayMorning)]

        // Act
        let cells = strip(items)

        // Assert
        #expect(filled(cells) == [0: .assignment])
    }

    @Test("a deadline late at night belongs to its local day, not to its UTC day")
    func lateNightDeadlineBucketsToTheLocalDay() {
        // Arrange — priority 1. `2026-02-13T04:30:00Z` reads as Feb 13 in UTC and
        // as 23:30 on Feb 12 in Indiana. Feb 12 is cell 2; reading the UTC day
        // draws it on cell 3 and tells the student they have an extra day.
        let items = [work(Real.citiID, .assignment, due: Pinned.lateNightOnDayTwo)]

        // Act
        let cells = strip(items)

        // Assert
        #expect(filled(cells) == [2: .assignment])
    }

    @Test("days crossing the spring-forward are still whole calendar days")
    func daysCrossingTheSpringForwardStayWholeDays() {
        // Arrange — 00:30 local on Mar 9, the hour after Indiana loses an hour.
        // The window began Feb 10, so this is calendar day 27 — but only 26.98
        // × 86_400 seconds have elapsed, so step-counting files it under 26.
        let items = [work(Real.citiID, .assignment, due: Pinned.justAfterSpringForward)]

        // Act
        let cells = strip(items)

        // Assert
        #expect(filled(cells) == [27: .assignment])
    }

    // MARK: - Highest tier wins

    @Test("a day holding both kinds renders as the quiz")
    func quizOutranksAssignmentOnTheSameDay() {
        // Arrange — both due at different hours of Feb 13, which is one local day
        // and therefore one cell. The quiz is listed FIRST so a last-one-wins
        // implementation answers `.assignment` and fails here.
        let items = [
            work(Real.moduleOneQuizID, .quiz, due: Pinned.noonOnDayThree),
            work(Real.citiID, .assignment, due: Pinned.earlyMorningOnDayThree),
        ]

        // Act
        let cells = strip(items)

        // Assert — one cell, filled with the more important kind.
        #expect(filled(cells) == [3: .quiz])
    }

    @Test("the winning kind does not depend on the order the items arrive in")
    func theWinnerIsOrderIndependent() {
        // Arrange — the same day, the same two items, the opposite order. Paired
        // with the test above this pins `max()` rather than either end of the
        // list; it also protects `MenuModel`'s `Equatable`, which the GUI uses to
        // skip rebuilding an unchanged menu.
        let items = [
            work(Real.citiID, .assignment, due: Pinned.earlyMorningOnDayThree),
            work(Real.moduleOneQuizID, .quiz, due: Pinned.noonOnDayThree),
        ]

        // Act
        let cells = strip(items)

        // Assert
        #expect(filled(cells) == [3: .quiz])
    }

    // MARK: - The window's edges

    @Test("work due on the window's last day fills the last cell")
    func workDueOnDayTwentySevenFillsTheLastCell() {
        // Arrange — Mar 9, the 28th and final day of a window that opened Feb 10.
        let items = [work(Real.citiID, .assignment, due: Pinned.noonOnTheLastDay)]

        // Act
        let cells = strip(items)

        // Assert — the last index is 27, not 28: an inclusive-end off-by-one would
        // either drop this or run off the end of the array.
        #expect(filled(cells) == [Pinned.windowDays - 1: .assignment])
    }

    @Test("work due one day past the window is excluded")
    func workDueOnDayTwentyEightIsExcluded() {
        // Arrange — Mar 10, the first day the strip does not cover.
        let items = [work(Real.citiID, .assignment, due: Pinned.noonOneDayPastTheWindow)]

        // Act
        let cells = strip(items)

        // Assert — nothing drawn, and the strip is still its full length.
        #expect(filled(cells).isEmpty)
        #expect(cells.count == Pinned.windowDays)
    }

    @Test("work due yesterday is excluded — the window only looks forward")
    func workDueYesterdayIsExcluded() {
        // Arrange — this is the one adaptation of RepoBar's window that matters:
        // theirs trails behind today, ours starts at it.
        let items = [work(Real.citiID, .assignment, due: Pinned.noonYesterday)]

        // Act
        let cells = strip(items)

        // Assert
        #expect(filled(cells).isEmpty)
        #expect(cells.count == Pinned.windowDays)
    }

    // MARK: - What never reaches a cell

    @Test("hidden work is excluded, exactly as it is from the submenu")
    func hiddenWorkIsExcluded() {
        // Arrange — `isHidden` is D2L's own "not visible to students" flag, and
        // `QuizParser` maps `IsActive: false` onto it, so one policy covers both
        // kinds. A square for work the student cannot open is worse than no
        // square.
        let items = [
            work(Real.citiID, .assignment, due: Pinned.todayAfternoon, isHidden: true),
            work(Real.moduleOneQuizID, .quiz, due: Pinned.tomorrowAfternoon, isHidden: true),
        ]

        // Act
        let cells = strip(items)

        // Assert
        #expect(filled(cells).isEmpty)
    }

    @Test("undated work is excluded without shortening the strip")
    func undatedWorkIsExcludedAndTheStripKeepsItsLength() {
        // Arrange — the normal case today: all four currently reachable
        // assignments have `DueDate: null`. There is no day to draw them on.
        let items = [
            work(Real.citiID, .assignment, due: nil),
            work(Real.moduleOneQuizID, .quiz, due: nil),
        ]

        // Act
        let cells = strip(items)

        // Assert — the course still gets its (empty) four weeks. Collapsing to
        // `[]` here would make an all-undated course look unfetched.
        #expect(filled(cells).isEmpty)
        #expect(cells.count == Pinned.windowDays)
        #expect(cells[0].isToday)
    }

    // MARK: - States

    @Test("a failed refresh still draws the work it is holding")
    func failedStateDrawsItsHeldItems() {
        // Arrange — the preserved-stale case: the fetch died, but the store still
        // holds what loaded a minute ago. Blanking the strip would say the work
        // disappeared, which is the same lie the submenu refuses to tell.
        let held = [
            work(Real.citiID, .assignment, due: Pinned.todayAfternoon),
            work(Real.moduleOneQuizID, .quiz, due: Pinned.tomorrowAfternoon),
        ]

        // Act
        let cells = GraphTranslation.strip(
            state: .failed(lastKnown: held, error: .transport("offline")),
            now: Pinned.now,
            timeZone: Pinned.zone
        )

        // Assert
        #expect(cells.count == Pinned.windowDays)
        #expect(filled(cells) == [0: .assignment, 1: .quiz])
    }

    @Test("a failure with nothing held still draws the empty window")
    func failedWithNothingHeldStillDrawsTheWindow() {
        // Arrange / Act — the dead-session-on-first-fetch case. `neverFetched` is
        // the ONLY state that yields no strip; a failure is a state the course
        // has been in, so it keeps its shape.
        let cells = GraphTranslation.strip(
            state: .failed(lastKnown: [], error: .sessionExpired),
            now: Pinned.now,
            timeZone: Pinned.zone
        )

        // Assert
        #expect(cells.count == Pinned.windowDays)
        #expect(filled(cells).isEmpty)
    }

    // MARK: - Wiring through the menu

    @Test("a course with loaded assignments carries its strip on its row")
    func aLoadedCourseCarriesAGraph() throws {
        // Arrange — the real 27-course payload, at the instant the rest of the
        // suite probes, with one dated assignment for the Scholarly Project.
        let state = AssignmentsState.loaded([
            work(Real.citiID, .assignment, due: Pinned.duringMidFall2025),
        ])

        // Act
        let model = try realMenu(assignments: [Real.scholarlyID: state])

        // Assert — the strip reached the row, and the deadline landed on the cell
        // its local day names (Oct 2, two days after the Sep 30 that `now` is
        // locally).
        let scholarly = try #require(model.course(id: Real.scholarlyID))
        #expect(scholarly.graph.count == Pinned.windowDays)
        #expect(filled(scholarly.graph) == [2: .assignment])
    }

    @Test("a course with no assignment state carries no graph")
    func anUnfetchedCourseCarriesNoGraph() throws {
        // Arrange / Act — Civics is absent from the map, so it is `neverFetched`.
        // This is priority 2: an absent entry must reproduce the pre-graph row
        // exactly, which is what keeps every existing menu expectation valid.
        let state = AssignmentsState.loaded([
            work(Real.citiID, .assignment, due: Pinned.duringMidFall2025),
        ])
        let model = try realMenu(assignments: [Real.scholarlyID: state])

        // Assert — one course gained a strip; every other visible course kept the
        // empty default.
        let civics = try #require(model.course(id: Real.civicsID))
        #expect(civics.graph.isEmpty)
        #expect(model.courses.filter { !$0.graph.isEmpty }.map(\.id) == [Real.scholarlyID])
    }

    @Test("an empty assignments map leaves every course exactly as it was")
    func anEmptyMapAddsNoGraphsAtAll() throws {
        // Arrange / Act — the guarantee the whole default-`[]` design buys: the
        // pre-graph output, reproduced.
        let model = try realMenu(assignments: [:])

        // Assert
        #expect(Set(model.courses.map(\.id)) == RealData.visibleIDsAtMidFall2025)
        #expect(model.courses.allSatisfy { $0.graph.isEmpty })
    }
}
