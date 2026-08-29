import Foundation
import Testing

import AssignmentPipeline
import CourseMenu
import CoursePipeline
import ManualItems
import MenuAdapter

// ═════════════════════════════════════════════════════════════════════════════
// The two features this file pins:
//
//   • THE AGGREGATE ROW (Intent 3). When two or more course rows render, the
//     menu leads with `.course(CourseRow(id: -1, title: "All classes", …))`
//     followed by `.separator`, BEFORE the section headers. Its graph is the
//     fold of the rendered courses' strips (popup titles carry the course-label
//     prefix, "CS 25200 · Homework 2"), its submenu is empty (a view, not a
//     course), and its url is baseURL/d2l/home. With zero or one course there
//     is no aggregate row — the fold IS the course list.
//
//   • THE "THIS WEEK" BLOCK (week stats, Intent 5). `CourseRow.weekLines`
//     carries the per-course lines: a counts line for the current calendar week
//     ("2 assignments · 1 quiz", omitted when all zero), then the single next
//     item due at-or-after now across ALL upcoming work ("next: <name> · <Wkd>",
//     omitted when nothing is upcoming). Derived from unhidden, dated,
//     deadline-tiered fetched items (gradeOnly excluded) plus manual items —
//     the same population that fills the graph squares.
//
// SCOPE: all small. Pure translation over plain values; `now` and the zone are
// pinned the way GraphTranslationTests pins them, so every date literal below
// is a known local wall time in Indiana.
// ═════════════════════════════════════════════════════════════════════════════

private enum Pinned {
    /// A real zone with a real DST rule — the same choice GraphTranslationTests
    /// makes, so local-day reasoning is exercised rather than vacuous.
    static let zone = TimeZone(identifier: "America/Indianapolis")!

    /// `2026-02-10T15:00:00Z` — **10:00 on TUESDAY Feb 10** in Indiana. The
    /// week containing it runs Sun Feb 8 through Sat Feb 14.
    static let now = Date(timeIntervalSince1970: 1_770_735_600)

    /// 15:00 local on **Wed Feb 11** = `2026-02-11T20:00:00Z`. In this week,
    /// after `now` — graph cell 3.
    static let wednesdayAfternoon = Date(timeIntervalSince1970: 1_770_840_000)
    /// 23:30 local on **Thu Feb 12** = `2026-02-13T04:30:00Z`. In this week.
    static let lateThursdayNight = Date(timeIntervalSince1970: 1_770_957_000)
    /// 12:00 local on **Fri Feb 13** = `2026-02-13T17:00:00Z`. In this week.
    static let noonFriday = Date(timeIntervalSince1970: 1_771_002_000)
    /// 12:00 local on **Fri Mar 20** = `2026-03-20T16:00:00Z` (EDT by then).
    /// Weeks BEYOND this one — upcoming, but never in the counts line.
    static let noonMarchTwentieth = Date(timeIntervalSince1970: 1_774_022_400)

    /// Where `wednesdayAfternoon` lands in the 112-cell window opening on
    /// Sun Feb 8: cell 3.
    static let wednesdayIndex = 3
}

/// A course with a wide-open Access window, so it is CURRENT at any test `now`
/// and these tests are not entangled with the currentness policy.
private func makeCourse(id: Int, code: String = "wl.202610.CS.10000.LE1") -> Course {
    Course(
        id: id, name: "Course \(id)", code: code, role: "Learner", isActive: true,
        homeUrl: nil,
        startDate: "2000-01-01T00:00:00.000Z", endDate: "2999-01-01T00:00:00.000Z"
    )
}

private func work(
    _ id: Int,
    _ kind: ItemKind,
    name: String,
    due: Date?,
    courseId: Int,
    isHidden: Bool = false
) -> Assignment {
    Assignment(
        id: id, courseId: courseId, name: name, dueDate: due,
        isHidden: isHidden, groupTypeId: nil, kind: kind
    )
}

private func menu(
    courses: [Course],
    assignments: [Int: AssignmentsState] = [:],
    manualItems: [Int: [ManualItem]] = [:]
) -> MenuModel {
    MenuTranslation.menu(
        courses: courses, lastFetch: Pinned.now, now: Pinned.now,
        baseURL: RealData.baseURL, assignments: assignments,
        manualItems: manualItems, timeZone: Pinned.zone
    )
}

@Suite("The aggregate row — \"All classes\" leads a multi-course menu")
struct AggregateRowTests {

