import Foundation
import Testing

import AssignmentPipeline
import CourseMenu
import CoursePipeline
import MenuAdapter

// ═════════════════════════════════════════════════════════════════════════════
// THE GRAPH MAPPING — due-date instants → a 112-cell window of local days.
//
// This is the arithmetic half of the activity graph: everything between "D2L
// said this is due at instant X" and "the renderer fills cell N". It is a pure
// function of `(state, now, timeZone)`, which is the whole reason it can be
// pinned this densely — no clock, no calendar of the machine, no stored window
// to drift.
//
// RE-PINNED for NewVertical-3 §4: the window was 28 days starting at today, and
// `.neverFetched` yielded `[]`. It is now 112 days (16 weeks) starting on the
// SUNDAY of today's week, emitted for every state including `.neverFetched`.
//
// PRIORITIES:
//
//   1. THE BUCKETING IS SILENTLY WRONG WHEN IT IS WRONG. A deadline is a UTC
//      instant; a cell is a LOCAL calendar day. `2026-02-13T04:30:00Z` is 23:30
//      on **February 12** in Indiana, and an implementation that reads the UTC
//      day, or that walks the window in 86_400-second steps, draws that work on
//      the wrong square. Nothing downstream can catch it: a filled cell one
//      column over is still a perfectly plausible-looking grid, and the student
//      reads it as "not due until tomorrow". Every date literal below is
//      therefore stated twice — as its UTC instant and as its local wall time —
//      and the expectations were derived from the local side.
//
//   2. THE WINDOW'S ORIGIN IS LOAD-BEARING AND EQUALLY SILENT. §3.3's seam
//      promises the frontend that `index = day offset from window start`, that
//      the window STARTS ON A WEEK BOUNDARY, and that N is a multiple of 7.
//      Slice 4 derives `row = i % 7` from exactly that and labels row 0 Sunday.
//      A window that opens on today instead of Sunday still renders a perfectly
//      plausible grid — every cell simply sits under the wrong weekday, and the
//      M/W/F labels lie. There is no `windowStart` in the contract to assert on,
//      so alignment is pinned the only way it is observable: by where known
//      local days land. `todayIsNotAlwaysCellZero` and
//      `theWindowOpensOnTheSundayOfTodaysWeek` are the tests that catch it.
//
// CULLED: anything about how a cell is DRAWN (colour, size, the today outline's
// geometry) — that is slice 4 and unobservable from here; and the grid's
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
//         public static let windowDays = 112
//         /// AssignmentsState + now + timeZone → the 112-cell window. Pure.
//         public static func strip(
//             state: AssignmentsState, now: Date, timeZone: TimeZone
//         ) -> [GraphCell]
//     }
//
// The API surface does NOT change — only the values it produces. Same file, same
// signature, same purity rules.
//
// ── The window: 112 local calendar days, week-aligned ───────────────────────
//   Cell index = the whole-day offset from WINDOW START, where window start is
//   the local start of the SUNDAY of the week containing `now`'s local day, in
//   `timeZone`. Sunday because that is GitHub's convention and slice 4's row-0
//   label assumes it; `now` itself lands somewhere in cells 0–6.
//
//   112 = 16 × 7. A whole number of weeks is not decoration: §3.3 promises the
//   renderer that N is a multiple of 7, and a ragged final column would be a
//   contract violation the renderer cannot detect.
//
//   Recomputed from `now` on every call — no stored window to drift, which is
//   why the grid "shifts" a week at a time with no state to move.
//
//   Whole CALENDAR days, not 86_400-second steps. The two disagree across a DST
//   transition, and `daysCrossingTheSpringForwardStayWholeDays` is the test that
//   separates them.
//
//   Computed with `Calendar` in the INJECTED `timeZone`. No `Date()`, no
//   `.current`, no `Locale` from the machine.
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
//   • Anything due before WINDOW START, or on/after day 112.
//   The window is ALWAYS 112 cells regardless: exclusion empties a cell, it
//   never shortens the window.
//
//   NOTE the changed lower bound. The exclusion is no longer "before today" —
//   it is "before the window", and the window now opens up to six days behind
//   today. Work due on Monday when today is Tuesday DOES fill Monday's cell:
//   the grid shows the current week honestly, including the part of it that has
//   already passed. `workDueEarlierThisWeekStillFillsItsCell` pins this, and it
//   is the direct inversion of the old `workDueYesterdayIsExcluded`.
//
//   Within a day the bound stays day-granular, not instant-granular. Work due
//   at 08:00 this morning still fills today's cell when `now` is 10:00.
//
// ── isToday: the true today cell, wherever that falls ───────────────────────
//   Set on the cell whose local day is `now`'s local day — index 0 through 6,
//   NOT index 0 by construction — and on no other cell. Exactly one cell
//   carries it. It stays orthogonal to the fill: a separate field, never a fill
//   value, which is what makes "the today indicator must not obscure the
//   activity state" hold by construction rather than by careful drawing.
//
// ── States: the window is emitted for ALL of them ──────────────────────────
//     .neverFetched  →  112 cells     (§2 item 2: an absent grid reads as a bug)
//     .loaded(_)     →  112 cells     (an empty list is data: 112 empty days)
//     .failed(_, _)  →  112 cells     built from `lastKnown`
//   `[]` is no longer a reachable output. A missing grid is indistinguishable
//   from a rendering failure; an empty grid honestly says "nothing due". The
//   decision lives here, in the pure layer, so the renderer never invents cells.
//
// ── Wiring ─────────────────────────────────────────────────────────────────
//   `MenuTranslation.menu` hands each `CourseRow` a
//   `graph: GraphTranslation.strip(state:now:timeZone:)` for that course's state.
//   A course absent from the assignments map is `neverFetched` — and now that
//   too carries a full, empty window, so EVERY course row in the menu has a
//   grid. Uniformity is the point (§2 item 2).
// ─────────────────────────────────────────────────────────────────────────────

