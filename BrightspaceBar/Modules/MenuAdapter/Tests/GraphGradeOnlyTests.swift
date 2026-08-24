import Foundation
import Testing

import AssignmentPipeline
import CourseMenu
import CoursePipeline
import MenuAdapter

// ═════════════════════════════════════════════════════════════════════════════
// THE HEATMAP ABSTAINS — a gradebook column marks no day, ever.
//
// The activity graph answers one question: what is due, and when. A heads-up row
// exists precisely because nothing knows when — it is a gradebook column with no
// visible assignment behind it, and `dueDate` is null by contract in v1. There is
// no day it belongs on, so it gets no square.
//
// PRIORITY: THE EXCLUSION IS BY KIND, NOT BY THE ACCIDENT OF A NULL DATE. Today
// every gradeOnly item is undated, so `strip`'s existing `guard let dueDate`
// already drops all of them — which means a builder can add the third kind,
// change NOTHING here, and watch a naive suite go green. The moment the contract
// grows a date ladder (a Fall decision, deliberately deferred), that
// implementation starts drawing squares for deadlines the daemon inferred rather
// than read, and a filled cell is indistinguishable from a real one. The whole
// value of this file is the HOSTILE fixture: a gradeOnly item carrying a real,
// in-window due date, which must still mark nothing.
//
// CULLED: everything about WHERE a date lands — the window origin, DST, the
// local-day bucketing, the edges. `GraphTranslationTests` pins all of it and a
// third kind gives none of it a new way to break. This file asks one question
// only: does this kind reach a cell at all.
//
// SCOPE: all small. Pure translation over plain values, `now` and `timeZone`
// supplied. No `TimeZone.current`, no `Date()`.
// ═════════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────
// PINNED POLICY — the builder implements exactly this.
//
//   `GraphTranslation.strip` produces NO cell fill for an item whose kind is
//   `.gradeOnly`, whatever its `dueDate`. The exclusion is a kind test, stated
//   where the other exclusions are stated — alongside `isHidden` and `dueDate ==
//   nil` — and NOT expressed as a `CellTier`.
//
//   `CellTier` deliberately gains NO case. A third tier would mean a colour on
//   the grid, and the grid is a deadline calendar: a square drawn for something
//   with no deadline is a claim the data does not support. It would also outrank
//   or be outranked by real work on a shared day, which is a question with no
//   right answer.
//
//   The window is UNCHANGED in every other respect. An excluded item empties a
//   cell; it never shortens the strip, never moves `isToday`, and never
//   suppresses the real work sharing its day.
// ─────────────────────────────────────────────────────────────────────────────

private enum Pinned {
    /// Stated as a literal rather than read from the production constant, for the
    /// same reason `GraphTranslationTests` states it: the window must not be
    /// resized and re-blessed in one edit.
    static let windowDays = 112

    /// Indiana rather than UTC, matching the sibling suite: in UTC the local day
    /// and the instant's day always agree, so a bucketing bug would pass.
    static let zone = TimeZone(identifier: "America/Indianapolis")!

    /// `2026-02-10T15:00:00Z` — **10:00 on Tuesday Feb 10** in Indiana. The window
    /// therefore opens on Sunday Feb 8 and `now`'s own day is cell 2.
    static let now = Date(timeIntervalSince1970: 1_770_735_600)
    static let todayIndex = 2

    /// 15:00 local on **Tue Feb 10** = `2026-02-10T20:00:00Z`. Cell 2 — today, and
    /// squarely inside the window, which is what makes it hostile.
    static let todayAfternoon = Date(timeIntervalSince1970: 1_770_753_600)
    /// 15:00 local on **Wed Feb 11** = `2026-02-11T20:00:00Z`. Cell 3.
    static let tomorrowAfternoon = Date(timeIntervalSince1970: 1_770_840_000)
    /// 12:00 local on **Fri Feb 13** = `2026-02-13T17:00:00Z`. Cell 5.
    static let noonOnFebThirteenth = Date(timeIntervalSince1970: 1_771_002_000)
}

private enum Real {
    static let scholarlyID = 440_703
    static let citiID = 445_296
    static let moduleOneQuizID = 476_481
    static let participationID = 812_004
    static let midtermColumnID = 812_311
}