    /// CS 25100 hosts the assignment, CS 25200 the quiz — same day, so the
    /// fold's max-tier rule is observable on one cell.
    private static let hostA = makeCourse(id: 101, code: "wl.202610.CS.25100.LE1")
    private static let hostB = makeCourse(id: 202, code: "wl.202610.CS.25200.LE1")

    @Test("with two or more courses the menu leads with All classes, then a separator")
    func twoCoursesLeadWithTheAggregateRow() throws {
        // Arrange / Act — the smallest menu with something to add up.
        let model = menu(courses: [Self.hostA, Self.hostB])

        // Assert — the aggregate row, Intent 3: the fold leads the menu, its
        // separator sets it off, and the first header comes only after both.
        guard case .course(let aggregate) = try #require(model.rows.first) else {
            Issue.record("the first row is not a course row")
            return
        }
        #expect(aggregate.id == -1)
        #expect(aggregate.title == "Fall 2025 All classes")  // 202610, per the fixtures
        #expect(aggregate.url == RealData.baseURL.appending(path: "d2l/home"))
        #expect(aggregate.submenu.isEmpty, "the aggregate is a view, not a course")
        #expect(model.rows[1] == .separator)
        #expect(model.rows[2] == .hairline, "the course list follows the aggregate prelude directly")
    }

    @Test("with a single course there is no aggregate row")
    func oneCourseHasNoAggregateRow() {
        // Arrange / Act — with one course the fold IS the course list, so a
        // leading "All classes" row would just duplicate it.
        let model = menu(courses: [Self.hostA])

        // Assert — no id == -1 anywhere, and the menu opens on the course list.
        #expect(!model.courses.contains { $0.id == -1 })
        #expect(model.rows.first == .hairline, "a single-course menu opens on its course boundary")
    }

    @Test("an empty enrollment has no aggregate row either")
    func zeroCoursesHaveNothingToFold() {
        // Arrange / Act
        let model = menu(courses: [])

        // Assert
        #expect(!model.courses.contains { $0.id == -1 })
    }

    @Test("the aggregate cell tier is the max across courses, and popup titles carry the course prefix")
    func theFoldTakesTheMaxTierAndPrefixesTitles() throws {
        // Arrange — an assignment (tier 1) in CS 25100 and a quiz (tier 2) in
        // CS 25200, due the same local day, so the folded cell must read quiz.
        let assignments: [Int: AssignmentsState] = [
            Self.hostA.id: .loaded([
                work(1, .assignment, name: "Homework 2", due: Pinned.wednesdayAfternoon, courseId: Self.hostA.id),
            ]),
            Self.hostB.id: .loaded([
                work(2, .quiz, name: "Quiz 3", due: Pinned.wednesdayAfternoon, courseId: Self.hostB.id),
            ]),
        ]

        // Act
        let model = menu(courses: [Self.hostA, Self.hostB], assignments: assignments)

        // Assert — aggregate row, Intent 3: highest tier wins on the folded
        // cell, and the flat popup keeps the grouping via the label prefix.
        let aggregate = try #require(model.courses.first { $0.id == -1 })
        let cell = aggregate.graph[Pinned.wednesdayIndex]
        #expect(cell.tier == .quiz, "assignment + quiz folds to the max tier")

        let titles = try #require(cell.detail).items.map(\.title)
        #expect(titles.contains("CS 25100 · Homework 2"))
        #expect(titles.contains("CS 25200 · Quiz 3"))
    }

    @Test("the aggregate weekLines fold every course's work into one block")
    func theAggregateWeekLinesSpanTheCourses() throws {
        // Arrange — one assignment in each course this week, so a per-course
        // reading would say "1 assignment" and only the union says "2".
        let assignments: [Int: AssignmentsState] = [
            Self.hostA.id: .loaded([
                work(1, .assignment, name: "Homework 2", due: Pinned.wednesdayAfternoon, courseId: Self.hostA.id),
            ]),
            Self.hostB.id: .loaded([
                work(2, .assignment, name: "Project 1", due: Pinned.noonFriday, courseId: Self.hostB.id),
            ]),
        ]

        // Act
        let model = menu(courses: [Self.hostA, Self.hostB], assignments: assignments)

        // Assert — week stats, Intent 5, over the union: counts add, and the
        // single next item is the earliest across both courses (Wed before Fri).
        let aggregate = try #require(model.courses.first { $0.id == -1 })
        #expect(aggregate.weekLines == ["This week", "2 assignments", "next: Homework 2 · Wed"])
    }
}