private enum Pinned {
    /// Stated as a literal rather than read from the production constant, so the
    /// window cannot be resized and re-blessed in one edit.
    static let windowDays = 112

    /// A real zone with a real DST rule, chosen over UTC deliberately: in UTC the
    /// local day and the instant's day always agree, so every bucketing bug in
    /// priority 1 would pass. Indiana is five hours behind UTC in February and
    /// four hours behind after March 8.
    static let zone = TimeZone(identifier: "America/Indianapolis")!

    /// `2026-02-10T15:00:00Z` — **10:00 on TUESDAY Feb 10** in Indiana.
    ///
    /// Mid-morning on purpose: it leaves earlier-today and later-today on
    /// opposite sides of `now` while both belong to the same cell. A Tuesday on
    /// purpose too: a mid-week `now` is what separates "the window opens on
    /// Sunday" from "the window opens on today", and it puts two already-passed
    /// days inside the window.
    static let now = Date(timeIntervalSince1970: 1_770_735_600)

    /// Where `now`'s own day sits. **Not 0** — that is the whole point of the
    /// alignment change. Feb 10 2026 is a Tuesday, so today is the third cell of
    /// week one, counting from Sunday.
    static let todayIndex = 2

    // ── The window this `now` implies, transcribed by hand from the calendar ──
    //
    //   cell   0 → Sun Feb  8 2026 (window start)   cell   2 → Tue Feb 10 (today)
    //   cell   1 → Mon Feb  9      (already passed)  cell 111 → Sat May 30 (last)
    //   cell  -1 → Sat Feb  7      (out, behind)     cell 112 → Sun May 31 (out)
    //
    // Feb 8 is a Sunday and May 30 is a Saturday — 16 whole weeks, opening and
    // closing on the week boundaries §3.3 promises.
    //
    // Every literal below is the local wall time named in its comment, converted
    // once, by an independent tool. None of them is computed the way the code
    // under test computes it.

