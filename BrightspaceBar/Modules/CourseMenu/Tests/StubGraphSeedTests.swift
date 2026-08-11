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
