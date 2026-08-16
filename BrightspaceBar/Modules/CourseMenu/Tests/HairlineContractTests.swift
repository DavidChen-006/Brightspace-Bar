import Foundation
import Testing

import CourseMenu

// ═════════════════════════════════════════════════════════════════════════════
// `MenuRow.hairline` — the boundary as CONTRACT vocabulary (NewVertical-3.md §3.1).
//
// The decision this file pins is structural, not cosmetic. §3.1 rejects drawing
// the boundary inside each component's own bounds and chooses a standalone inert
// row, and the decisive reason is that a menu MIXING native rows with custom ones
// cannot draw an in-component line at all. The consequence stated there is exactly
// this case: the hairline "becomes contract vocabulary — a `MenuRow` case placed
// by the pure translation layer — not something a component view decides".
//
// PRIORITY: contract integrity. `MenuRow` is the whole API surface between backend
// and GUI, and `Equatable` on it is load-bearing — the app skips rebuilding the
// menu when the model compares equal, so a case that does not participate properly
// in equality would make boundaries appear or vanish without a redraw.
//
// CULLED: everything visual. Colour, thickness, inset and row height are the view
// layer's, and are pinned as STRUCTURE (class, frame) — never as pixel colours —
// in `Modules/BrightspaceBar/Tests/HairlineRenderingTests.swift`. A test that
// sampled `NSColor` components would be asserting a design choice §3.1 explicitly
// leaves to a dynamic provider, and would fail on an appearance change that is
// correct.
//
// SCOPE: small. Pure values, no I/O.
// ═════════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────
// PINNED CONTRACT — the builder implements exactly this.
//
//     public enum MenuRow: Equatable, Sendable {
//         ...
//         case hairline
//     }
//
// A boundary line. Carries NO payload — a hairline knows nothing about what it
// separates, which is what lets the translation layer place it by rule rather than
// by asking a row about its neighbours. Not selectable.
//
// It is a case ALONGSIDE `.separator`, not a replacement for it: the footer
// boundary above the status row stays a native `.separator` for now (a deliberate
// scope limit for this slice).
// ─────────────────────────────────────────────────────────────────────────────

@Suite("MenuRow.hairline — the boundary in the contract")
struct HairlineContractTests {

    @Test("a hairline row equals another hairline row")
    func hairlineIsEqualToItself() {
        // Arrange / Act / Assert — payload-free, so every hairline is the same
        // value. Without this the GUI's Equatable skip-rebuild could not compare
        // two structurally identical menus as equal.
        #expect(MenuRow.hairline == MenuRow.hairline)
    }

    @Test("a hairline is not a separator")
    func hairlineIsDistinctFromSeparator() {
        // Arrange / Act / Assert — the two coexist. A `.hairline` that compared
        // equal to `.separator` would let the footer's native separator and a
        // course boundary be swapped for each other silently.
        #expect(MenuRow.hairline != MenuRow.separator)
    }

    @Test("a model's equality tracks whether a hairline is present")
    func addingAHairlineMakesModelsUnequal() {
        // Arrange — the same course list, with and without a boundary before it.
        let course = CourseRow(
            id: 1, title: "Data Engineering", subtitle: "CS 17600",
            url: URL(string: "https://purdue.brightspace.com/d2l/home/1")!
        )
        let without = MenuModel(rows: [.sectionHeader("202610"), .course(course)])
        let with = MenuModel(rows: [.sectionHeader("202610"), .hairline, .course(course)])

        // Act / Assert — the GUI rebuilds only when the model changes, so a menu
        // that gained boundaries must compare unequal to the one that had none.
        #expect(with != without)
    }

    @Test("hairlines do not disturb the course accessor")
    func coursesAccessorIgnoresHairlines() {
        // Arrange — boundaries interleaved exactly as the translation layer will
        // place them.
        let a = CourseRow(id: 1, title: "A", subtitle: nil, url: URL(string: "https://e.example/1")!)
        let b = CourseRow(id: 2, title: "B", subtitle: nil, url: URL(string: "https://e.example/2")!)
        let model = MenuModel(rows: [
            .sectionHeader("202610"),
            .hairline, .course(a),
            .hairline, .course(b),
            .separator, .status(.updated(nil)),
        ])

        // Act
        let extracted = model.courses

        // Assert — every existing test and call site reads courses through this
        // accessor, so the whole suite survives the new case only if it stays
        // blind to it.
        #expect(extracted == [a, b])
    }
}