    /// 12:00 local on **Sun Feb 8** = `2026-02-08T17:00:00Z`. Cell 0 — the
    /// window's first day, two days BEHIND today.
    static let noonOnTheWindowsFirstDay = Date(timeIntervalSince1970: 1_770_570_000)
    /// 12:00 local on **Sat Feb 7** = `2026-02-07T17:00:00Z`. One day behind the
    /// window's start, and the last Saturday of the previous week.
    static let noonTheDayBeforeTheWindow = Date(timeIntervalSince1970: 1_770_483_600)
    /// 12:00 local on **Mon Feb 9** = `2026-02-09T17:00:00Z`. Cell 1 — yesterday,
    /// which is now INSIDE the window because it is earlier this same week.
    static let noonEarlierThisWeek = Date(timeIntervalSince1970: 1_770_656_400)
    /// 15:00 local on Feb 10 = `2026-02-10T20:00:00Z`. Cell 2 — today.
    static let todayAfternoon = Date(timeIntervalSince1970: 1_770_753_600)
    /// 08:00 local on Feb 10 = `2026-02-10T13:00:00Z`. Cell 2, but BEFORE `now`.
    static let todayMorning = Date(timeIntervalSince1970: 1_770_728_400)
    /// 15:00 local on Feb 11 = `2026-02-11T20:00:00Z`. Cell 3.
    static let tomorrowAfternoon = Date(timeIntervalSince1970: 1_770_840_000)
    /// **23:30 local on Feb 12** = `2026-02-13T04:30:00Z`. Cell 4 — the UTC day
    /// reads Feb 13, the local day is Feb 12. This is the off-by-one.
    static let lateNightOnFebTwelfth = Date(timeIntervalSince1970: 1_770_957_000)
    /// 01:00 local on Feb 13 = `2026-02-13T06:00:00Z`. Cell 5 — 90 minutes after
    /// `lateNightOnFebTwelfth`, and a different cell, because the day rolled over.
    static let earlyMorningOnFebThirteenth = Date(timeIntervalSince1970: 1_770_962_400)
    /// 12:00 local on Feb 13 = `2026-02-13T17:00:00Z`. Cell 5.
    static let noonOnFebThirteenth = Date(timeIntervalSince1970: 1_771_002_000)
    /// **00:30 local on Mar 9** = `2026-03-09T04:30:00Z`. Cell 29.
    ///
    /// The hour after the spring-forward, which is why it is here: counting the
    /// window in 86_400-second steps from Feb 8 puts this instant at offset 28.98
    /// and files it under cell 28. Counting calendar days puts it on Mar 9,
    /// which is 29.
    static let justAfterSpringForward = Date(timeIntervalSince1970: 1_773_030_600)
    /// 12:00 local on **Sat May 30** = `2026-05-30T16:00:00Z` (EDT by then).
    /// Cell 111 — the window's final day.
    static let noonOnTheLastDay = Date(timeIntervalSince1970: 1_780_156_800)
    /// 12:00 local on **Sun May 31** = `2026-05-31T16:00:00Z`. Day 112 — one past
    /// the end, and the first day of the week after the window.
    static let noonOneDayPastTheWindow = Date(timeIntervalSince1970: 1_780_243_200)

    /// A deadline inside the window from `RealData.midFall2025`, for the wiring
    /// tests: 12:00 local on Thu Oct 2 2025 = `2025-10-02T16:00:00Z`. That `now`
    /// is 20:00 on Tuesday Sep 30 in Indiana, so the window opens on Sun Sep 28
    /// and this is cell 4.
    static let duringMidFall2025 = Date(timeIntervalSince1970: 1_759_420_800)
    /// Where `RealData.midFall2025` itself lands: Tue Sep 30, cell 2.
    static let midFall2025TodayIndex = 2
    /// The cell `duringMidFall2025` fills: Thu Oct 2.
    static let duringMidFall2025Index = 4
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
/// stray filled cell anywhere in the 112 fails it.
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

@Suite("Graph mapping — due dates into the 112-day week-aligned window")
struct GraphTranslationTests {

    // MARK: - The window exists, and is always the same size

    @Test("a course that has never been fetched still gets the whole empty window")
    func neverFetchedStillDrawsTheWholeWindow() {
        // Arrange / Act — the launch state of every course, since assignments are
        // deliberately not persisted. This is the inversion of the old `[]`
        // policy (§2 item 2): a missing grid is indistinguishable from a bug,
        // where an empty grid honestly says "nothing known to be due".
        let cells = GraphTranslation.strip(
            state: .neverFetched, now: Pinned.now, timeZone: Pinned.zone
        )

        // Assert — the full window, all empty, today still marked. `[]` is no
        // longer a reachable output of this function at all.
        #expect(cells.count == Pinned.windowDays)
        #expect(filled(cells).isEmpty)
        #expect(cells.firstIndex(where: \.isToday) == Pinned.todayIndex)
    }

