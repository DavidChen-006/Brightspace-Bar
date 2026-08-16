import Foundation
import Testing

import AssignmentPipeline
import CourseMenu
import CoursePipeline
import MenuAdapter

// ═════════════════════════════════════════════════════════════════════════════
// THE "HEADS UP" SECTION — gradebook columns nothing else in the menu knows about.
//
// A student-scored column that matches no fetched assignment or quiz is graded
// work whose only trace is the gradebook. It becomes a third section of the same
// per-course submenu — name only, no date, linking to the course gradebook.
//
// PRIORITIES:
//
//   1. A HEADS-UP ROW MUST NEVER IMPERSONATE DATED WORK. This is the one kind
//      that genuinely has no deadline: `dueDate` is null by contract in v1. The
//      failure is silent and it runs in one direction — a row that acquires a
//      "Due Sep 15" line tells a student a deadline exists when the daemon never
//      saw one, and the student cannot tell it apart from a real assignment. The
//      fixed subtitle is what makes the section explain itself, and
//      `subtitleSurvivesAHostileDueDate` is the test that separates "the wording
//      is fixed" from "the wording happens to be nil because the date is".
//
//   2. CLICK-TARGET CORRECTNESS ACROSS A THIRD TEMPLATE. The same argument
//      `QuizSectionTests` makes for two: every way of choosing wrong yields a
//      REAL Brightspace page that is the wrong one, and nothing downstream can
//      catch it because `MenuAssembler` opens whatever URL it is handed. A
//      gradebook column has no dropbox folder and no quiz, so `db=812004` and
//      `qi=812004` are both pages for entities that do not exist.
//
// CULLED: whether the heads-up row is the RIGHT column — the student-scored /
// unmatched diff is the daemon's rule and is pinned on the Node side, not here.
// Also culled: failure-state shapes, determinism, and the whole-course wiring —
// those rules are kind-agnostic and `QuizSectionTests` already pins them; a
// third kind does not give them a new way to break.
//
// SCOPE: all small. Pure translation over plain values, `now` and `timeZone`
// supplied.
// ═════════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────
// PINNED POLICY — the builder implements exactly this.
//
// ── The section list gains one entry, LAST ──────────────────────────────────
//     (.assignment, "Assignments")
//     (.quiz,       "Quizzes")
//     (.gradeOnly,  "Heads up")      ← new, and last
//
//   Last because it is the least certain: a heads-up row is inferred from a
//   gradebook column rather than fetched as a piece of work, so it sits below
//   everything the student can actually open.
//
//   The LABELLING RULE IS UNCHANGED: headers appear only when more than one
//   section is populated. A gradeOnly-only course therefore shows bare rows and
//   NO "Heads up" header — the same shape a quizzes-only course has had since
//   sections shipped, and the reason `AssignmentWiringTests`' `rows.count == 5`
//   still holds.
//
//   Sorting stays WITHIN the section and is the existing total order. Every
//   gradeOnly item is undated by contract, so in practice the section is name
//   ascending, id ascending.
//
// ── The subtitle is a fixed string, never a date line ───────────────────────
//     subtitle == "In gradebook — no due date"
//   For EVERY gradeOnly row, unconditionally — not `dueLabel(item.dueDate…)`,
//   which would render nil today and a fabricated deadline the day a date
//   appears on one of these. Em dash, matching the wording in LADDER-PLAN.
//
// ── The click target is the course gradebook ───────────────────────────────
//     {base}/d2l/lms/grades/my_grades/main.d2l?ou={courseId}
//   Built by a new `GradebookLink` beside `AssignmentLink`/`QuizLink`; the
//   exhaustive `clickTarget` switch forces the decision at compile time. There
//   is no per-column deep link — D2L's gradebook is one page per course — so the
//   column id appears NOWHERE in the URL. `ou` comes from the course whose
//   submenu this is, never from the item.
//
//   These tests name only the URL, not the builder: which module `GradebookLink`
//   lands in is the builder's call, and the click target is what a student
//   actually experiences.
//
// ── Visibility is unchanged ────────────────────────────────────────────────
//   `isHidden` is never set on this kind (the daemon does not send it and the
//   decoder defaults it to false), so no new policy is needed and none is added.
// ─────────────────────────────────────────────────────────────────────────────