@Suite("weekLines — the per-course \"This week\" block")
struct WeekLinesTranslationTests {

    private static let host = makeCourse(id: 101, code: "wl.202610.CS.25100.LE1")

    /// A row for the course under test — via a SINGLE-course menu on purpose,
    /// so the claim is about the per-course derivation, not the aggregate.
    private func row(
        assignments: AssignmentsState,
        manualItems: [ManualItem] = []
    ) throws -> CourseRow {
        let model = menu(
            courses: [Self.host],
            assignments: [Self.host.id: assignments],
            manualItems: [Self.host.id: manualItems]
        )
        return try #require(model.courses.first { $0.id == Self.host.id })
    }

    @Test("a busy week with a later midterm reads counts, then the next item")
    func aBusyWeekProducesBothLines() throws {
        // Arrange — 2 assignments + 1 quiz inside Sun Feb 8 – Sat Feb 14, plus
        // a manual midterm in March: upcoming, so it proves the counts line
        // stays within the week while never being the "next" item here.
        let fetched: [Assignment] = [
            work(1, .assignment, name: "Homework 4", due: Pinned.wednesdayAfternoon, courseId: Self.host.id),
            work(2, .assignment, name: "Lab Report", due: Pinned.lateThursdayNight, courseId: Self.host.id),
            work(3, .quiz, name: "Quiz 3", due: Pinned.noonFriday, courseId: Self.host.id),
        ]
        let midterm = try #require(ManualItem(
            courseId: Self.host.id, kind: .test, name: "Midterm 1",
            link: "https://example.edu/midterm", due: Pinned.noonMarchTwentieth
        ))

        // Act
        let row = try self.row(assignments: .loaded(fetched), manualItems: [midterm])

        // Assert — week stats, Intent 5: EXACTLY these two lines. The next
        // item is the earliest due at-or-after now (Homework 4, Wednesday) —
        // the March midterm counts as upcoming but is not first.
        #expect(row.weekLines == ["This week", "2 assignments · 1 quiz", "next: Homework 4 · Wed"])
    }

    @Test("gradeOnly and hidden items count nowhere in the week block")
    func excludedPopulationsLeaveTheLinesUntouched() throws {
        // Arrange — the same visible assignment twice, once alone and once
        // beside a hidden quiz and a gradeOnly column due the same week.
        let visible = work(1, .assignment, name: "Homework 4", due: Pinned.wednesdayAfternoon, courseId: Self.host.id)
        let hidden = work(2, .quiz, name: "Hidden Quiz", due: Pinned.noonFriday, courseId: Self.host.id, isHidden: true)
        let gradeOnly = work(3, .gradeOnly, name: "Participation", due: Pinned.noonFriday, courseId: Self.host.id)

        // Act
        let alone = try self.row(assignments: .loaded([visible]))
        let crowded = try self.row(assignments: .loaded([visible, hidden, gradeOnly]))

        // Assert — week stats, Intent 5: the block reads the same population
        // that fills the squares, so hidden and gradeOnly change nothing.
        #expect(alone.weekLines == ["This week", "1 assignment", "next: Homework 4 · Wed"])
        #expect(crowded.weekLines == alone.weekLines)
    }

    @Test("no work at all means no lines at all")
    func nothingToSayRendersNothing() throws {
        // Arrange / Act — a loaded-empty course: no counts, nothing upcoming.
        let row = try self.row(assignments: .loaded([]))

        // Assert — empty, never a placeholder line (week stats, Intent 5).
        #expect(row.weekLines.isEmpty)
    }

    @Test("an empty week with only a later midterm still names what is next")
    func anEmptyWeekStillPointsAtTheMidterm() throws {
        // Arrange — nothing due this week; a manual midterm weeks out. The
        // counts line is omitted (all zero), but "what's first" still answers.
        let midterm = try #require(ManualItem(
            courseId: Self.host.id, kind: .test, name: "Midterm 1",
            link: "https://example.edu/midterm", due: Pinned.noonMarchTwentieth
        ))

        // Act
        let row = try self.row(assignments: .loaded([]), manualItems: [midterm])

        // Assert — Mar 20 2026 is a Friday.
        #expect(row.weekLines == ["This week", "next: Midterm 1 · Fri"])
    }
}