    @Test("a loaded course gets 112 cells even when it has no work at all")
    func aLoadedCourseAlwaysGetsTheWholeWindow() {
        // Arrange / Act — an empty list here is data: the server said there is
        // nothing due.
        let cells = strip([])

        // Assert — the window is a fixed 112 days, and every one of them is empty.
        #expect(cells.count == Pinned.windowDays)
        #expect(GraphTranslation.windowDays == Pinned.windowDays)
        #expect(filled(cells).isEmpty)
    }

    @Test("the window is a whole number of weeks, as the renderer is promised")
    func theWindowIsAWholeNumberOfWeeks() {
        // Arrange / Act — §3.3's seam promise, stated as its own claim rather
        // than left implicit in the constant. Slice 4 derives `row = i % 7` from
        // this; a window that is not a multiple of 7 gives the grid a ragged
        // final column and there is nothing downstream that can notice.
        let cells = strip([])

        // Assert — 16 weeks exactly, and the emitted array agrees with it.
        #expect(GraphTranslation.windowDays % 7 == 0)
        #expect(GraphTranslation.windowDays == 16 * 7)
        #expect(cells.count % 7 == 0)
    }

    // MARK: - Where the window opens

    @Test("the window opens on the Sunday of today's week, not on today")
    func theWindowOpensOnTheSundayOfTodaysWeek() {
        // Arrange — priority 2, and the only way it is observable: the contract
        // carries no `windowStart`, so alignment has to be read off where a known
        // local day lands. `now` is Tuesday Feb 10, so cell 0 must be Sunday
        // Feb 8 — and the Saturday before it must fall outside.
        let items = [
            work(Real.citiID, .assignment, due: Pinned.noonOnTheWindowsFirstDay),
            work(Real.moduleOneQuizID, .quiz, due: Pinned.noonTheDayBeforeTheWindow),
        ]

        // Act
        let cells = strip(items)

        // Assert — Sunday is cell 0; the preceding Saturday is not drawn at all.
        // A window that opened at today would put Feb 8 outside and fail here.
        #expect(filled(cells) == [0: .assignment])
    }

    // MARK: - Today

    @Test("today is not cell 0 — it sits where its weekday puts it")
    func todayIsNotAlwaysCellZero() {
        // Arrange / Act — the headline behaviour change, asserted directly so it
        // cannot be lost in an aggregate. Tuesday is the third day of a
        // Sunday-first week.
        let cells = strip([])

        // Assert
        #expect(cells.firstIndex { $0.isToday } == Pinned.todayIndex)
        #expect(Pinned.todayIndex != 0, "the fixture no longer exercises the change it exists for")
    }

    @Test("exactly one cell claims to be today")
    func todayIsMarkedExactlyOnce() {
        // Arrange / Act — no work at all, so nothing can confuse the marker with
        // a fill. Stated as a count over the whole window rather than as an index
        // list, so a second stamp anywhere in the 16 weeks fails it.
        let cells = strip([])

        // Assert
        #expect(cells.indices.filter { cells[$0].isToday } == [Pinned.todayIndex])
    }

    @Test("the today marker does not displace today's work")
    func todaysMarkerCoexistsWithTodaysTier() {
        // Arrange — the invariant the whole two-field design exists for: the
        // indicator must not destroy or obscure the underlying activity state.
        let items = [work(Real.citiID, .assignment, due: Pinned.todayAfternoon)]

        // Act
        let cells = strip(items)

        // Assert — both, on the same cell.
        #expect(cells[Pinned.todayIndex] == GraphCell(tier: .assignment, isToday: true))
    }

    // MARK: - Where a deadline lands

    @Test("an assignment due today fills today's cell")
    func assignmentDueTodayFillsTodaysCell() {
        // Arrange
        let items = [work(Real.citiID, .assignment, due: Pinned.todayAfternoon)]

        // Act
        let cells = strip(items)

        // Assert — today's cell, and nothing else touched.
        #expect(filled(cells) == [Pinned.todayIndex: .assignment])
    }

    @Test("a quiz due tomorrow fills the next cell along")
    func quizDueTomorrowFillsTheFollowingCell() {
        // Arrange
        let items = [work(Real.moduleOneQuizID, .quiz, due: Pinned.tomorrowAfternoon)]

        // Act
        let cells = strip(items)

        // Assert — the kind maps to its tier, and today stays empty.
        #expect(filled(cells) == [Pinned.todayIndex + 1: .quiz])
    }