private enum Pinned {
    static let baseURL = URL(string: "https://purdue.brightspace.com")!
    static let utc = TimeZone(identifier: "UTC")!

    static let assignmentsHeader = "Assignments"
    static let quizzesHeader = "Quizzes"
    static let headsUpHeader = "Heads up"
    static let noAssignments = "No assignments"

    /// The whole subtitle, written out rather than composed, so a builder cannot
    /// satisfy it with a prefix and a formatted date.
    static let gradebookSubtitle = "In gradebook — no due date"

    /// `2026-02-20T00:00:00Z`, the instant the sibling suite probes at — before
    /// every due date used below, so `dueLabel` would render a *future* deadline
    /// rather than "Overdue" if it were ever reached.
    static let now = Date(timeIntervalSince1970: 1_771_545_600)

    /// `2026-09-15T23:59:00Z`. In UTC that is Sep 15, so a row that wrongly ran
    /// through `dueLabel` would read exactly "Due Sep 15" — the string this
    /// section must never produce.
    static let septemberFifteenth = Date(timeIntervalSince1970: 1_789_516_740)
    static let septemberFifteenthLabel = "Due Sep 15"

    // Full literals, so editing a template cannot silently rewrite the
    // expectation alongside the code.
    static let civicsGradebookURL =
        "https://purdue.brightspace.com/d2l/lms/grades/my_grades/main.d2l?ou=412690"
    static let scholarlyGradebookURL =
        "https://purdue.brightspace.com/d2l/lms/grades/my_grades/main.d2l?ou=440703"
}

private enum Real {
    static let scholarlyID = 440_703
    static let citiID = 445_296
    static let citiName = "Upload your CITI Certificate to Complete Module 2"
    static let moduleOneQuizID = 476_481

    static let civicsID = 412_690
    static let untitledID = 648_911
    static let honorPledgeID = 619_243

    /// Synthetic `GradeObjectId`s — no reachable course has a live gradebook to
    /// harvest — chosen non-adjacent so an index or zip bug yields a wrong number
    /// rather than a coincidentally right one.
    static let participationID = 812_004
    static let midtermColumnID = 812_311
    static let finalPaperColumnID = 813_902
}

private func work(
    _ id: Int,
    _ courseId: Int,
    _ kind: ItemKind,
    name: String,
    dueDate: Date? = nil,
    isHidden: Bool = false
) -> Assignment {
    Assignment(
        id: id, courseId: courseId, name: name, dueDate: dueDate,
        isHidden: isHidden, groupTypeId: nil, kind: kind
    )
}

private func headers(_ rows: [MenuRow]) -> [String] {
    rows.compactMap { if case .sectionHeader(let text) = $0 { text } else { nil } }
}

private func submenu(_ items: [Assignment], courseId: Int) -> [MenuRow] {
    AssignmentTranslation.submenu(
        state: .loaded(items), courseId: courseId,
        now: Pinned.now, baseURL: Pinned.baseURL, timeZone: Pinned.utc
    )
}

@Suite("Heads up — the gradeOnly section")
struct GradeOnlySectionTests {

