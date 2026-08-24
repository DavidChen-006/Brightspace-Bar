import Foundation
import Testing

import AssignmentPipeline
import CourseMenu
import CoursePipeline
import ManualItems
import MenuAdapter

// ═════════════════════════════════════════════════════════════════════════════
// MANUAL ITEMS REACH THE MENU (Intent 1) — the pure merge, pinned.
//
// The student types an item into an add-form; the store persists it; and from
// there it must ride the SAME graph pipeline fetched items ride — the tier
// fold that fills a square, and the day detail that lists it with a working
// link in the Intent-2 popup. This suite pins that merge as the pure function
// it is: `ManualItem`s in, `GraphCell`s and `MenuModel`s out.
//
// PRIORITIES (the 1–2 carrying 80% of the value):
//
//   1. AN ADDED ITEM IS VISIBLE, ON THE RIGHT DAY, WITH A WORKING LINK. The
//      whole feature is "David adds the test the professor only announced
//      aloud, and the app treats it as real work". A manual item that colours
//      no square, colours the wrong day's square, or lists with a dead link is
//      the feature not existing — silently.
//
//   2. THE THREE KINDS MAP TO THE THREE TIERS, AND `test` OUTRANKS. `.test` is
//      the tier the contract reserved; a manual test sharing a day with a
//      fetched quiz must win the cell, or the most important thing that day is
//      the one the student cannot see.
//
// CULLED: window arithmetic, DST bucketing, caption wording — all pinned by
// `GraphTranslationTests`/`GraphDayDetailTests` over the same fold, which
// manual items now share. Store round-trips — `ManualItemsTests` owns them.
//
// SCOPE: all small. Pure translation over plain values, `now`/`timeZone`
// injected, no clock, no disk.
// ═════════════════════════════════════════════════════════════════════════════

// The same pinned Tuesday the other graph suites use: 2026-02-10T15:00:00Z =
// 10:00 Tue Feb 10 in Indiana. Window opens Sun Feb 8; today is cell 2.
private enum Pinned {
    static let zone = TimeZone(identifier: "America/Indianapolis")!
    static let now = Date(timeIntervalSince1970: 1_770_735_600)
    /// 15:00 local on **Wed Feb 11** = `2026-02-11T20:00:00Z`. Cell 3.
    static let wednesdayAfternoon = Date(timeIntervalSince1970: 1_770_840_000)
    static let baseURL = URL(string: "https://purdue.brightspace.com")!
    static let courseId = 1_360_027
}

/// A manual item on the pinned Wednesday. The force-unwrap is fine in a test:
/// the link literal is non-empty by inspection.
private func manual(
    _ kind: ManualItem.Kind,
    name: String = "Exam 1",
    link: String = "https://example.org/study-guide",
    due: Date = Pinned.wednesdayAfternoon
) -> ManualItem {
    ManualItem(courseId: Pinned.courseId, kind: kind, name: name, link: link, due: due)!
}

private func strip(_ manual: [ManualItem], state: AssignmentsState = .neverFetched) -> [GraphCell] {
    GraphTranslation.strip(
        state: state, now: Pinned.now, timeZone: Pinned.zone,
        courseId: Pinned.courseId, courseLabel: "CS 25200", baseURL: Pinned.baseURL,
        manual: manual
    )
}

@Suite("Manual items — into the graph fold")
struct ManualGraphTests {

    // ── Priority 1: visible, right day, working link ─────────────────────────

    @Test("a manual item fills its due day's cell and appears in its detail")
    func manualItemReachesCellAndPopup() throws {
        // Act
        let cells = strip([manual(.assignment)])

        // Assert — cell 3 (Wed Feb 11), filled AND explained: the two readings
        // of one bucketing, the same invariant fetched items are pinned to.
        #expect(cells[3].tier == .assignment)
        let detail = try #require(cells[3].detail)
        #expect(detail.items.map(\.title) == ["Exam 1"])
        #expect(detail.caption == "Wed Feb 11 · CS 25200")
        // Every other day stays empty.
        #expect(cells.enumerated().allSatisfy { $0.offset == 3 || $0.element.tier == nil })
    }

    @Test("the pasted link is the popup row's destination, verbatim")
    func pastedLinkIsOpaque() throws {
        // Arrange — a link with a query, exactly as pasted from a browser.
        let pasted = "https://example.org/exam?week=4"

        // Act
        let items = try #require(strip([manual(.test, link: pasted)])[3].detail).items

        // Assert — untouched: not re-derived, not normalised, not templated.
        #expect(items.map(\.url.absoluteString) == [pasted])
    }