    @Test("work due earlier today still fills today's cell")
    func workDueThisMorningStillFillsToday() {
        // Arrange — due at 08:00 local, with `now` at 10:00. Bucketing is
        // day-granular, not instant-granular; `dueDate >= now` would blank
        // today's square as the morning wore on.
        let items = [work(Real.citiID, .assignment, due: Pinned.todayMorning)]

        // Act
        let cells = strip(items)

        // Assert
        #expect(filled(cells) == [Pinned.todayIndex: .assignment])
    }

    @Test("work due earlier this week fills its own cell rather than being dropped")
    func workDueEarlierThisWeekStillFillsItsCell() {
        // Arrange — Monday, with `now` on Tuesday. This is the direct inversion
        // of the old `workDueYesterdayIsExcluded`: the window no longer opens at
        // today, so the days of the current week that have already passed are
        // inside it and must be drawn. The grid shows this week honestly —
        // silently blanking Monday would make a missed deadline invisible.
        let items = [work(Real.citiID, .assignment, due: Pinned.noonEarlierThisWeek)]

        // Act
        let cells = strip(items)

        // Assert — cell 1, one behind today's cell 2.
        #expect(filled(cells) == [1: .assignment])
    }

    @Test("a deadline late at night belongs to its local day, not to its UTC day")
    func lateNightDeadlineBucketsToTheLocalDay() {
        // Arrange — priority 1. `2026-02-13T04:30:00Z` reads as Feb 13 in UTC and
        // as 23:30 on Feb 12 in Indiana. Feb 12 is cell 4; reading the UTC day
        // draws it on cell 5 and tells the student they have an extra day.
        let items = [work(Real.citiID, .assignment, due: Pinned.lateNightOnFebTwelfth)]

        // Act
        let cells = strip(items)

        // Assert
        #expect(filled(cells) == [4: .assignment])
    }

    @Test("days crossing the spring-forward are still whole calendar days")
    func daysCrossingTheSpringForwardStayWholeDays() {
        // Arrange — 00:30 local on Mar 9, the hour after Indiana loses an hour.
        // The window began Sun Feb 8, so this is calendar day 29 — but only 28.98
        // × 86_400 seconds have elapsed, so step-counting files it under 28.
        let items = [work(Real.citiID, .assignment, due: Pinned.justAfterSpringForward)]

        // Act
        let cells = strip(items)

        // Assert
        #expect(filled(cells) == [29: .assignment])
    }

    // MARK: - Highest tier wins

    @Test("a day holding both kinds renders as the quiz")
    func quizOutranksAssignmentOnTheSameDay() {
        // Arrange — both due at different hours of Feb 13, which is one local day
        // and therefore one cell. The quiz is listed FIRST so a last-one-wins
        // implementation answers `.assignment` and fails here.
        let items = [
            work(Real.moduleOneQuizID, .quiz, due: Pinned.noonOnFebThirteenth),
            work(Real.citiID, .assignment, due: Pinned.earlyMorningOnFebThirteenth),
        ]

        // Act
        let cells = strip(items)

        // Assert — one cell, filled with the more important kind.
        #expect(filled(cells) == [5: .quiz])
    }

    @Test("the winning kind does not depend on the order the items arrive in")
    func theWinnerIsOrderIndependent() {
        // Arrange — the same day, the same two items, the opposite order. Paired
        // with the test above this pins `max()` rather than either end of the
        // list; it also protects `MenuModel`'s `Equatable`, which the GUI uses to
        // skip rebuilding an unchanged menu.
        let items = [
            work(Real.citiID, .assignment, due: Pinned.earlyMorningOnFebThirteenth),
            work(Real.moduleOneQuizID, .quiz, due: Pinned.noonOnFebThirteenth),
        ]

        // Act
        let cells = strip(items)

        // Assert
        #expect(filled(cells) == [5: .quiz])
    }

    // MARK: - The window's edges

    @Test("work due on the window's last day fills the last cell")
    func workDueOnTheFinalDayFillsTheLastCell() {
        // Arrange — Sat May 30, the 112th and final day of a window that opened
        // Sun Feb 8.
        let items = [work(Real.citiID, .assignment, due: Pinned.noonOnTheLastDay)]

        // Act
        let cells = strip(items)

        // Assert — the last index is 111, not 112: an inclusive-end off-by-one
        // would either drop this or run off the end of the array.
        #expect(filled(cells) == [Pinned.windowDays - 1: .assignment])
    }