private func work(
    _ id: Int,
    _ kind: ItemKind,
    due dueDate: Date?,
    isHidden: Bool = false
) -> Assignment {
    Assignment(
        id: id, courseId: Real.scholarlyID, name: "Item \(id)", dueDate: dueDate,
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

@Suite("Graph — gradebook columns mark nothing")
struct GraphGradeOnlyTests {

    @Test("a gradebook column with a real in-window due date still marks nothing")
    func aDatedGradeOnlyItemMarksNothing() {
        // Arrange — THE hostile fixture, and the reason this file exists. This
        // item should not exist under the v1 contract (`dueDate` is always null),
        // which is exactly the point: it is the only input that tells a kind test
        // apart from `guard let dueDate`. Due today, in the middle of the window,
        // where a drawn square would be maximally believable.
        let items = [work(Real.participationID, .gradeOnly, due: Pinned.todayAfternoon)]

        // Act
        let cells = strip(items)

        // Assert — nothing drawn, and the window keeps its full length: an
        // exclusion empties a cell, it never shortens the strip.
        #expect(filled(cells).isEmpty)
        #expect(cells.count == Pinned.windowDays)
        #expect(cells.firstIndex(where: \.isToday) == Pinned.todayIndex)
    }

    @Test("several dated gradebook columns across the window mark nothing between them")
    func datedGradeOnlyItemsMarkNothingAnywhere() {
        // Arrange — three different days, so an implementation that excluded only
        // the today cell, or only the first item, leaves evidence.
        let items = [
            work(Real.participationID, .gradeOnly, due: Pinned.todayAfternoon),
            work(Real.midtermColumnID, .gradeOnly, due: Pinned.tomorrowAfternoon),
            work(813_902, .gradeOnly, due: Pinned.noonOnFebThirteenth),
        ]

        // Act
        let cells = strip(items)

        // Assert
        #expect(filled(cells).isEmpty)
        #expect(cells.count == Pinned.windowDays)
    }

    @Test("an undated gradebook column changes nothing, as every undated item does")
    func anUndatedGradeOnlyItemIsAlsoExcluded() {
        // Arrange — the shape the contract actually produces. It passes today for
        // the wrong reason, and it is here only so the pair reads honestly: this
        // is the case, the test above is the proof.
        let items = [work(Real.participationID, .gradeOnly, due: nil)]

        // Act
        let cells = strip(items)

        // Assert
        #expect(filled(cells).isEmpty)
        #expect(cells.count == Pinned.windowDays)
    }

    @Test("a gradebook column does not suppress the real work sharing its day")
    func realWorkOnTheSameDaySurvives() {
        // Arrange — the opposite failure, and the one a "skip this whole day"
        // implementation produces: an assignment genuinely due today, with a
        // gradebook column that landed on the same date. The column abstains; the
        // assignment must not.
        let items = [
            work(Real.participationID, .gradeOnly, due: Pinned.todayAfternoon),
            work(Real.citiID, .assignment, due: Pinned.todayAfternoon),
        ]

        // Act
        let cells = strip(items)

        // Assert — today's cell is the assignment's, and it is the only fill.
        #expect(filled(cells) == [Pinned.todayIndex: .assignment])
    }

    @Test("a gradebook column does not outrank or downgrade the tier of a shared day")
    func theSharedDayKeepsTheHighestRealTier() {
        // Arrange — a quiz is the highest tier, so a gradeOnly item folded into
        // the `max()` with any tier at all would either win (drawing the wrong
        // colour) or lose invisibly. Listed first so a last-one-wins fold is
        // caught too.
        let items = [
            work(Real.participationID, .gradeOnly, due: Pinned.noonOnFebThirteenth),
            work(Real.moduleOneQuizID, .quiz, due: Pinned.noonOnFebThirteenth),
            work(Real.citiID, .assignment, due: Pinned.noonOnFebThirteenth),
        ]

        // Act
        let cells = strip(items)

        // Assert — Fri Feb 13 is cell 5, and it is the quiz's.
        #expect(filled(cells) == [5: .quiz])
    }

    @Test("a whole course of gradebook columns still gets its full empty window")
    func aGradeOnlyCourseStillGetsAWindow() {
        // Arrange — the Civics probe shape taken to its limit: every column is
        // unmatched, so the submenu is all heads-up rows and the graph has nothing
        // to say. Collapsing to `[]` here would make the course look unfetched
        // (§2 item 2), and the row would lose its grid while its neighbours keep
        // theirs.
        let items = [
            work(Real.participationID, .gradeOnly, due: nil),
            work(Real.midtermColumnID, .gradeOnly, due: Pinned.tomorrowAfternoon),
        ]

        // Act
        let cells = strip(items)

        // Assert
        #expect(cells.count == Pinned.windowDays)
        #expect(filled(cells).isEmpty)
        #expect(cells.indices.filter { cells[$0].isToday } == [Pinned.todayIndex])
    }

    @Test("a failed refresh holding gradebook columns draws only the real work it held")
    func failedStateAlsoAbstains() {
        // Arrange — the preserved-stale path reads `lastKnown` rather than the
        // loaded list, so it is a second entry into the same fold and a second
        // place the kind test can be missed.
        let held = [
            work(Real.participationID, .gradeOnly, due: Pinned.todayAfternoon),
            work(Real.moduleOneQuizID, .quiz, due: Pinned.tomorrowAfternoon),
        ]

        // Act
        let cells = GraphTranslation.strip(
            state: .failed(lastKnown: held, error: .transport("offline")),
            now: Pinned.now,
            timeZone: Pinned.zone
        )

        // Assert — the quiz's day only.
        #expect(filled(cells) == [Pinned.todayIndex + 1: .quiz])
    }

    @Test("the grid's vocabulary gains no tier for this kind")
    func cellTierGainsNoCase() {
        // Arrange / Act — the decision this pins is unchanged: a gradebook
        // column has no deadline, so no tier may exist FOR IT. The vocabulary
        // did grow — `.test` arrived with Intent 1's manual items — but that
        // case belongs to work with a real deadline, never to this kind, which
        // `tier(of: .gradeOnly) == nil` (asserted throughout this suite via
        // empty cells) keeps true. What remains assertable here is that the
        // ranked cases are exactly the deadline-bearing kinds.
        let tiers = CellTier.allCases

        // Assert
        #expect(tiers == [.assignment, .quiz, .test])
    }
}
