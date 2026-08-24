import Foundation
import Testing

import CourseMenu

// ═════════════════════════════════════════════════════════════════════════════
// THE GRAPH CONTRACT — a course's upcoming work as plain values.
//
// Every course row gains a strip of cells describing the days ahead. The strip is
// POSITIONAL: index is the day offset from the window start, cell 0 is today, and
// the contract carries NO dates. That omission is deliberate — bucketing instants
// into local calendar days is the mapping layer's job, and keeping it out of here
// is what lets the GUI be built against hand-written strips.
//
// PRIORITIES:
//
//   1. THE RANKING IS THE FEATURE. `CellTier` is a ranked enum, not an intensity
//      scale, because "a day with both an assignment and a quiz renders as the more
//      important kind" is expressed downstream as one expression:
//
//          itemsDueThatDay.map(\.tier).max()
//
//      That expression is only correct if `<` follows the rank and the raw values
//      leave room above — a future `case test = 3` must slot in with no other
//      change. So the order and the raw values are both pinned here, at the
//      contract, rather than being an accident of declaration order.
//
//   2. EQUATABLE FIDELITY. `MenuModel`'s `Equatable` is what lets the app skip
//      rebuilding an unchanged menu. A `GraphCell` that ignored a field — or a
//      `CourseRow` that ignored its strip — would make a changed graph compare
//      equal to the old one, and the menu would silently keep drawing yesterday.
//      These tests are unsatisfiable by any conformance that drops a field.
//
// CULLED: everything about DATES (window range, local-day bucketing, the 11 PM
// boundary) — that is the mapping layer's, tested with an injected clock. Also
// culled: cell count, drawing, palette, and the today outline's appearance. This
// suite only pins the shape the two sides agree on.
//
// SCOPE: all small. Pure values, no I/O, no clock.
// ═════════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────
// PINNED POLICY — the builder implements exactly these, in module `CourseMenu`.
//
// ── CellTier — ranked, with headroom ────────────────────────────────────────
//     public enum CellTier: Int, Comparable, Equatable, Sendable, CaseIterable {
//         case assignment = 1
//         case quiz = 2
//         // future: case test = 3
//         public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
//     }
//
// ── GraphCell — fill and outline are ORTHOGONAL ─────────────────────────────
//     public struct GraphCell: Equatable, Sendable {
//         public let tier: CellTier?    // nil = empty day
//         public let isToday: Bool
//         public init(tier: CellTier?, isToday: Bool = false)
//     }
//   `isToday` is a separate field and never a fill value. The renderer draws the
//   fill from `tier` and the outline from `isToday` independently, so the
//   invariant "the today indicator must not obscure the underlying activity
//   state" holds by construction rather than by careful drawing.
//
// ── CourseRow gains the strip, LAST and DEFAULTED ───────────────────────────
//     public let graph: [GraphCell]
//     init(id:title:subtitle:url:submenu:graph: = [])
//   Last and defaulted for the same reason `Assignment.kind` was: every existing
//   call site — tests, stubs, the translation layer — compiles untouched, and a
//   course with no graph yet is the same plain row it is today.
//
// Values only: no AppKit, no Foundation types beyond what `MenuModel.swift`
// already uses. Everything `Equatable` and `Sendable`.
// ─────────────────────────────────────────────────────────────────────────────

@Suite("CellTier — the ranking that decides a shared day")
struct CellTierTests {

    @Test("a quiz outranks an assignment")
    func quizOutranksAssignment() {
        // Arrange / Act / Assert — the whole point of the enum being `Comparable`.
        #expect(CellTier.assignment < CellTier.quiz)
    }