    @Test("work due one day past the window is excluded")
    func workDueOneDayPastTheWindowIsExcluded() {
        // Arrange — Sun May 31, the first day the window does not cover.
        let items = [work(Real.citiID, .assignment, due: Pinned.noonOneDayPastTheWindow)]

        // Act
        let cells = strip(items)

        // Assert — nothing drawn, and the window is still its full length.
        #expect(filled(cells).isEmpty)
        #expect(cells.count == Pinned.windowDays)
    }

    @Test("work due before the window's first day is excluded")
    func workDueBeforeTheWindowIsExcluded() {
        // Arrange — Sat Feb 7, the day before the window opens. The lower bound
        // moved with the window: it is "before window start", not "before today",
        // and this is the cell that would be index -1.
        let items = [work(Real.citiID, .assignment, due: Pinned.noonTheDayBeforeTheWindow)]

        // Act
        let cells = strip(items)

        // Assert — dropped, not clamped onto cell 0, and the window keeps its
        // length. Clamping would file last week's work under this Sunday.
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

        // Assert — the course still gets its (empty) sixteen weeks. Collapsing to
        // `[]` here would make an all-undated course look unfetched.
        #expect(filled(cells).isEmpty)
        #expect(cells.count == Pinned.windowDays)
        #expect(cells[Pinned.todayIndex].isToday)
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
        #expect(filled(cells) == [Pinned.todayIndex: .assignment, Pinned.todayIndex + 1: .quiz])
    }

    @Test("a failure with nothing held still draws the empty window")
    func failedWithNothingHeldStillDrawsTheWindow() {
        // Arrange / Act — the dead-session-on-first-fetch case. Every state now
        // yields the window; this test survives the always-emit change unchanged
        // because a failure always kept its shape.
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

        // Assert — the window reached the row, and the deadline landed on the cell
        // its local day names. `now` is Tuesday Sep 30 locally, so the window
        // opens Sunday Sep 28 and Thursday Oct 2 is cell 4.
        let scholarly = try #require(model.course(id: Real.scholarlyID))
        #expect(scholarly.graph.count == Pinned.windowDays)
        #expect(filled(scholarly.graph) == [Pinned.duringMidFall2025Index: .assignment])
        #expect(scholarly.graph.firstIndex(where: \.isToday) == Pinned.midFall2025TodayIndex)
    }

    @Test("a course with no assignment state still carries a full empty window")
    func anUnfetchedCourseStillCarriesTheWindow() throws {
        // Arrange / Act — Civics is absent from the map, so it is `neverFetched`.
        // Under always-emit that no longer means "no graph": it means a full
        // window with nothing in it, so Civics' row is the same shape as
        // Scholarly's and the two cannot be told apart by height (§2 item 2).
        let state = AssignmentsState.loaded([
            work(Real.citiID, .assignment, due: Pinned.duringMidFall2025),
        ])
        let model = try realMenu(assignments: [Real.scholarlyID: state])

        // Assert — same length, no fills; the tiered one is still the only course
        // carrying work, which is what proves the graph is joined per course
        // rather than handed to everyone.
        let civics = try #require(model.course(id: Real.civicsID))
        #expect(civics.graph.count == Pinned.windowDays)
        #expect(filled(civics.graph).isEmpty)
        #expect(model.courses.filter { !filled($0.graph).isEmpty }.map(\.id) == [Real.scholarlyID])
    }

    @Test("an empty assignments map still gives every course its window")
    func anEmptyMapStillGivesEveryCourseAWindow() throws {
        // Arrange / Act — the uniformity guarantee, over the real 27-course
        // payload: with nothing fetched at all, every visible course still gets
        // a grid. This is the launch state of the app, and it is the state §2
        // item 2 exists for — no course may render without one.
        let model = try realMenu(assignments: [:])

        // Assert
        #expect(Set(model.courses.map(\.id)) == RealData.visibleIDsAtMidFall2025)
        #expect(model.courses.allSatisfy { $0.graph.count == Pinned.windowDays })
        #expect(model.courses.allSatisfy { filled($0.graph).isEmpty })
        // `firstIndex` rather than a subscript: a course whose graph is shorter
        // than expected must fail this assertion, not trap and take the whole
        // test process down with it.
        #expect(model.courses.allSatisfy {
            $0.graph.firstIndex(where: \.isToday) == Pinned.midFall2025TodayIndex
        })
    }
}
