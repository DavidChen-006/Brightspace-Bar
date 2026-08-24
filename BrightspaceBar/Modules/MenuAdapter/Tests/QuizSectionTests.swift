import Foundation
import Testing

import AssignmentPipeline
import CourseMenu
import CoursePipeline
import MenuAdapter

// ═════════════════════════════════════════════════════════════════════════════
// SECTIONS — one unified item list, presented as two labelled groups.
//
// The data model is unified (one list, one store, `kind` on each item) so a future
// heatmap can count all work from one place. The PRESENTATION is split, because a
// student reading a submenu needs to know whether "Honor Pledge" is something to
// upload or something to sit.
//
// PRIORITIES:
//
//   1. CLICK-TARGET CORRECTNESS ACROSS TWO TEMPLATES. Assignments open
//      `folder_submit_files.d2l?db=…&grpid=0&ou=…`; quizzes open
//      `quiz_summary.d2l?qi=…&ou=…`. This is the only place that chooses between
//      them, and every way of choosing wrong produces a REAL Brightspace page that
//      is the wrong one — a quiz id in a `db=` slot, a `qi=` with a neighbouring
//      course's `ou=`. Nothing downstream can catch it: `MenuAssembler` opens
//      whatever URL it is handed.
//
//   2. NO REGRESSION OF THE SHIPPED ASSIGNMENTS FEATURE. 257 tests currently
//      describe a submenu with no section headers. Adding sections must not add a
//      header where one did not exist, which is why headers are conditional rather
//      than unconditional.
//
// CULLED: quiz-specific detail lines (attempts remaining, time limit — the parser
// deliberately ignores those fields because their shapes are unverified), and
// anything about what a hidden or inactive item's page renders (unobservable).
//
// SCOPE: all small. Pure translation over plain values, `now` and `timeZone`
// supplied.
// ═════════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────
// PINNED POLICY — the builder implements exactly these.
//
// ── Section headers appear ONLY when BOTH kinds have visible rows ────────────
//     assignments + quizzes  →  .sectionHeader("Assignments"), assignment rows,
//                               .sectionHeader("Quizzes"),     quiz rows
//     assignments only       →  assignment rows, NO header
//     quizzes only           →  quiz rows, NO header
//
//   This is FORCED, not chosen: `AssignmentWiringTests.failedAppendsTheStalenessNote`
//   asserts `rows.count == 5` for a three-assignment failed submenu (3 rows +
//   separator + note). An unconditional header would make it 6 and regress a
//   shipped feature. It is also the better rule on its own terms — a header exists
//   to DISAMBIGUATE, and with one kind present there is nothing to disambiguate.
//
//   Assignments come first. They are the kind that shipped, they are what a
//   dropbox deadline usually means, and a stable order matters more than which
//   order.
//
// ── Sorting is WITHIN each section ──────────────────────────────────────────
//   The existing total order (dated before undated → dueDate ascending → name
//   ascending → id ascending) applies inside a section, never across the whole
//   list. A quiz due sooner than an assignment does NOT jump the section boundary;
//   sections are the outer key. Cross-kind deadline ordering is what a future
//   "what's due this week" view is for, and it would read the unified list
//   directly rather than the submenu.
//
// ── The note goes last, after every section ─────────────────────────────────
//     rows... + .separator + .message("Couldn't refresh — may be out of date")
//   Unchanged from the assignments-only shape, just with more rows before it.
//
// ── Per-kind click targets ──────────────────────────────────────────────────
//     .assignment  →  {base}/d2l/lms/dropbox/user/folder_submit_files.d2l?db={id}&grpid=0&ou={courseId}
//     .quiz        →  {base}/d2l/lms/quizzing/user/quiz_summary.d2l?qi={id}&ou={courseId}
//   Both browser-verified. `ou` always comes from the COURSE the submenu belongs
//   to, never from the item — so a row structurally cannot carry another course's id.
//
// ── Visibility: `isHidden` excludes, for both kinds ─────────────────────────
//   Quizzes reach this layer with `IsActive: false` already mapped onto `isHidden`
//   by `QuizParser`, so one policy covers both kinds and there is no per-kind
//   branch here. A course whose every item is hidden shows "No assignments" — the
//   existing string, kept because `AssignmentWiringTests` pins it. (The wording is
//   now slightly narrow for a menu that also holds quizzes; changing it would churn
//   existing tests for a cosmetic gain, so it is noted rather than done.)
// ─────────────────────────────────────────────────────────────────────────────

private enum Pinned {
    static let baseURL = URL(string: "https://purdue.brightspace.com")!
    static let utc = TimeZone(identifier: "UTC")!

