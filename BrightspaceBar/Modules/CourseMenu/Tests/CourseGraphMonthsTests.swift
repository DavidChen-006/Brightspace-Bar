import Foundation
import Testing

import CourseMenu

// ═════════════════════════════════════════════════════════════════════════════
// `CourseRow.graphMonths` — the grid's column headings, in the contract.
//
// The contract stays 1-D and positional (§3.3): the backend never says "16
// columns". It says "N cells, N a multiple of 7", and the renderer decides that
// this means columns. `graphMonths` is the ONE place a column is named on the
// backend side, and it is here rather than in the renderer for a reason worth
// stating: which column holds the 1st of April is a calendar fact about real
// days, and the renderer has no dates. Weekday labels are the opposite — row 0
// is Sunday for every window the backend can emit — so they stay a renderer
// literal and never enter this file.
//
// PRIORITIES:
//
//   1. THE FIELD CANNOT BREAK WHAT ALREADY COMPILES. `CourseRow` is the frozen
//      contract; its initialiser is called from the stub, the translation layer
//      and four test targets. Last and defaulted, exactly as `graph` was, or the
//      slice turns into a mechanical edit of every call site — and a mechanical
//      edit of every call site is where a wrong value gets pasted in.
//
//   2. HEADINGS PARTICIPATE IN CHANGE DETECTION. The app rebuilds the menu only
//      when the model differs (`MenuModel: Equatable`). A window that rolls into
//      a new month while the cells happen to be unchanged — an empty grid, which
//      under always-emit is the common case — must still redraw, or the grid
//      keeps last month's headings over this month's columns.
//
// CULLED: which columns get named and what the names are — that is calendar
// arithmetic, pinned in `MenuAdapter/Tests/GraphMonthLabelTests.swift` with an
// injected clock; and everything about drawing them.
//
// SCOPE: all small. Plain values.
// ═════════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────
// PINNED POLICY — the builder implements exactly this.
//
//     public struct CourseRow: Equatable, Sendable, Identifiable {
//         …
//         public let graph: [GraphCell]
//         /// One entry per week column of `graph`; nil where no month begins.
//         public let graphMonths: [String?]
//
//         public init(
//             id: Int, title: String, subtitle: String? = nil, url: URL,
//             submenu: [MenuRow] = [], graph: [GraphCell] = [],
//             graphMonths: [String?] = []
//         )
//     }
//
// LAST and DEFAULTED to `[]`, for the same reason `graph` is: every existing
// call site compiles untouched. `[]` means "no headings", which is what an
// ungraphed hand-written row has and what the GUI's own fixtures keep.
// ─────────────────────────────────────────────────────────────────────────────

private func url(_ id: Int) -> URL {
    URL(string: "https://purdue.brightspace.com/d2l/home/\(id)")!
}

/// A three-column heading set. Short on purpose: this file makes no claim about
/// how many columns there are, only about the field carrying what it is given.
private let headings: [String?] = ["Feb", nil, "Mar"]

@Suite("CourseRow carries its graph's month headings")
struct CourseGraphMonthsTests {

    /// The compile-compatibility claim, made as a value claim so it survives:
    /// a row built the way every pre-slice call site builds one still works, and
    /// its headings are empty rather than absent.
    @Test("a row built without headings has none")
    func headingsDefaultToEmpty() {
        // Arrange / Act — the pre-slice initialiser call, verbatim.
        let row = CourseRow(id: 1, title: "Data Engineering", url: url(1))

        // Assert
        #expect(row.graphMonths == [])
    }

    /// The same for a row that has a graph but was built before headings
    /// existed — the field is independent of `graph`, so an old call site with
    /// cells does not accidentally acquire headings.
    @Test("a row built with cells but no headings still has none")
    func graphDoesNotImplyHeadings() {
        // Arrange / Act
        let row = CourseRow(id: 1, title: "Data Engineering", url: url(1), graph: [GraphCell(tier: .quiz)])

        // Assert
        #expect(row.graph.count == 1)
        #expect(row.graphMonths == [])
    }

    /// What is put in comes out, nils included. A field that dropped its nils
    /// would renumber every heading's column.
    @Test("headings are carried through unchanged, empty entries included")
    func headingsRoundTrip() {
        // Arrange / Act
        let row = CourseRow(id: 1, title: "Data Engineering", url: url(1), graphMonths: headings)

        // Assert
        #expect(row.graphMonths == headings)
    }

    /// Priority 2. Two rows identical but for their headings must not compare
    /// equal, or the menu keeps the old headings when the month rolls over.
    @Test("rows whose headings differ are not equal")
    func headingsParticipateInEquality() {
        // Arrange
        let february = CourseRow(id: 1, title: "Data Engineering", url: url(1), graphMonths: headings)

        // Act
        let march = CourseRow(id: 1, title: "Data Engineering", url: url(1), graphMonths: ["Mar", nil, "Apr"])

        // Assert
        #expect(february != march)
    }

    /// The case that makes the previous one load-bearing rather than pedantic:
    /// an empty grid rolling into a new month. The cells are byte-identical —
    /// every one of them empty — so headings are the ONLY thing that changed, and
    /// if they do not count, the menu does not redraw.
    @Test("a new month over an unchanged empty grid is still a change")
    func aMonthRollOverOverAnEmptyGridIsAChange() {
        // Arrange — the same 14 empty days both times.
        let emptyFortnight = Array(repeating: GraphCell(tier: nil), count: 14)
        let before = CourseRow(
            id: 1, title: "Data Engineering", url: url(1),
            graph: emptyFortnight, graphMonths: ["Feb", nil]
        )

        // Act
        let after = CourseRow(
            id: 1, title: "Data Engineering", url: url(1),
            graph: emptyFortnight, graphMonths: ["Mar", nil]
        )

        // Assert
        #expect(before.graph == after.graph)
        #expect(before != after)
        #expect(MenuModel(rows: [.course(before)]) != MenuModel(rows: [.course(after)]))
    }

    /// And the converse, so the field is not merely making everything unequal:
    /// two rows with the same headings still compare equal, which is what keeps
    /// the menu from rebuilding on every poll.
    @Test("rows with the same headings remain equal")
    func identicalHeadingsCompareEqual() {
        // Arrange / Act
        let first = CourseRow(id: 1, title: "Data Engineering", url: url(1), graphMonths: headings)
        let second = CourseRow(id: 1, title: "Data Engineering", url: url(1), graphMonths: headings)

        // Assert
        #expect(first == second)
    }
}