    @Test("all three kinds are labelled Assignments, Quizzes, then Heads up")
    func headsUpIsTheLastSection() {
        // Arrange — one of each, deliberately with the gradebook column FIRST in
        // the input, so a passing result cannot be an artifact of the input
        // already being in section order.
        let items = [
            work(Real.participationID, Real.scholarlyID, .gradeOnly, name: "Participation"),
            work(Real.citiID, Real.scholarlyID, .assignment, name: Real.citiName),
            work(Real.moduleOneQuizID, Real.scholarlyID, .quiz, name: "Module 1 Completion Quiz"),
        ]

        // Act
        let rows = submenu(items, courseId: Real.scholarlyID)

        // Assert
        #expect(headers(rows) == [
            Pinned.assignmentsHeader, Pinned.quizzesHeader, Pinned.headsUpHeader,
        ])
    }

    @Test("Heads up sits below assignments even when there are no quizzes")
    func headsUpFollowsAssignmentsWithNoQuizzesBetween() {
        // Arrange — the shape a real course is most likely to have: work the
        // student can open, plus a column they cannot. The heads-up rows must
        // still land underneath, not merge into the assignments above them.
        let items = [
            work(Real.participationID, Real.civicsID, .gradeOnly, name: "Participation"),
            work(Real.untitledID, Real.civicsID, .assignment, name: "Untitled"),
        ]

        // Act
        let rows = submenu(items, courseId: Real.civicsID)

        // Assert — headers in order, and the ids in the order the sections imply.
        #expect(headers(rows) == [Pinned.assignmentsHeader, Pinned.headsUpHeader])
        #expect(rows.assignments.map(\.id) == [Real.untitledID, Real.participationID])
    }

    @Test("a course whose only items are gradebook columns gets no header")
    func gradeOnlyAloneKeepsTheUnlabelledShape() {
        // Arrange — the labelling rule is unchanged, and this is the case that
        // proves it: with one populated section there is nothing to disambiguate,
        // so a lone "Heads up" label would be noise. It is also the regression
        // guard — an unconditional header would break `rows.count == 5` in
        // `AssignmentWiringTests`.
        let items = [
            work(Real.participationID, Real.civicsID, .gradeOnly, name: "Participation"),
            work(Real.midtermColumnID, Real.civicsID, .gradeOnly, name: "Midterm Exam"),
        ]

        // Act
        let rows = submenu(items, courseId: Real.civicsID)

        // Assert
        #expect(headers(rows).isEmpty)
        #expect(rows.count == 2)
    }

    @Test("a course with no items at all still says No assignments, naming no section")
    func nothingAtAllNamesNoSection() {
        // Arrange / Act — adding a section must not add a header to the empty
        // case. A "Heads up" label over the empty message would claim the daemon
        // found a gradebook column when it found none.
        let rows = submenu([], courseId: Real.civicsID)

        // Assert
        #expect(rows == [.message(Pinned.noAssignments)])
    }

    @Test("gradebook columns are name-ordered within their section")
    func headsUpRowsAreNameOrdered() {
        // Arrange — every item of this kind is undated by contract, so the
        // existing total order reduces to name ascending. Fed in reverse so a
        // no-op sort fails.
        let items = [
            work(Real.finalPaperColumnID, Real.civicsID, .gradeOnly, name: "Zebra Column"),
            work(Real.midtermColumnID, Real.civicsID, .gradeOnly, name: "Midterm Exam"),
            work(Real.participationID, Real.civicsID, .gradeOnly, name: "Attendance"),
        ]

        // Act
        let rows = submenu(items, courseId: Real.civicsID)

        // Assert
        #expect(rows.assignments.map(\.title) == ["Attendance", "Midterm Exam", "Zebra Column"])
    }

    @Test("a gradebook row is not sorted across the boundary into another section")
    func headsUpDoesNotJumpItsSection() {
        // Arrange — the heads-up column's name sorts FIRST alphabetically and the
        // assignment above it is undated too, so an implementation that sorted one
        // flat list and then labelled it would put "Attendance" at the top.
        let items = [
            work(Real.participationID, Real.civicsID, .gradeOnly, name: "Attendance"),
            work(Real.untitledID, Real.civicsID, .assignment, name: "Untitled"),
        ]

        // Act
        let rows = submenu(items, courseId: Real.civicsID)

        // Assert — sections are the outer key.
        #expect(rows.assignments.map(\.id) == [Real.untitledID, Real.participationID])
    }
}

@Suite("Heads up — the subtitle that says why there is no date")
struct GradeOnlySubtitleTests {

    @Test("a gradebook row explains itself with the fixed gradebook line")
    func subtitleIsTheFixedString() throws {
        // Arrange — priority 1. The GUI renders `subtitle` verbatim, and a nil
        // here would leave a bare name with no hint of where it came from: the
        // student would read an unopenable row as an assignment the app forgot to
        // date.
        let items = [work(Real.participationID, Real.civicsID, .gradeOnly, name: "Participation")]

        // Act
        let row = try #require(submenu(items, courseId: Real.civicsID).assignments.first)

        // Assert
        #expect(row.subtitle == Pinned.gradebookSubtitle)
    }

