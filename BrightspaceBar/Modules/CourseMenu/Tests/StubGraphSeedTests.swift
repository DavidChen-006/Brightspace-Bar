import Foundation
import Testing

import CourseMenu

// ═════════════════════════════════════════════════════════════════════════════
// THE STUB'S SEEDED STRIPS — the data the renderer is developed against.
//
// `StubMenuDataSource` is production code that hands the GUI a finished
// `MenuModel` with no backend at all (`BRIGHTSPACEBAR_STUB=1`). Stage 2 builds the
// renderer against it, which means the seeds are not decoration: they are the
// only inputs the renderer will be exercised with until the mapping layer lands.
//
// The window is POSITIONAL — 112 cells, index is the day offset from WINDOW
// START, and window start is the Sunday of today's week — and the stub carries
// FINISHED `GraphCell` values. Any "both kinds on one day" has already been
// resolved to the higher tier upstream; the stub demonstrates the OUTCOME, not
// the resolution.
//
// RE-PINNED for NewVertical-3 §4. Three things moved:
//   • 28 cells → 112 (16 weeks, the multiple of 7 §3.3 promises the grid).
//   • `isToday` is no longer index 0. The window opens on Sunday, so today sits
//     somewhere in cells 0–6. The seeds pick index 2 (a Tuesday), matching the
//     mapping suite's and the E2E suite's pinned instants.
//   • "A course with no strip at all" CEASED TO EXIST. Always-emit (§2 item 2)
//     makes `[]` unreachable from `GraphTranslation`, so no seed may demonstrate
//     it — a renderer developed against a `[]` seed would be developed against a
//     state the backend can no longer produce.
//
// PRIORITIES:
//
//   1. VISUAL COVERAGE. Every state the renderer can be in must be reachable by
//      launching the stub: a filled cell, an empty cell, a today cell that also
//      carries work, a today cell that does not, work on a day of the current
//      week that has ALREADY PASSED (new — the window now reaches behind today),
//      work on the window's last index, and an entirely empty window. A seed set
//      that drifts silently loses one of those states, and the renderer bug it
//      was hiding ships — the human verification step is only as good as the
//      seeds.
//
//   2. DETERMINISM. The seeds are literals, not clock-derived, so a screenshot
//      taken today and one taken next month show the same strip. These tests pin
//      exact indices for that reason; a seed built from `Date()` would make them
//      flap and would make visual review unrepeatable.
//
// CULLED: everything about the mapping (window range, local-day bucketing, the
// 11 PM boundary, highest-tier-wins as a computation) — that is stage 4, tested
// with an injected clock. Also culled: `CellTier`/`GraphCell` shape claims, which
// `GraphCellTests` already owns, and drawing/palette, which is the renderer's.
//
// SCOPE: all small. Pure values; the one `async` test only crosses the
// `MenuDataSource` protocol, which the stub answers from memory.
// ═════════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────
// PINNED POLICY — the builder seeds exactly this, in `StubMenuDataSource.seeded`.
//
// 112 cells per window, for EVERY seeded course without exception. `isToday`
// true at index 2 only, never elsewhere — index 2 because a Sunday-aligned
// window puts a Tuesday there, which is where the mapping suite's and the E2E
// suite's pinned instants land too.
//
//   Data Engineering (1_498_777) — a today cell that ALSO carries work, proving
//     the outline does not obscure the fill:
//       2: .assignment (and isToday)   3: .quiz   5: .assignment   7: .quiz
//
//   Multivariate Calculus (1_415_558) — a today cell that is EMPTY, proving the
//     outline renders on an empty cell, plus work on the window's last index so
//     the trailing edge of a 16-week grid is visible:
//       2: nil (and isToday)   4: .quiz   8: .assignment
//      11: .quiz  ← the seeded "assignment + quiz same day", already resolved
//     111: .assignment  ← last cell of the window
//
//   Transformative Texts (1_460_912) — the state the old window could not have:
//     work on days of the CURRENT week that have already passed, one on either
//     side of the window's opening Sunday:
//       0: .assignment   1: .quiz
//
//   Computer Graphics Technology (1_452_301) and Purdue Civics (412_690) — the
//     honest "nothing due" window: 112 cells, every tier nil, isToday at 2.
//     Two of them, because under always-emit this is the common case and a
//     stub with only one would under-represent how the menu usually looks.
//
// Seeds are literals. Nothing here derives from `Date()`.
// ─────────────────────────────────────────────────────────────────────────────

/// The window's width, stated once so the expectations below read as the spec.
private let windowLength = 112

/// Where the seeds put today. Deliberately NOT 0: a stub that stamped cell 0
/// would let a renderer that assumes "today is the first cell" look correct.
private let todayIndex = 2

