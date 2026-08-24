import Foundation
import Testing
import CourseMenu
import AggregateGraph

// ─────────────────────────────────────────────────────────────────────────────
// The combine is pure, so the tests are arithmetic: strips in, one strip out.
// Cells are hand-written, exactly the way the GUI's own tests build strips —
// no pipeline, no clock, no network.
// ─────────────────────────────────────────────────────────────────────────────

private func item(_ title: String, tier: CellTier = .assignment) -> GraphDayItem {
    GraphDayItem(title: title, tier: tier, url: URL(string: "https://example.edu/\(title)")!)
}

private func cell(
    _ tier: CellTier?, today: Bool = false, caption: String? = nil, items: [GraphDayItem] = []
) -> GraphCell {
    GraphCell(
        tier: tier,
        isToday: today,
        detail: caption.map { GraphDayDetail(caption: $0, items: items) }
    )
}

private func empty(_ count: Int) -> [GraphCell] {
    Array(repeating: cell(nil), count: count)
}

@Suite struct AggregateStripTests {

    // MARK: - The exactness argument's foundation

    /// PINS the property the whole input-type decision rests on: a cell's tier
    /// is `max` over item kinds, and `max` is associative, so aggregating
    /// finished cells is exact. If `CellTier` ever gains a case that breaks
    /// the rank ordering, or stops being a rank at all, this fails loudly and
    /// the counts-as-input design must be revisited (see AggregateStrip.swift
    /// header).
    @Test func tierOrderingPin() {
        #expect(CellTier.assignment.rawValue == 1)
        #expect(CellTier.quiz.rawValue == 2)
        #expect(CellTier.test.rawValue == 3)
        #expect(CellTier.assignment < CellTier.quiz)
        #expect(CellTier.quiz < CellTier.test)
        #expect(CellTier.allCases.max() == .test)
        // Associativity in miniature: per-course maxima vs one flat max.
        let a: [CellTier] = [.assignment, .assignment]
        let b: [CellTier] = [.quiz]
        #expect(Swift.max(a.max()!, b.max()!) == (a + b).max()!)
    }

    // MARK: - Per-day intensity

    @Test func tierIsMaxAcrossCourses() throws {
        let out = try AggregateGraph.combined([
            CourseStrip(label: "CS 25200", cells: [cell(.assignment), cell(nil), cell(.quiz)]),
            CourseStrip(label: "ANTH 21000", cells: [cell(.quiz), cell(nil), cell(.assignment)]),
            CourseStrip(label: "MA 26100", cells: [cell(nil), cell(nil), cell(nil)]),
        ])
        #expect(out.map(\.tier) == [.quiz, nil, .quiz])
    }

    @Test func emptyDayEverywhereStaysEmpty() throws {
        let out = try AggregateGraph.combined([
            CourseStrip(label: "A", cells: empty(4)),
            CourseStrip(label: "B", cells: empty(4)),
        ])
        #expect(out.count == 4)
        #expect(out.allSatisfy { $0.tier == nil && $0.detail == nil && !$0.isToday })
    }

    // MARK: - Grouped detail