    @Test("a gradebook row keeps the fixed line even when it arrives carrying a due date")
    func subtitleSurvivesAHostileDueDate() throws {
        // Arrange — THE hostile fixture for priority 1, and the only thing that
        // separates "the subtitle is fixed" from "the subtitle is nil because the
        // date is". `dueDate` is null by contract in v1, so this item should not
        // exist — which is exactly why it is here: `dueLabel` wired to this kind
        // passes every other test in this file and starts lying the day the
        // contract grows a date ladder.
        let items = [
            work(Real.participationID, Real.civicsID, .gradeOnly,
                 name: "Participation", dueDate: Pinned.septemberFifteenth),
        ]

        // Act
        let row = try #require(submenu(items, courseId: Real.civicsID).assignments.first)

        // Assert — the fixed line, and demonstrably not the date line that the
        // same instant produces for every other kind.
        #expect(row.subtitle == Pinned.gradebookSubtitle)
        #expect(row.subtitle != Pinned.septemberFifteenthLabel)
        #expect(
            AssignmentTranslation.dueLabel(
                Pinned.septemberFifteenth, now: Pinned.now, timeZone: Pinned.utc
            ) == Pinned.septemberFifteenthLabel,
            "the fixture no longer exercises the date line it exists to rule out"
        )
    }

    @Test("the fixed line is this kind's alone — other kinds still get their date")
    func otherKindsKeepTheirDueLabel() throws {
        // Arrange — the inverse regression: a builder that reached for the fixed
        // string one level too high would silently blank every real deadline in
        // the menu.
        let items = [
            work(Real.citiID, Real.civicsID, .assignment,
                 name: Real.citiName, dueDate: Pinned.septemberFifteenth),
            work(Real.participationID, Real.civicsID, .gradeOnly, name: "Participation"),
        ]

        // Act
        let rows = submenu(items, courseId: Real.civicsID)
        let assignment = try #require(rows.assignments.first { $0.id == Real.citiID })
        let column = try #require(rows.assignments.first { $0.id == Real.participationID })

        // Assert
        #expect(assignment.subtitle == Pinned.septemberFifteenthLabel)
        #expect(column.subtitle == Pinned.gradebookSubtitle)
    }
}

@Suite("Heads up — the click target is the course gradebook")
struct GradeOnlyClickTargetTests {

    @Test("a gradebook row opens its course's my-grades page")
    func gradeOnlyOpensTheGradebook() throws {
        // Arrange — priority 2, stated as the full literal.
        let items = [work(Real.participationID, Real.civicsID, .gradeOnly, name: "Participation")]

        // Act
        let row = try #require(submenu(items, courseId: Real.civicsID).assignments.first)

        // Assert
        #expect(row.url.absoluteString == Pinned.civicsGradebookURL)
    }

    @Test("a gradebook row carries neither template's parameters")
    func gradeOnlyCarriesNoItemParameters() throws {
        // Arrange / Act — the copy-paste failure, in both available directions:
        // `db=812004` is a dropbox folder that does not exist and `qi=812004` is a
        // quiz that does not exist, and each is a syntactically perfect URL.
        let items = [work(Real.participationID, Real.civicsID, .gradeOnly, name: "Participation")]
        let row = try #require(submenu(items, courseId: Real.civicsID).assignments.first)

        // Assert — and no column id anywhere: D2L's gradebook is one page per
        // course, so there is no per-column deep link to get wrong.
        #expect(!row.url.absoluteString.contains("db="))
        #expect(!row.url.absoluteString.contains("qi="))
        #expect(!row.url.absoluteString.contains("grpid"))
        #expect(!row.url.absoluteString.contains(String(Real.participationID)))
    }