/// A full 112-cell tier expectation written the way the window is actually read:
/// sparse, by index, everything else empty. Built from the policy block above
/// rather than from the stub, so it is an independent source of truth.
private func window(_ seeded: [Int: CellTier]) -> [CellTier?] {
    (0..<windowLength).map { seeded[$0] }
}

private func seededCourse(_ id: Int) throws -> CourseRow {
    try #require(
        StubMenuDataSource.seeded.courses.first { $0.id == id },
        "the stub no longer seeds course \(id)"
    )
}

/// Every course the stub seeds. Named once so the "all of them" claims below
/// cannot quietly stop covering a course someone adds.
private let seededIDs = [1_498_777, 1_415_558, 1_452_301, 1_460_912, 412_690]

@Suite("The stub seeds every state the renderer can draw")
struct StubGraphSeedTests {

    @Test("every seeded course carries a full 112-cell window")
    func everyCourseCarriesTheWholeWindow() throws {
        // Arrange / Act — the always-emit rule (§2 item 2) as it reaches the
        // renderer. This is the claim that makes course rows uniform in height:
        // if any seed were short or empty, one row would draw differently and the
        // stub would demo a menu the backend can no longer produce.
        for id in seededIDs {
            let course = try seededCourse(id)

            // Assert
            #expect(course.graph.count == windowLength, "course \(id) has \(course.graph.count) cells")
        }
    }

