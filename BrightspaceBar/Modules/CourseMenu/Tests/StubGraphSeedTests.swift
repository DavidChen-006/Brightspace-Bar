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
// The strip is POSITIONAL — 28 cells, index is the day offset, cell 0 is today —
// and the stub carries FINISHED `GraphCell` values. Any "both kinds on one day"
// has already been resolved to the higher tier upstream; the stub demonstrates the
// OUTCOME, not the resolution.
//
// PRIORITIES:
//
//   1. VISUAL COVERAGE. Every state the renderer can be in must be reachable by
//      launching the stub: a filled cell, an empty cell, a today cell that also
//      carries work, a today cell that does not, work on the window's last index,
//      an entirely empty strip, and a course with no strip at all. A seed set that
//      drifts silently loses one of those states, and the renderer bug it was
//      hiding ships — the human verification step is only as good as the seeds.
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
// 28 cells per strip. `isToday` true at index 0 only, never elsewhere.
//
//   Data Engineering (1_498_777) — a today cell that ALSO carries work, proving
//     the outline does not obscure the fill:
//       0: .assignment (and isToday)   1: .quiz   3: .assignment   5: .quiz
//
//   Multivariate Calculus (1_415_558) — a today cell that is EMPTY, proving the
//     outline renders on an empty cell, plus work on the window's last index so
//     the trailing edge is visible:
//       0: nil (and isToday)   2: .quiz   6: .assignment
//       9: .quiz  ← the seeded "assignment + quiz same day", already resolved
//      27: .assignment  ← last cell of the window
//
//   Computer Graphics Technology (1_452_301) — the honest "nothing due" strip:
//       28 cells, every tier nil, isToday at index 0.
//
//   Transformative Texts (1_460_912) and Purdue Civics (412_690) — `graph == []`.
//     No strip at all; the renderer must skip these rows entirely rather than
//     drawing 28 empty cells.
//
// Seeds are literals. Nothing here derives from `Date()`.
// ─────────────────────────────────────────────────────────────────────────────

/// The window's width, stated once so the expectations below read as the spec.
private let stripLength = 28

/// A full 28-cell tier expectation written the way the policy states it: sparse,
/// by index, everything else empty. Built from the policy block above rather than
/// from the stub, so it is an independent source of truth.
private func strip(_ seeded: [Int: CellTier]) -> [CellTier?] {
    (0..<stripLength).map { seeded[$0] }
}

private func seededCourse(_ id: Int) throws -> CourseRow {
    try #require(
        StubMenuDataSource.seeded.courses.first { $0.id == id },
        "the stub no longer seeds course \(id)"
    )
}

@Suite("The stub seeds every state the renderer can draw")
struct StubGraphSeedTests {

    @Test("Data Engineering's strip fills today, tomorrow, +3 and +5")
    func dataEngineeringStrip() throws {
        // Arrange / Act
        let course = try seededCourse(1_498_777)

        // Assert — the full 28-cell tier sequence, so the count and the gaps are
        // pinned alongside the fills.
        #expect(course.graph.map(\.tier) == strip([
            0: .assignment,
            1: .quiz,
            3: .assignment,
            5: .quiz,
        ]))
    }

    @Test("Multivariate Calculus's strip reaches the window's last cell")
    func multivariateCalculusStrip() throws {
        // Arrange / Act
        let course = try seededCourse(1_415_558)

        // Assert — index 9 is the seeded "an assignment AND a quiz were due that
        // day", already resolved to `.quiz` upstream; the stub shows the outcome.
        // Index 27 is the window's final cell, seeded so the trailing edge of the
        // strip is visible rather than being cropped without anyone noticing.
        #expect(course.graph.map(\.tier) == strip([
            2: .quiz,
            6: .assignment,
            9: .quiz,
            27: .assignment,
        ]))
    }

    @Test("Computer Graphics Technology's strip is 28 empty days")
    func computerGraphicsStrip() throws {
        // Arrange / Act — the honest "nothing due" state. Distinct from having no
        // strip: the row still draws a full-width strip, just with no fills.
        let course = try seededCourse(1_452_301)

        // Assert
        #expect(course.graph.map(\.tier) == strip([:]))
    }

    @Test("today is stamped on exactly one cell, and it is index 0")
    func todayIsStampedOnceAtIndexZero() throws {
        for id in [1_498_777, 1_415_558, 1_452_301] {
            // Arrange / Act
            let graph = try seededCourse(id).graph

            // Assert — cell 0 is today by definition of the positional strip. A
            // second stamp, or a stamp further along, means the seed and the
            // contract disagree about which end of the strip is now.
            let stamped = graph.indices.filter { graph[$0].isToday }
            #expect(stamped == [0], "course \(id) stamps today at \(stamped)")
        }
    }

    @Test("Data Engineering's today cell also carries work")
    func todayCanCarryATier() throws {
        // Arrange / Act — the outline-over-fill case. Without a seed like this the
        // renderer could draw the today outline as a fill and nobody would see it.
        let today = try #require(seededCourse(1_498_777).graph.first)

        // Assert
        #expect(today.isToday)
        #expect(today.tier == .assignment)
    }

    @Test("Multivariate Calculus's today cell is empty")
    func todayCanBeEmpty() throws {
        // Arrange / Act — the mirror: the outline has to render on a cell with no
        // fill behind it, which is the case a fill-based today indicator loses.
        let today = try #require(seededCourse(1_415_558).graph.first)

        // Assert
        #expect(today.isToday)
        #expect(today.tier == nil)
    }

    @Test("the two courses with no upcoming work carry no strip at all")
    func someCoursesHaveNoStrip() throws {
        // Arrange / Act — empty means "draw nothing", not "draw 28 empty cells".
        // Computer Graphics covers the latter; these two cover the former.
        let transformativeTexts = try seededCourse(1_460_912)
        let civics = try seededCourse(412_690)

        // Assert
        #expect(transformativeTexts.graph == [])
        #expect(civics.graph == [])
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

        // Assert
        #expect(courses.map(\.graph) == StubMenuDataSource.seeded.courses.map(\.graph))
        #expect(courses.filter { !$0.graph.isEmpty }.count == 3)
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