    @Test("the highest tier wins on a day with both kinds, whatever order they arrive in")
    func highestTierWins() {
        // Arrange — the two orders a day's items could be folded in. The mapping
        // layer's fill rule is `map(\.tier).max()`, so an ordering-dependent answer
        // would make the same day render differently between refreshes.
        let assignmentFirst: [CellTier] = [.assignment, .quiz]
        let quizFirst: [CellTier] = [.quiz, .assignment]

        // Assert
        #expect(assignmentFirst.max() == .quiz)
        #expect(quizFirst.max() == .quiz)
    }

    @Test("the raw values are 1, 2 and 3, with test the highest tier")
    func rawValuesArePinned() {
        // Arrange / Act / Assert — the extensibility contract, exercised: the
        // reserved `case test = 3` arrived with Intent 1 (manual items), and
        // slotted in above `quiz` exactly as the pinning promised. These ranks
        // are what `max()`-based aggregation reads, so they stay pinned.
        #expect(CellTier.assignment.rawValue == 1)
        #expect(CellTier.quiz.rawValue == 2)
        #expect(CellTier.test.rawValue == 3)
        #expect(CellTier.allCases.max() == .test)
    }
}

@Suite("GraphCell — fill and outline, independently")
struct GraphCellTests {

    @Test("a day with nothing due is a cell with no tier")
    func anEmptyDayHasNoTier() {
        // Arrange / Act — `nil` is the empty day, not a zero-th tier. The strip is
        // positional, so empty days must still occupy their index.
        let empty = GraphCell(tier: nil)

        // Assert
        #expect(empty.tier == nil)
    }

    @Test("a cell is not today unless it says so")
    func isTodayDefaultsToFalse() {
        // Arrange / Act — exactly one cell in a strip is stamped, so the default
        // carries 27 of the 28 and is worth pinning on its own.
        let cell = GraphCell(tier: .quiz)

        // Assert
        #expect(cell.isToday == false)
    }

    @Test("two cells on the same day with different work are not equal")
    func equalityIsSensitiveToTier() {
        // Arrange — an assignment day that becomes a quiz day. If `tier` were left
        // out of equality the menu would keep drawing the old fill.
        let assignmentDay = GraphCell(tier: .assignment)
        let quizDay = GraphCell(tier: .quiz)

        // Assert
        #expect(assignmentDay != quizDay)
    }

    @Test("the same work on today and on another day are not equal")
    func equalityIsSensitiveToIsToday() {
        // Arrange — the mirror. Midnight moves the stamp one cell along while the
        // work stays put; that is a real change the GUI has to redraw.
        let today = GraphCell(tier: .quiz, isToday: true)
        let anotherDay = GraphCell(tier: .quiz, isToday: false)

        // Assert
        #expect(today != anotherDay)
    }
}

@Suite("CourseRow carries the strip")
struct CourseRowGraphTests {

    @Test("a course built without naming a graph has an empty one")
    func graphDefaultsToEmpty() {
        // Arrange / Act — the defaulted parameter is what keeps every existing call
        // site compiling untouched, so it gets a test of its own.
        let built = CourseRow(
            id: 440_703,
            title: "Scholarly Project Milestones",
            subtitle: "HONR 39900",
            url: URL(string: "https://purdue.brightspace.com/d2l/home/440703")!
        )

        // Assert
        #expect(built.graph == [])
    }

    @Test("two courses whose strips differ by one cell are not equal")
    func graphParticipatesInEquality() {
        // Arrange — the skip-rebuild guard at the row level: an assignment on day 3
        // that turns out to be a quiz. Same id, same title, same submenu.
        func row(day3: CellTier) -> CourseRow {
            CourseRow(
                id: 412_690,
                title: "Civics",
                subtitle: "POL 10100",
                url: URL(string: "https://purdue.brightspace.com/d2l/home/412690")!,
                submenu: [],
                graph: [
                    GraphCell(tier: nil, isToday: true),
                    GraphCell(tier: nil),
                    GraphCell(tier: nil),
                    GraphCell(tier: day3),
                ]
            )
        }

        // Assert
        #expect(row(day3: .assignment) != row(day3: .quiz))
    }
}