    @Test("Data Engineering's window fills today and three days after it")
    func dataEngineeringWindow() throws {
        // Arrange / Act
        let course = try seededCourse(1_498_777)

        // Assert — the full 112-cell tier sequence, so the count and the gaps are
        // pinned alongside the fills.
        #expect(course.graph.map(\.tier) == window([
            2: .assignment,
            3: .quiz,
            5: .assignment,
            7: .quiz,
        ]))
    }

    @Test("Multivariate Calculus's window reaches its last cell, 16 weeks out")
    func multivariateCalculusWindow() throws {
        // Arrange / Act
        let course = try seededCourse(1_415_558)

        // Assert — index 11 is the seeded "an assignment AND a quiz were due that
        // day", already resolved to `.quiz` upstream; the stub shows the outcome.
        // Index 111 is the window's final cell, seeded so the trailing edge of the
        // grid is visible rather than being cropped without anyone noticing —
        // which matters far more at 16 weeks than it did at four.
        #expect(course.graph.map(\.tier) == window([
            4: .quiz,
            8: .assignment,
            11: .quiz,
            111: .assignment,
        ]))
    }

    @Test("Transformative Texts carries work on days of this week already past")
    func workBehindTodayIsSeeded() throws {
        // Arrange / Act — the state the old today-anchored window could not hold
        // and no seed therefore covered. The window now opens on Sunday, so cells
        // 0 and 1 are days that have already gone by; the renderer must draw them
        // like any other filled cell, and only a seed makes that visible.
        let course = try seededCourse(1_460_912)

        // Assert
        #expect(course.graph.map(\.tier) == window([
            0: .assignment,
            1: .quiz,
        ]))
    }

    @Test("the courses with nothing due carry 112 empty days")
    func emptyWindowsAreStillFullLength() throws {
        // Arrange / Act — the honest "nothing due" state, and under always-emit
        // the only kind of empty there is: a full-width grid with no fills, never
        // an absent one.
        for id in [1_452_301, 412_690] {
            let course = try seededCourse(id)

            // Assert
            #expect(course.graph.map(\.tier) == window([:]), "course \(id) is not empty")
        }
    }

    @Test("today is stamped on exactly one cell of every course, and it is not cell 0")
    func todayIsStampedOnceAndNotAtIndexZero() throws {
        for id in seededIDs {
            // Arrange / Act
            let graph = try seededCourse(id).graph

            // Assert — a second stamp, or a stamp elsewhere, means the seed and
            // the week-aligned window disagree about where now sits. Index 2 and
            // not 0 is the point: a seed at cell 0 would let a renderer that
            // assumes today leads the window look perfectly correct.
            let stamped = graph.indices.filter { graph[$0].isToday }
            #expect(stamped == [todayIndex], "course \(id) stamps today at \(stamped)")
        }
    }

    @Test("Data Engineering's today cell also carries work")
    func todayCanCarryATier() throws {
        // Arrange / Act — the outline-over-fill case. Without a seed like this the
        // renderer could draw the today outline as a fill and nobody would see it.
        let today = try seededCourse(1_498_777).graph[todayIndex]

        // Assert
        #expect(today.isToday)
        #expect(today.tier == .assignment)
    }

    @Test("Multivariate Calculus's today cell is empty")
    func todayCanBeEmpty() throws {
        // Arrange / Act — the mirror: the outline has to render on a cell with no
        // fill behind it, which is the case a fill-based today indicator loses.
        let today = try seededCourse(1_415_558).graph[todayIndex]

        // Assert
        #expect(today.isToday)
        #expect(today.tier == nil)
    }

    @Test("both tiers appear somewhere in the seeds")
    func bothTiersAreVisible() {
        // Arrange / Act — a claim about the seed set as a whole, which no single
        // course's strip makes: whatever the renderer does to distinguish an
        // assignment from a quiz is visible in one launch of the stub.
        let seededTiers = Set(StubMenuDataSource.seeded.courses.flatMap { $0.graph.compactMap(\.tier) })

        // Assert
        #expect(seededTiers == Set(CellTier.allCases))
    }

    @Test("the strips arrive through the MenuDataSource protocol")
    func stripsReachTheGUIThroughTheProtocol() async {
        // Arrange
        let source = StubMenuDataSource()

        // Act — the path the app actually takes; the seeds are worthless if
        // `currentMenu()` answers with a different model than the static one.
        let courses = await source.currentMenu().courses

        // Assert — every course arrives with its window, not just the ones
        // carrying work.
        #expect(courses.map(\.graph) == StubMenuDataSource.seeded.courses.map(\.graph))
        #expect(courses.count == seededIDs.count)
        #expect(courses.allSatisfy { $0.graph.count == windowLength })
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// The stub seeds BOUNDARIES too (NewVertical-3.md §3.1).
//
// Same priority as the strips above — VISUAL COVERAGE. The stub is what the
// renderer is developed and demoed against, so a boundary rule that lives only in
// `MenuTranslation` would never appear under `BRIGHTSPACEBAR_STUB=1`, and the
// hairline's real look (inset, height, dynamic grey) would go unreviewed until it
// shipped. The stub therefore mirrors the translation layer's rule exactly.
//
// PINNED: a `.hairline` immediately BEFORE every `.course` row — after the section
// header for the first course, between consecutive courses for the rest. The
// footer `.separator` above the status row is UNCHANGED: this slice deliberately
// leaves the native separator where it is.
//
// CULLED: colour and geometry, which are the view's and are pinned as structure in
// `Modules/BrightspaceBar/Tests/HairlineRenderingTests.swift`.
// ═════════════════════════════════════════════════════════════════════════════

@Suite("The stub seeds the boundaries the renderer draws")
struct StubHairlineSeedTests {

    @Test("every seeded course is immediately preceded by a hairline")
    func everyCourseHasABoundaryAboveIt() {
        // Arrange / Act — walk the seeded rows and read what sits above each
        // course. Written as "the row before each course", not as an index list,
        // so re-seeding a course does not require rewriting the expectation.
        let rows = StubMenuDataSource.seeded.rows
        let coursesWithoutABoundaryAbove = rows.indices.filter { index in
            guard case .course = rows[index] else { return false }
            return index == 0 || rows[index - 1] != .hairline
        }

        // Assert
        #expect(coursesWithoutABoundaryAbove.isEmpty, "courses at \(coursesWithoutABoundaryAbove) have no boundary above them")
    }

    @Test("the stub seeds exactly one hairline per course and no more")
    func hairlineCountMatchesCourseCount() {
        // Arrange / Act — a stray hairline elsewhere (before the status row, say)
        // would demo a look the translation layer never produces.
        let rows = StubMenuDataSource.seeded.rows
        let hairlines = rows.count { $0 == .hairline }

        // Assert
        #expect(hairlines == StubMenuDataSource.seeded.courses.count)
    }

    @Test("the footer keeps its native separator")
    func footerSeparatorIsUntouched() throws {
        // Arrange — the deliberate scope limit of this slice: the boundary above
        // the status row stays a native `.separator`, and swapping it for a
        // hairline is NOT part of the change.
        let rows = StubMenuDataSource.seeded.rows

        // Act
        let separatorIndex = try #require(rows.firstIndex(of: .separator), "the footer separator is gone")

        // Assert
        guard case .status = rows[separatorIndex + 1] else {
            Issue.record("the row after the footer separator is not the status row")
            return
        }
    }

    @Test("no course submenu carries a hairline")
    func submenusHaveNoBoundaries() {
        // Arrange / Act — §3.1's rule is a TOP-LEVEL one. A submenu's rows are
        // assignments under one course, with no boundaries to draw between them.
        let seededSubmenuRows = StubMenuDataSource.seeded.courses.flatMap(\.submenu)

        // Assert
        #expect(!seededSubmenuRows.contains(.hairline))
    }
}