    static let assignmentsHeader = "Assignments"
    static let quizzesHeader = "Quizzes"
    static let noAssignments = "No assignments"
    static let refreshFailed = "Couldn't refresh — may be out of date"

    /// `2026-02-20T00:00:00Z`, before every due date used below.
    static let now = Date(timeIntervalSince1970: 1_771_545_600)

    // Browser-verified literals, written out in full so editing a template cannot
    // silently rewrite the expectation alongside the code.
    static let citiURL =
        "https://purdue.brightspace.com/d2l/lms/dropbox/user/folder_submit_files.d2l?db=445296&grpid=0&ou=440703"
    static let moduleOneQuizURL =
        "https://purdue.brightspace.com/d2l/lms/quizzing/user/quiz_summary.d2l?qi=476481&ou=440703"
    static let honorPledgeURL =
        "https://purdue.brightspace.com/d2l/lms/quizzing/user/quiz_summary.d2l?qi=619243&ou=412690"
    static let untitledURL =
        "https://purdue.brightspace.com/d2l/lms/dropbox/user/folder_submit_files.d2l?db=648911&grpid=0&ou=412690"
}

private enum Real {
    static let scholarlyID = 440_703
    static let citiID = 445_296
    static let citiName = "Upload your CITI Certificate to Complete Module 2"
    static let moduleOneQuizID = 476_481
    static let moduleOneQuizName = "Module 1 Completion Quiz - What Is Research?"

    static let civicsID = 412_690
    static let untitledID = 648_911
    static let honorPledgeID = 619_243
    static let practiceQuizID = 619_244
    static let welcomeQuizID = 790_340
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

private func messages(_ rows: [MenuRow]) -> [String] {
    rows.compactMap { if case .message(let text) = $0 { text } else { nil } }
}

private func submenu(_ items: [Assignment], courseId: Int) -> [MenuRow] {
    AssignmentTranslation.submenu(
        state: .loaded(items), courseId: courseId,
        now: Pinned.now, baseURL: Pinned.baseURL, timeZone: Pinned.utc
    )
}

@Suite("Submenu sections — labelling two kinds")
struct QuizSectionTests {

    @Test("a course with both kinds gets Assignments then Quizzes, each labelled")
    func bothKindsAreSectioned() {
        // Arrange — the real Scholarly Project shape: assignments and one quiz.
        let items = [
            work(Real.citiID, Real.scholarlyID, .assignment, name: Real.citiName),
            work(Real.moduleOneQuizID, Real.scholarlyID, .quiz, name: Real.moduleOneQuizName),
        ]

        // Act
        let rows = submenu(items, courseId: Real.scholarlyID)

        // Assert
        #expect(headers(rows) == [Pinned.assignmentsHeader, Pinned.quizzesHeader])
    }

    @Test("each section holds only its own kind, in order")
    func sectionsHoldTheirOwnKind() throws {
        // Arrange — two of each, deliberately interleaved in the input so a
        // passing result cannot be an artifact of the input already being grouped.
        let items = [
            work(Real.honorPledgeID, Real.civicsID, .quiz, name: "Honor Pledge"),
            work(Real.untitledID, Real.civicsID, .assignment, name: "Untitled"),
            work(Real.welcomeQuizID, Real.civicsID, .quiz, name: "Welcome Quiz"),
            work(1, Real.civicsID, .assignment, name: "A Second Upload"),
        ]

        // Act — walk the rows, attributing each item to the header above it.
        let rows = submenu(items, courseId: Real.civicsID)
        var byHeader: [String: [Int]] = [:]
        var current: String?
        for row in rows {
            switch row {
            case .sectionHeader(let name): current = name
            case .assignment(let item): if let current { byHeader[current, default: []].append(item.id) }
            default: break
            }
        }

        // Assert — assignments name-ascending, quizzes name-ascending, each under
        // its own header and neither leaking into the other.
        #expect(byHeader[Pinned.assignmentsHeader] == [1, Real.untitledID])
        #expect(byHeader[Pinned.quizzesHeader] == [Real.honorPledgeID, Real.welcomeQuizID])
    }

    @Test("an assignments-only course gets no header, exactly as before this feature")
    func assignmentsOnlyKeepsItsOldShape() {
        // Arrange — the regression guard for priority 2. 257 existing tests describe
        // this shape; a header here would break `rows.count == 5` in
        // `AssignmentWiringTests`.
        let items = [work(Real.citiID, Real.scholarlyID, .assignment, name: Real.citiName)]

        // Act
        let rows = submenu(items, courseId: Real.scholarlyID)

        // Assert
        #expect(headers(rows).isEmpty)
        #expect(rows.count == 1)
    }

