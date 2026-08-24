import Foundation
import Testing

import CourseMenu

// ─────────────────────────────────────────────────────────────────────────────
// The contract's own claims.
//
// These are GREEN ON ARRIVAL — `MenuModel` already exists and is frozen. They are
// here because MenuModel.swift's comments make load-bearing promises ("deliberately
// not empty", "Equatable is load-bearing"), and an untested promise is just a
// comment. They defend the contract against a future edit that quietly breaks the
// GUI's assumptions.
//
// PRIORITY: contract integrity. SCOPE: small — pure values, no I/O.
// ─────────────────────────────────────────────────────────────────────────────

@Suite("MenuModel — contract claims")
struct MenuModelTests {

    /// The comment says "Deliberately not `MenuModel(rows: [])`" because a zero-row
    /// dropdown reads as a crashed app. Pin it.
    @Test("the placeholder is never empty and offers a way out")
    func placeholderIsNeverEmpty() throws {
        #expect(!MenuModel.placeholder.rows.isEmpty)

        let hasCommand = MenuModel.placeholder.rows.contains { row in
            if case .command = row { true } else { false }
        }
        #expect(hasCommand, "the empty state gives the user nothing to act on")
    }

    @Test("the placeholder explains itself rather than showing a blank list")
    func placeholderCarriesAMessage() throws {
        let hasMessage = MenuModel.placeholder.rows.contains { row in
            if case .message = row { true } else { false }
        }
        #expect(hasMessage)
    }

    @Test("courses extracts only course rows, preserving order")
    func coursesExtractsInOrder() throws {
        // Arrange
        let a = CourseRow(id: 1, title: "A", subtitle: nil, url: URL(string: "https://e.example/1")!)
        let b = CourseRow(id: 2, title: "B", subtitle: "B 1", url: URL(string: "https://e.example/2")!)
        let model = MenuModel(rows: [
            .sectionHeader("Term"),
            .course(a),
            .status(.updated(Date(timeIntervalSince1970: 1_786_230_000))),
            .course(b),
            .separator,
            .command(.quit),
        ])

        // Act
        let extracted = model.courses

        // Assert
        #expect(extracted == [a, b])
    }

    @Test("courses is empty when there are no course rows")
    func coursesIsEmptyWithoutCourseRows() throws {
        let model = MenuModel(rows: [.message("No courses yet"), .command(.refresh)])
        #expect(model.courses.isEmpty)
    }

    /// `Equatable` is what lets the app skip rebuilding an unchanged menu, so an
    /// accidental identity-based conformance would cause needless rebuilds.
    @Test("two models with equal rows are equal")
    func equatableComparesByValue() throws {
        let url = URL(string: "https://e.example/1")!
        let rows: [MenuRow] = [
            .sectionHeader("Term"),
            .course(CourseRow(id: 1, title: "A", subtitle: "A 1", url: url)),
            .separator,
        ]
        #expect(MenuModel(rows: rows) == MenuModel(rows: rows))
    }

    @Test("a differing subtitle makes models unequal")
    func equatableDetectsSubtitleChange() throws {
        let url = URL(string: "https://e.example/1")!
        let withSubtitle = MenuModel(rows: [.course(CourseRow(id: 1, title: "A", subtitle: "A 1", url: url))])
        let without = MenuModel(rows: [.course(CourseRow(id: 1, title: "A", subtitle: nil, url: url))])
        #expect(withSubtitle != without)
    }
}