    @Test("ou comes from the submenu's course, not from the item")
    func ouComesFromTheSubmenusCourse() throws {
        // Arrange — an item deliberately stamped with the WRONG course, which is
        // what a fan-out bug produces. The submenu's own course id must win: a
        // heads-up row in course A's submenu cannot open course B's gradebook,
        // which is a real page showing real grades for the wrong class.
        let mislabelled = work(Real.participationID, 999_999, .gradeOnly, name: "Participation")

        // Act
        let row = try #require(submenu([mislabelled], courseId: Real.civicsID).assignments.first)

        // Assert
        #expect(row.url.absoluteString == Pinned.civicsGradebookURL)
        #expect(!row.url.absoluteString.contains("999999"))
    }

    @Test("every kind in one submenu routes to its own template")
    func theThreeTemplatesDoNotBleed() throws {
        // Arrange — all three side by side, which is the only arrangement that
        // catches a switch arm wired to its neighbour.
        let items = [
            work(Real.citiID, Real.scholarlyID, .assignment, name: Real.citiName),
            work(Real.moduleOneQuizID, Real.scholarlyID, .quiz, name: "Module 1 Completion Quiz"),
            work(Real.participationID, Real.scholarlyID, .gradeOnly, name: "Participation"),
        ]

        // Act
        let rows = submenu(items, courseId: Real.scholarlyID)
        let assignment = try #require(rows.assignments.first { $0.id == Real.citiID })
        let quiz = try #require(rows.assignments.first { $0.id == Real.moduleOneQuizID })
        let column = try #require(rows.assignments.first { $0.id == Real.participationID })

        // Assert — the two shipped templates are untouched and the third is its
        // own page.
        #expect(assignment.url.absoluteString.contains("dropbox/user/folder_submit_files.d2l?db=445296"))
        #expect(quiz.url.absoluteString.contains("quizzing/user/quiz_summary.d2l?qi=476481"))
        #expect(column.url.absoluteString == Pinned.scholarlyGradebookURL)
    }

    @Test("two courses' gradebook rows never share an ou")
    func gradebookRowsDoNotCrossCourses() throws {
        // Arrange — the gradebook URL's ONLY variable is `ou`, so a cached or
        // shared value is the one way this template can be wrong, and it points a
        // student at another class's grades.
        let civics = submenu(
            [work(Real.participationID, Real.civicsID, .gradeOnly, name: "Participation")],
            courseId: Real.civicsID
        )
        let scholarly = submenu(
            [work(Real.midtermColumnID, Real.scholarlyID, .gradeOnly, name: "Midterm Exam")],
            courseId: Real.scholarlyID
        )

        // Act
        let civicsRow = try #require(civics.assignments.first)
        let scholarlyRow = try #require(scholarly.assignments.first)

        // Assert
        #expect(civicsRow.url.absoluteString == Pinned.civicsGradebookURL)
        #expect(scholarlyRow.url.absoluteString == Pinned.scholarlyGradebookURL)
    }

    @Test("the shipped kinds' click targets are unchanged by the third section")
    func theShippedTemplatesDoNotMove() throws {
        // Arrange — the regression guard on priority 2. Widening the exhaustive
        // switch is a compile-time edit to the one function that chooses between
        // templates, and the two existing arms are within a line of the new one.
        let items = [
            work(Real.untitledID, Real.civicsID, .assignment, name: "Untitled"),
            work(Real.honorPledgeID, Real.civicsID, .quiz, name: "Honor Pledge"),
        ]

        // Act
        let rows = submenu(items, courseId: Real.civicsID)
        let assignment = try #require(rows.assignments.first { $0.id == Real.untitledID })
        let quiz = try #require(rows.assignments.first { $0.id == Real.honorPledgeID })

        // Assert — the browser-verified literals, unchanged.
        #expect(assignment.url.absoluteString ==
            "https://purdue.brightspace.com/d2l/lms/dropbox/user/folder_submit_files.d2l?db=648911&grpid=0&ou=412690")
        #expect(quiz.url.absoluteString ==
            "https://purdue.brightspace.com/d2l/lms/quizzing/user/quiz_summary.d2l?qi=619243&ou=412690")
    }
}