    @Test("a quizzes-only course also gets no header")
    func quizzesOnlyGetsNoHeader() {
        // Arrange — symmetry. With one kind present there is nothing to
        // disambiguate, and a lone "Quizzes" label would be noise.
        let items = [
            work(Real.honorPledgeID, Real.civicsID, .quiz, name: "Honor Pledge"),
            work(Real.welcomeQuizID, Real.civicsID, .quiz, name: "Welcome Quiz"),
        ]

        // Act
        let rows = submenu(items, courseId: Real.civicsID)

        // Assert
        #expect(headers(rows).isEmpty)
        #expect(rows.assignments.count == 2)
    }

    @Test("a kind whose only items are hidden does not get a lonely header")
    func hiddenOnlyKindLeavesNoHeader() {
        // Arrange — one visible assignment and one hidden quiz. The quiz section
        // has no visible rows, so labelling anything would produce a header over
        // nothing and imply the student is missing something.
        let items = [
            work(Real.citiID, Real.scholarlyID, .assignment, name: Real.citiName),
            work(Real.moduleOneQuizID, Real.scholarlyID, .quiz, name: "Unreleased", isHidden: true),
        ]

        // Act
        let rows = submenu(items, courseId: Real.scholarlyID)

        // Assert
        #expect(headers(rows).isEmpty)
        #expect(rows.assignments.map(\.id) == [Real.citiID])
    }

    @Test("a course where every item is hidden says so once, with no headers")
    func allHiddenYieldsTheEmptyMessage() {
        // Arrange
        let items = [
            work(Real.citiID, Real.scholarlyID, .assignment, name: "Hidden Upload", isHidden: true),
            work(Real.moduleOneQuizID, Real.scholarlyID, .quiz, name: "Hidden Quiz", isHidden: true),
        ]

        // Act
        let rows = submenu(items, courseId: Real.scholarlyID)

        // Assert
        #expect(rows == [.message(Pinned.noAssignments)])
    }
}

@Suite("Submenu sections — click targets per kind")
struct SectionedClickTargetTests {

    @Test("an assignment row opens the dropbox template and a quiz row the quizzing one")
    func eachKindUsesItsOwnTemplate() throws {
        // Arrange — priority 1. The two templates differ in path AND parameter name
        // (`db=` vs `qi=`), and using the wrong one yields a real page for a
        // different entity.
        let items = [
            work(Real.citiID, Real.scholarlyID, .assignment, name: Real.citiName),
            work(Real.moduleOneQuizID, Real.scholarlyID, .quiz, name: Real.moduleOneQuizName),
        ]

        // Act
        let rows = submenu(items, courseId: Real.scholarlyID)
        let assignment = try #require(rows.assignments.first { $0.id == Real.citiID })
        let quiz = try #require(rows.assignments.first { $0.id == Real.moduleOneQuizID })

        // Assert — full literals, browser-verified.
        #expect(assignment.url.absoluteString == Pinned.citiURL)
        #expect(quiz.url.absoluteString == Pinned.moduleOneQuizURL)
    }

    @Test("a quiz never gets a db= or grpid parameter")
    func quizRowsCarryNoAssignmentParameters() throws {
        // Arrange / Act — the copy-paste failure: the assignment template applied to
        // a quiz id. It produces a syntactically fine dropbox URL for a folder that
        // does not exist.
        let rows = submenu(
            [work(Real.honorPledgeID, Real.civicsID, .quiz, name: "Honor Pledge")],
            courseId: Real.civicsID
        )
        let quiz = try #require(rows.assignments.first)

        // Assert
        #expect(!quiz.url.absoluteString.contains("db="))
        #expect(!quiz.url.absoluteString.contains("grpid"))
        #expect(quiz.url.absoluteString == Pinned.honorPledgeURL)
    }

    @Test("quizzes in different courses never share an ou")
    func quizzesDoNotCrossCourses() throws {
        // Arrange — the same quiz id would be ambiguous, so two different ids in two
        // different courses, translated separately as the menu does. A shared or
        // cached `ou` shows up here as a row pointing into the wrong course.
        let civicsRows = submenu(
            [work(Real.honorPledgeID, Real.civicsID, .quiz, name: "Honor Pledge")],
            courseId: Real.civicsID
        )
        let scholarlyRows = submenu(
            [work(Real.moduleOneQuizID, Real.scholarlyID, .quiz, name: Real.moduleOneQuizName)],
            courseId: Real.scholarlyID
        )

        // Act
        let civicsQuiz = try #require(civicsRows.assignments.first)
        let scholarlyQuiz = try #require(scholarlyRows.assignments.first)

        // Assert
        #expect(civicsQuiz.url.absoluteString.contains("ou=412690"))
        #expect(scholarlyQuiz.url.absoluteString.contains("ou=440703"))
        #expect(!civicsQuiz.url.absoluteString.contains("440703"))
        #expect(!scholarlyQuiz.url.absoluteString.contains("412690"))
    }