    @Test("an unparsable link degrades to the course home, never to no row")
    func unparsableLinkFallsBackToCourseHome() throws {
        // Arrange — non-empty (the store's only rule) but not a URL. The row
        // must still exist and still click SOMEWHERE sensible, because
        // `GraphDayItem.url` is non-optional for the good reason that a listed
        // item must be clickable.
        let items = try #require(strip([manual(.quiz, link: "see syllabus §3")])[3].detail).items

        // Assert
        #expect(items.map(\.url.absoluteString)
            == ["https://purdue.brightspace.com/d2l/home/\(Pinned.courseId)"])
    }

    @Test("an item due outside the window fills nothing")
    func outsideTheWindowIsExcluded() {
        // Arrange — the day before the window opens (Sat Feb 7).
        let past = manual(.test, due: Pinned.now.addingTimeInterval(-4 * 24 * 60 * 60))

        // Act / Assert — an exclusion empties cells, never shortens the strip.
        let cells = strip([past])
        #expect(cells.count == GraphTranslation.windowDays)
        #expect(cells.allSatisfy { $0.tier == nil && $0.detail == nil })
    }

    // ── Priority 2: kinds → tiers, and the ranking ───────────────────────────

    @Test("each manual kind fills its own tier", arguments: [
        (ManualItem.Kind.assignment, CellTier.assignment),
        (ManualItem.Kind.quiz, CellTier.quiz),
        (ManualItem.Kind.test, CellTier.test),
    ])
    func kindsMapToTiers(kind: ManualItem.Kind, tier: CellTier) {
        #expect(strip([manual(kind)])[3].tier == tier)
    }

    @Test("a manual test outranks a fetched quiz sharing its day")
    func manualTestWinsTheSharedDay() throws {
        // Arrange — the ranking working ACROSS the merge: a fetched quiz and a
        // manual test on one day must resolve exactly as two fetched kinds do.
        let quiz = Assignment(
            id: 9_101, courseId: Pinned.courseId, name: "Quiz 4",
            dueDate: Pinned.wednesdayAfternoon, isHidden: false, groupTypeId: nil,
            kind: .quiz
        )

        // Act
        let cells = strip([manual(.test)], state: .loaded([quiz]))

        // Assert — the square shows the test; the popup shows BOTH, name-sorted.
        #expect(cells[3].tier == .test)
        let detail = try #require(cells[3].detail)
        #expect(detail.items.map(\.title) == ["Exam 1", "Quiz 4"])
        #expect(detail.items.map(\.tier) == [.test, .quiz])
    }

    @Test("merged detail order is deterministic: name, then fetched before manual")
    func mergedOrderIsTotal() throws {
        // Arrange — a fetched item and a manual item SHARING a name, the tie
        // the order must break the same way every build, or `MenuModel`'s
        // `Equatable` skip-rebuild fires on identical data.
        let fetched = Assignment(
            id: 9_102, courseId: Pinned.courseId, name: "Exam 1",
            dueDate: Pinned.wednesdayAfternoon, isHidden: false, groupTypeId: nil
        )

        // Act
        let items = try #require(strip([manual(.test)], state: .loaded([fetched]))[3].detail).items

        // Assert — the official item leads on the tie.
        #expect(items.map(\.tier) == [.assignment, .test])
    }
}

@Suite("Manual items — through the whole-course translation")
struct ManualMenuTests {

    private func course() -> Course {
        Course(
            id: Pinned.courseId, name: "Systems Programming",
            code: "wl.202610.CS.25200.LE1", role: "Learner", isActive: true,
            homeUrl: nil,
            startDate: "2000-01-01T00:00:00.000Z", endDate: "2999-01-01T00:00:00.000Z"
        )
    }

    @Test("manual items reach the course's graph via MenuTranslation.menu")
    func manualItemsSurviveTheWholeChain() throws {
        // Act — the end of the chain: keyed manual items in, a MenuModel out.
        let model = MenuTranslation.menu(
            courses: [course()], lastFetch: Pinned.now, now: Pinned.now,
            baseURL: Pinned.baseURL,
            manualItems: [Pinned.courseId: [manual(.test)]],
            timeZone: Pinned.zone
        )

        // Assert — the square and its popup, exactly as the strip-level suite
        // pins them, proving the keying and the join deliver to the right row.
        let row = try #require(model.course(id: Pinned.courseId))
        #expect(row.graph[3].tier == .test)
        #expect(row.graph[3].detail?.items.map(\.title) == ["Exam 1"])
        // And the submenu is untouched by the item: forms, not listings.
        #expect(row.submenu == AddItemKind.allCases.map {
            .addForm(AddItemFormRow(courseId: Pinned.courseId, kind: $0))
        })
    }

    @Test("another course's manual items never bleed into this one's graph")
    func manualItemsDoNotCrossCourses() throws {
        // Arrange — an item keyed under a DIFFERENT course id: the transposition
        // failure every other join pins against, restated for this one.
        let model = MenuTranslation.menu(
            courses: [course()], lastFetch: Pinned.now, now: Pinned.now,
            baseURL: Pinned.baseURL,
            manualItems: [999_999: [manual(.test)]],
            timeZone: Pinned.zone
        )

        // Assert
        let row = try #require(model.course(id: Pinned.courseId))
        #expect(row.graph.allSatisfy { $0.tier == nil })
    }
}

private extension MenuModel {
    func course(id: Int) -> CourseRow? { self.courses.first { $0.id == id } }
}