    @Test func detailGroupsByCourseInCallerOrder() throws {
        let csItems = [item("Project 2"), item("Quiz 4", tier: .quiz)]
        let anthItems = [item("Reading response")]
        let out = try AggregateGraph.combined([
            CourseStrip(label: "CS 25200", cells: [
                cell(.quiz, caption: "Thu Aug 27 · CS 25200", items: csItems)
            ]),
            CourseStrip(label: "ANTH 21000", cells: [
                cell(.assignment, caption: "Thu Aug 27 · ANTH 21000", items: anthItems)
            ]),
        ])
        let detail = try #require(out[0].detail)
        #expect(detail.caption == "Thu Aug 27 · everything due")
        #expect(detail.sections == [
            AggregateDaySection(courseLabel: "CS 25200", items: csItems),
            AggregateDaySection(courseLabel: "ANTH 21000", items: anthItems),
        ])
    }

    /// Course order is the CALLER's order, never re-sorted — flipping the input
    /// flips the sections, and the caption's date half follows the first
    /// contributing course.
    @Test func sectionOrderFollowsInputOrder() throws {
        let strips = [
            CourseStrip(label: "ANTH 21000", cells: [
                cell(.assignment, caption: "Thu Aug 27 · ANTH 21000", items: [item("Reading")])
            ]),
            CourseStrip(label: "CS 25200", cells: [
                cell(.quiz, caption: "Thu Aug 27 · CS 25200", items: [item("Quiz", tier: .quiz)])
            ]),
        ]
        let forward = try AggregateGraph.combined(strips)
        let reversed = try AggregateGraph.combined(strips.reversed())
        #expect(forward[0].detail?.sections.map(\.courseLabel) == ["ANTH 21000", "CS 25200"])
        #expect(reversed[0].detail?.sections.map(\.courseLabel) == ["CS 25200", "ANTH 21000"])
    }

    /// A course with nothing due that day contributes no section — never an
    /// empty one — and a caption with no course half ("Thu Aug 27") is already
    /// the date.
    @Test func quietCoursesContributeNoSection() throws {
        let out = try AggregateGraph.combined([
            CourseStrip(label: "MA 26100", cells: [cell(nil)]),
            CourseStrip(label: "CS 25200", cells: [
                cell(.assignment, caption: "Thu Aug 27", items: [item("Homework 3")])
            ]),
        ])
        let detail = try #require(out[0].detail)
        #expect(detail.caption == "Thu Aug 27 · everything due")
        #expect(detail.sections.map(\.courseLabel) == ["CS 25200"])
    }

    /// Strips built without link context carry fills but no details; the
    /// aggregate degrades the same way `GraphCell.detail` documents — a filled
    /// cell with no popup, never a fabricated one.
    @Test func detaillessInputYieldsDetaillessAggregate() throws {
        let out = try AggregateGraph.combined([
            CourseStrip(label: "A", cells: [cell(.quiz)]),
            CourseStrip(label: "B", cells: [cell(.assignment)]),
        ])
        #expect(out[0].tier == .quiz)
        #expect(out[0].detail == nil)
    }

    // MARK: - Axis and today

    @Test func isTodayIsPreservedPositionally() throws {
        let out = try AggregateGraph.combined([
            CourseStrip(label: "A", cells: [cell(nil), cell(.assignment, today: true), cell(nil)]),
            CourseStrip(label: "B", cells: [cell(nil), cell(nil, today: true), cell(nil)]),
        ])
        #expect(out.map(\.isToday) == [false, true, false])
    }

    @Test func mismatchedLengthsThrowNamingTheCourse() {
        #expect(throws: AggregateGraphError.mismatchedStripLengths(
            expected: 3, courseLabel: "B", actual: 2
        )) {
            try AggregateGraph.combined([
                CourseStrip(label: "A", cells: empty(3)),
                CourseStrip(label: "B", cells: empty(2)),
            ])
        }
    }

    @Test func noCoursesYieldsNoStrip() throws {
        #expect(try AggregateGraph.combined([]).isEmpty)
    }

    @Test func singleCoursePassesThroughTiersAndToday() throws {
        let strip = [cell(.assignment, today: true), cell(nil), cell(.quiz)]
        let out = try AggregateGraph.combined([CourseStrip(label: "A", cells: strip)])
        #expect(out.map(\.tier) == [.assignment, nil, .quiz])
        #expect(out.map(\.isToday) == [true, false, false])
    }

    @Test func combineIsDeterministic() throws {
        let strips = [
            CourseStrip(label: "CS 25200", cells: [
                cell(.quiz, today: true, caption: "Sun Aug 23 · CS 25200",
                     items: [item("Quiz 1", tier: .quiz), item("Lab 0")])
            ]),
            CourseStrip(label: "ANTH 21000", cells: [
                cell(.assignment, today: true, caption: "Sun Aug 23 · ANTH 21000",
                     items: [item("Essay")])
            ]),
        ]
        #expect(try AggregateGraph.combined(strips) == AggregateGraph.combined(strips))
    }
}