    @Test("ou comes from the course the submenu belongs to, not from the item")
    func ouComesFromTheSubmenusCourse() throws {
        // Arrange — an item deliberately stamped with the WRONG course, which is
        // exactly what a fan-out bug would produce. The submenu's own course id must
        // win, because that is the structural guarantee: a row in course A's submenu
        // cannot carry course B's id.
        let mislabelled = work(Real.honorPledgeID, 999_999, .quiz, name: "Honor Pledge")

        // Act
        let rows = submenu([mislabelled], courseId: Real.civicsID)
        let quiz = try #require(rows.assignments.first)

        // Assert
        #expect(quiz.url.absoluteString == Pinned.honorPledgeURL)
        #expect(!quiz.url.absoluteString.contains("999999"))
    }

    @Test("both kinds in one course route to their own ids, never a neighbour's")
    func idsDoNotDriftBetweenRows() throws {
        // Arrange — three quizzes and one assignment with non-adjacent ids, so an
        // index or zip bug yields a wrong number rather than a coincidentally right
        // one.
        let items = [
            work(Real.untitledID, Real.civicsID, .assignment, name: "Untitled"),
            work(Real.honorPledgeID, Real.civicsID, .quiz, name: "Honor Pledge"),
            work(Real.practiceQuizID, Real.civicsID, .quiz, name: "Practice Quiz"),
            work(Real.welcomeQuizID, Real.civicsID, .quiz, name: "Welcome Quiz"),
        ]

        // Act
        let rows = submenu(items, courseId: Real.civicsID)

        // Assert — every row's URL names its own id.
        try #require(rows.assignments.count == 4)
        for row in rows.assignments {
            let expectedParameter = row.id == Real.untitledID ? "db=\(row.id)" : "qi=\(row.id)"
            #expect(
                row.url.absoluteString.contains(expectedParameter),
                "row \(row.id) links to \(row.url.absoluteString)"
            )
        }
        #expect(rows.assignments.first { $0.id == Real.untitledID }?.url.absoluteString == Pinned.untitledURL)
    }
}

@Suite("Submenu sections — ordering, states and determinism")
struct SectionedStateTests {

    @Test("sorting happens within a section, so a sooner quiz does not jump the boundary")
    func sortingIsScopedToEachSection() {
        // Arrange — the quiz is due BEFORE the assignment. Sections are the outer
        // key, so it still renders under Quizzes, below the assignment.
        let soon = Date(timeIntervalSince1970: 1_772_341_140)   // 2026-03-01
        let later = Date(timeIntervalSince1970: 1_789_516_740)  // 2026-09-15
        let items = [
            work(Real.citiID, Real.scholarlyID, .assignment, name: "Later Upload", dueDate: later),
            work(Real.moduleOneQuizID, Real.scholarlyID, .quiz, name: "Sooner Quiz", dueDate: soon),
        ]

        // Act
        let rows = submenu(items, courseId: Real.scholarlyID)

        // Assert — the assignment section comes first despite the later deadline.
        #expect(rows.assignments.map(\.id) == [Real.citiID, Real.moduleOneQuizID])
    }

    @Test("dated items still precede undated ones inside a section")
    func datedFirstStillHoldsWithinASection() {
        // Arrange — the existing total order must survive the sectioning, applied
        // per section rather than abandoned.
        let due = Date(timeIntervalSince1970: 1_772_341_140)
        let items = [
            work(Real.honorPledgeID, Real.civicsID, .quiz, name: "Aardvark Quiz"),
            work(Real.welcomeQuizID, Real.civicsID, .quiz, name: "Zebra Quiz", dueDate: due),
        ]

        // Act
        let rows = submenu(items, courseId: Real.civicsID)

        // Assert — the dated "Zebra" outranks the undated "Aardvark".
        #expect(rows.assignments.map(\.id) == [Real.welcomeQuizID, Real.honorPledgeID])
    }

    @Test("a failure over both kinds keeps every row and appends one note at the end")
    func failureKeepsBothSectionsAndOneNote() {
        // Arrange — routine for this tenant: the session dies within hours.
        let items = [
            work(Real.citiID, Real.scholarlyID, .assignment, name: Real.citiName),
            work(Real.moduleOneQuizID, Real.scholarlyID, .quiz, name: Real.moduleOneQuizName),
        ]

        // Act
        let rows = AssignmentTranslation.submenu(
            state: .failed(lastKnown: items, error: .sessionExpired),
            courseId: Real.scholarlyID,
            now: Pinned.now, baseURL: Pinned.baseURL, timeZone: Pinned.utc
        )

        // Assert — header, assignment, header, quiz, separator, note.
        #expect(rows.count == 6)
        #expect(headers(rows) == [Pinned.assignmentsHeader, Pinned.quizzesHeader])
        #expect(rows[4] == .separator)
        #expect(rows[5] == .message(Pinned.refreshFailed))
        #expect(messages(rows) == [Pinned.refreshFailed])
    }

    @Test("neverFetched says No assignments and names neither kind")
    func neverFetchedNamesNoKind() {
        // Arrange / Act — with either kind possible but nothing fetched, the row
        // must not imply a section. A "Quizzes" or "Assignments" header here would
        // claim knowledge of what the course holds.
        let rows = AssignmentTranslation.submenu(
            state: .neverFetched, courseId: Real.civicsID,
            now: Pinned.now, baseURL: Pinned.baseURL, timeZone: Pinned.utc
        )

        // Assert
        #expect(rows == [.message(Pinned.noAssignments)])
        #expect(headers(rows).isEmpty)
    }

    @Test("shuffled input yields an identical model, so the GUI can skip rebuilding")
    func translationIsDeterministic() {
        // Arrange — `MenuModel`'s `Equatable` is what lets the app avoid rebuilding
        // an unchanged menu. Sectioning via a dictionary would reintroduce
        // nondeterminism unless both levels are explicitly ordered.
        let items = [
            work(Real.untitledID, Real.civicsID, .assignment, name: "Untitled"),
            work(Real.honorPledgeID, Real.civicsID, .quiz, name: "Honor Pledge"),
            work(Real.practiceQuizID, Real.civicsID, .quiz, name: "Practice Quiz"),
            work(Real.welcomeQuizID, Real.civicsID, .quiz, name: "Welcome Quiz"),
            work(1, Real.civicsID, .assignment, name: "Another Upload"),
        ]

        // Act
        let first = submenu(items, courseId: Real.civicsID)
        let second = submenu(items.shuffled(), courseId: Real.civicsID)

        // Assert — guard the count first, or two empty results would pass trivially.
        #expect(first.count == 7)
        #expect(first == second)
    }

    @Test("a whole-course model carries sectioned submenus through MenuTranslation")
    func sectionsSurviveTheWholeCourseTranslation() throws {
        // Arrange — the end of the chain: per-course states in, a `MenuModel` out.
        // The course carries a wide-open Access window so it is CURRENT at any
        // `now`: an undated course is hidden entirely under the 2026-08-24 user
        // decision, and a hidden course has no submenu to section.
        let civicsItems = [
            work(Real.untitledID, Real.civicsID, .assignment, name: "Untitled"),
            work(Real.honorPledgeID, Real.civicsID, .quiz, name: "Honor Pledge"),
        ]
        let courses = [
            Course(id: Real.civicsID, name: "Purdue Civics Knowledge Test",
                   code: "wl.nc.civics.test", role: "Learner", isActive: true,
                   homeUrl: nil,
                   startDate: "2000-01-01T00:00:00.000Z", endDate: "2999-01-01T00:00:00.000Z"),
        ]

        // Act
        let model = MenuTranslation.menu(
            courses: courses, lastFetch: Pinned.now, now: Pinned.now, baseURL: Pinned.baseURL,
            assignments: [Real.civicsID: .loaded(civicsItems)], timeZone: Pinned.utc
        )

        // Assert — since Intent 1 the whole-course translation no longer calls
        // the sectioned listing at all: the submenu is the add-forms (plus any
        // announcements), and `AssignmentTranslation.submenu` — everything the
        // rest of this suite pins — survives as the pure function it always
        // was, no longer joined here. What this end-of-chain test now pins is
        // exactly that: no section headers and no work rows leak through.
        let course = try #require(model.courses.first { $0.id == Real.civicsID })
        #expect(headers(course.submenu).isEmpty)
        #expect(course.submenu.assignments.isEmpty)
        #expect(course.submenu == AddItemKind.allCases.map {
            .addForm(AddItemFormRow(courseId: Real.civicsID, kind: $0))
        })
    }
}
