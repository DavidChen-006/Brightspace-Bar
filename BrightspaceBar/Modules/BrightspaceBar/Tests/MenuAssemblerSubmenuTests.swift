import AppKit
import Foundation
import Testing

import BrightspaceBar
import CourseMenu

// ═════════════════════════════════════════════════════════════════════════════
// MenuAssembler — the assignment submenu.
//
// PRIORITIES (the 1–2 carrying 80% of the value):
//
//   1. CLICK-TARGET CORRECTNESS. Choosing assignment N must open assignment N.
//      This hazard is strictly WORSE than the course-level one already covered in
//      MenuAssemblerTests: there are now TWO levels of indexing, so an
//      implementation can resolve a submenu click against the top-level course
//      array and open a plausible-but-wrong page. The failure is invisible — the
//      menu looks perfect and sends you to someone else's homework.
//
//      The course-home escape hatch belongs to this priority too. AppKit makes an
//      item that owns a submenu non-actionable, so `CourseRow.url` becomes
//      unreachable by click the moment assignments appear. Without a replacement
//      row, adding this feature silently DELETES the ability to open a course.
//
//   2. NO SILENT STRUCTURE LOSS. Two symmetric failures:
//        - assignments present in the model but no submenu rendered → the whole
//          feature disappears and nothing else in the app notices;
//        - an EMPTY submenu attached to a legacy course → a hover arrow leading to
//          a blank box, AND the course's own click is killed. That would break
//          every course row that exists today.
//
// CULLED, deliberately: visual appearance, hover-open timing, submenu placement,
// keyboard navigation (all AppKit's, free, and the reason we use plain
// NSMenuItem), NSStatusItem (needs a UI session; covered by the launch smoke
// test), and performance (20 rows is nothing).
//
// SCOPE: all Google-small. In-process AppKit object graphs; no I/O, no network,
// no clock, no sleeping. Measured: NSMenu construction works with NSApp nil.
// ═════════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────
// PINNED FORMAT AND STRUCTURE — the builder implements exactly this.
//
// Assignment row title:
//
//   subtitle present │ "Report on your PURC Experience. — Due Mar 1"
//   subtitle nil     │ "Untitled"
//
// Separator is SPACE + EM DASH (U+2014) + SPACE, matching the course rows.
//
// NOTE the deliberate INVERSION versus courses. A course renders
// "CS 17600 — Data Engineering" (subtitle FIRST) because students search by
// course code. An assignment renders NAME first, due date second, because the
// name is the identity you scan for and the date is metadata. Leading with the
// date would also produce a ragged column, since almost every real assignment
// has no due date at all.
//
// The GUI must render `subtitle` VERBATIM and must never format `dueDate`
// itself — date formatting is policy and lives in the pure backend layer.
//
// Submenu structure, for a course whose `submenu` is non-empty:
//
//   [0] "Open Course Home"   → opens CourseRow.url   (the escape hatch)
//   [1] separator
//   [2…] one item per row in CourseRow.submenu, in model order
//
// A course whose `submenu` is EMPTY gets no NSMenu at all — it stays a plain,
// directly clickable row exactly as before this feature existed.
// ─────────────────────────────────────────────────────────────────────────────

private enum Expected {
    static let separator = " — "
    static let courseHome = "Open Course Home"

    /// Independent source of truth. Written as plain concatenation rather than by
    /// calling production code, so a bug in the implementation's formatter cannot
    /// define its own expected value.
    static func assignment(name: String, due: String?) -> String {
        guard let due else { return name }
        return name + self.separator + due
    }

    static func course(subtitle: String?, title: String) -> String {
        guard let subtitle else { return title }
        return subtitle + self.separator + title
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Builders. Local to this file: SPM test targets are separate modules, so the
// support types in Tests/CourseMenuTests are unreachable from here.
// ─────────────────────────────────────────────────────────────────────────────

private enum Build {
    static let baseURL = "https://purdue.brightspace.com"

    static func courseURL(_ id: Int) -> URL {
        URL(string: "\(self.baseURL)/d2l/home/\(id)")!
    }

    /// Experiment 7's proven deep-link template. Written out literally here so the
    /// expected click target is independent of however the backend builds it.
    static func assignmentURL(folder: Int, course: Int) -> URL {
        URL(string:
            "\(self.baseURL)/d2l/lms/dropbox/user/folder_submit_files.d2l"
            + "?db=\(folder)&grpid=0&ou=\(course)"
        )!
    }

    static func assignment(
        id: Int,
        title: String,
        due: String? = nil,
        dueDate: Date? = nil,
        course: Int
    ) -> AssignmentRow {
        AssignmentRow(
            id: id, title: title, subtitle: due, dueDate: dueDate,
            url: self.assignmentURL(folder: id, course: course)
        )
    }

    static func course(
        id: Int,
        title: String,
        subtitle: String? = nil,
        submenu: [MenuRow]
    ) -> CourseRow {
        CourseRow(id: id, title: title, subtitle: subtitle, url: self.courseURL(id), submenu: submenu)
    }

    // ── The real tenant data (the two courses with live API access) ───────────
    //
    // Both carry untermed codes, so both render with a nil subtitle — which is
    // also why their titles are used bare when looking rows up.

    static let scholarlyID = 440_703
    static let scholarlyTitle = "Scholarly Project Milestones"

    /// The three genuine dropbox folders in 440703. All undated, as measured.
    static let scholarlyAssignments: [AssignmentRow] = [
        Build.assignment(id: 445_296, title: "Upload your CITI Certificate to Complete Module 2", course: Build.scholarlyID),
        Build.assignment(id: 445_297, title: "Report on your PURC Experience.", course: Build.scholarlyID),
        Build.assignment(id: 529_524, title: "Getting Started on Scholarly Project Ideation", course: Build.scholarlyID),
    ]

    static var scholarly: CourseRow {
        Build.course(
            id: Build.scholarlyID, title: Build.scholarlyTitle,
            submenu: Build.scholarlyAssignments.map { MenuRow.assignment($0) }
        )
    }

    static let civicsID = 412_690
    static let civicsTitle = "Purdue Civics Knowledge Test"

    /// The single genuine folder in 412690 — D2L really does call it "Untitled".
    static let civicsAssignment = Build.assignment(id: 648_911, title: "Untitled", course: Build.civicsID)

    static var civics: CourseRow {
        Build.course(
            id: Build.civicsID, title: Build.civicsTitle,
            submenu: [.assignment(Build.civicsAssignment)]
        )
    }

    /// The hazard shape: two submenu-bearing courses buried among non-course rows,
    /// exactly as the real model looks. Item index and course index diverge here.
    static var interleaved: MenuModel {
        MenuModel(rows: [
            .sectionHeader("Fall 2026"),
            .course(Build.scholarly),
            .separator,
            .sectionHeader("Other"),
            .course(Build.civics),
            .separator,
            .status("Updated just now"),
            .command(.refresh),
            .command(.quit),
        ])
    }

    /// `@MainActor` because `MenuAssembler`'s initializer is main-actor isolated.
    @MainActor
    static func assembler(
        opener: FakeURLOpener = FakeURLOpener(),
        recorder: CommandRecorder = CommandRecorder()
    ) -> MenuAssembler {
        MenuAssembler(opener: opener) { command in recorder.record(command) }
    }
}

/// One (course, assignment) pair, for proving a click in course A cannot open an
/// assignment belonging to course B.
private struct CrossCourseCase: Sendable, CustomStringConvertible {
    let courseTitle: String
    let assignment: AssignmentRow
    var description: String { "\(self.assignment.title) under \(self.courseTitle)" }

    static let all: [CrossCourseCase] = [
        CrossCourseCase(courseTitle: Build.scholarlyTitle, assignment: Build.scholarlyAssignments[0]),
        CrossCourseCase(courseTitle: Build.scholarlyTitle, assignment: Build.scholarlyAssignments[2]),
        CrossCourseCase(courseTitle: Build.civicsTitle, assignment: Build.civicsAssignment),
    ]
}

// ─────────────────────────────────────────────────────────────────────────────
// Reaching into a submenu. `#require` before use, because an absent submenu must
// fail this one test rather than crash the process on a force-unwrap.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
private func submenu(
    ofCourseTitled title: String,
    in menu: NSMenu,
    _ sourceLocation: SourceLocation = #_sourceLocation
) throws -> NSMenu {
    let course = try item(titled: title, in: menu, sourceLocation)
    return try #require(
        course.submenu,
        "course row '\(title)' has no submenu, so its assignments are unreachable",
        sourceLocation: sourceLocation
    )
}

// ═════════════════════════════════════════════════════════════════════════════
// PRIORITY 2 — Structure: the submenu exists, holds everything, and leaks nothing
// ═════════════════════════════════════════════════════════════════════════════

@MainActor
@Suite("MenuAssembler — submenu structure")
struct MenuAssemblerSubmenuStructureTests {

    @Test("a course with assignments gets a submenu")
    func courseWithAssignmentsGetsASubmenu() throws {
        // Arrange
        let assembler = Build.assembler()

        // Act
        let menu = assembler.assemble(MenuModel(rows: [.course(Build.scholarly)]))

        // Assert
        let row = try #require(menu.items.first)
        #expect(row.submenu != nil, "assignments were in the model but no submenu was built")
    }

    /// Legacy protection, and the reason `submenu` defaults to empty. An empty
    /// NSMenu renders as a hover arrow onto a blank box AND makes the parent item
    /// non-actionable — so this would silently break every course row shipping today.
    @Test("a course with no assignments has no submenu and stays directly clickable")
    func courseWithoutAssignmentsHasNoSubmenu() throws {
        // Arrange
        let assembler = Build.assembler()
        let course = CourseRow(
            id: Build.civicsID, title: Build.civicsTitle, url: Build.courseURL(Build.civicsID)
        )

        // Act
        let menu = assembler.assemble(MenuModel(rows: [.course(course)]))

        // Assert
        let row = try #require(menu.items.first)
        #expect(row.submenu == nil, "an empty submenu was attached, which kills the course's own click")
        #expect(row.action != nil, "a course without assignments must remain directly clickable")
    }

    @Test("every assignment renders one submenu item, in model order, after the course-home row")
    func everyAssignmentRendersOneItemInOrder() throws {
        // Arrange
        let assembler = Build.assembler()
        let menu = assembler.assemble(MenuModel(rows: [.course(Build.scholarly)]))

        // Act
        let sub = try submenu(ofCourseTitled: Build.scholarlyTitle, in: menu)

        // Assert — the pinned shape. `#require` before positional access: indexing
        // NSMenu.items past the end raises an NSException that aborts the whole run.
        try #require(sub.items.count == 2 + Build.scholarlyAssignments.count)
        #expect(sub.items[0].title == Expected.courseHome)
        #expect(sub.items[1].isSeparatorItem)
        #expect(
            sub.items.dropFirst(2).map(\.title)
                == Build.scholarlyAssignments.map { Expected.assignment(name: $0.title, due: $0.subtitle) }
        )
    }

    @Test("the course-home row is first and the separator second")
    func courseHomeRowLeadsTheSubmenu() throws {
        // Arrange
        let assembler = Build.assembler()
        let menu = assembler.assemble(MenuModel(rows: [.course(Build.civics)]))

        // Act
        let sub = try submenu(ofCourseTitled: Build.civicsTitle, in: menu)

        // Assert
        try #require(sub.items.count >= 2)
        #expect(sub.items[0].title == Expected.courseHome)
        #expect(sub.items[0].action != nil, "the escape hatch carries no action, so the course is unreachable")
        #expect(sub.items[1].isSeparatorItem)
    }

    @Test("assignments do not leak into the top-level menu")
    func assignmentsDoNotLeakToTopLevel() throws {
        // Arrange
        let assembler = Build.assembler()
        let model = MenuModel(rows: [.course(Build.scholarly), .course(Build.civics)])

        // Act
        let menu = assembler.assemble(model)

        // Assert — one item per top-level row and nothing else.
        #expect(menu.items.count == model.rows.count)
        #expect(menu.items.map(\.title) == [Build.scholarlyTitle, Build.civicsTitle])
    }

    /// `.message` inside a submenu is how "No assignments" is said. It must be as
    /// inert as its top-level counterpart: `action == nil` is load-bearing, because
    /// an actionable row wired to the assignment action but carrying no assignment
    /// would open garbage.
    @Test("a message row inside a submenu is neither enabled nor actionable")
    func messageRowInASubmenuIsInert() throws {
        // Arrange
        let assembler = Build.assembler()
        let course = Build.course(
            id: Build.civicsID, title: Build.civicsTitle, submenu: [.message("No assignments")]
        )
        let menu = assembler.assemble(MenuModel(rows: [.course(course)]))

        // Act
        let sub = try submenu(ofCourseTitled: Build.civicsTitle, in: menu)

        // Assert
        let row = try item(titled: "No assignments", in: sub)
        #expect(row.action == nil, "the empty-state message can be activated")
        #expect(row.isEnabled == false, "the empty-state message looks clickable")
    }

    @Test("five courses with four assignments each assemble without truncation")
    func realisticLoadAssemblesFully() throws {
        // Arrange — a plausible full-time schedule, larger than either real course.
        let assembler = Build.assembler()
        let courses = Load.courses

        // Act
        let menu = assembler.assemble(MenuModel(rows: courses.map { MenuRow.course($0) }))

        // Assert
        try #require(menu.items.count == courses.count)
        for (index, course) in courses.enumerated() {
            let sub = try #require(menu.items[index].submenu, "course \(course.title) lost its submenu")
            #expect(sub.items.count == 2 + course.submenu.assignments.count)
        }
    }
}

/// A realistic multi-course load, built once so the structure and routing tests
/// make claims about the same world.
private enum Load {
    static let courses: [CourseRow] = (1...5).map { course in
        let id = course * 1_000
        return Build.course(
            id: id,
            title: "Course \(course)",
            subtitle: "C \(course)",
            submenu: (1...4).map { assignment in
                MenuRow.assignment(
                    Build.assignment(id: id + assignment, title: "Assignment \(course).\(assignment)", course: id)
                )
            }
        )
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// PRIORITY 2 — Rendering: the due date shows when present, and never lies
// ═════════════════════════════════════════════════════════════════════════════

@MainActor
@Suite("MenuAssembler — submenu rendering")
struct MenuAssemblerSubmenuRenderingTests {

    /// Constructed rather than taken from real data: all four genuine assignments
    /// are undated, so this is the only way to exercise the with-date path.
    private static let dated = Build.assignment(
        id: 445_297,
        title: "Report on your PURC Experience.",
        due: "Due Mar 1",
        dueDate: Date(timeIntervalSince1970: 1_772_323_200),
        course: Build.scholarlyID
    )

    @Test("an assignment with a due date renders the name then the date")
    func datedAssignmentRendersNameThenDate() throws {
        // Arrange
        let assembler = Build.assembler()
        let course = Build.course(
            id: Build.scholarlyID, title: Build.scholarlyTitle, submenu: [.assignment(Self.dated)]
        )

        // Act
        let menu = assembler.assemble(MenuModel(rows: [.course(course)]))

        // Assert — literal expected value, written independently of the code.
        let sub = try submenu(ofCourseTitled: Build.scholarlyTitle, in: menu)
        let titles = sub.items.map(\.title)
        #expect(titles.contains("Report on your PURC Experience. — Due Mar 1"))
    }

    /// The GUI renders `subtitle` verbatim; it must never format `dueDate` itself,
    /// because date formatting is policy and belongs in the pure backend layer.
    @Test("the raw due date never reaches the row title")
    func rawDueDateIsNotFormattedByTheView() throws {
        // Arrange
        let assembler = Build.assembler()
        let course = Build.course(
            id: Build.scholarlyID, title: Build.scholarlyTitle, submenu: [.assignment(Self.dated)]
        )
        let menu = assembler.assemble(MenuModel(rows: [.course(course)]))

        // Act
        let sub = try submenu(ofCourseTitled: Build.scholarlyTitle, in: menu)

        // Assert — no ISO date, no year, no epoch seconds anywhere in the submenu.
        let joined = sub.items.map(\.title).joined(separator: "|")
        #expect(!joined.contains("2026"), "the view formatted dueDate instead of rendering subtitle")
        #expect(!joined.contains("1772323200"), "raw epoch seconds leaked into a row title")
        #expect(!joined.contains("+0000"), "a Date description leaked into a row title")
    }

    /// The common case: every real assignment is undated. The classic bug is
    /// `"\(name) — \(subtitle)"` on a nil optional, which ships the literal "nil".
    @Test("an undated assignment renders the bare name")
    func undatedAssignmentRendersBareName() throws {
        // Arrange
        let assembler = Build.assembler()

        // Act
        let menu = assembler.assemble(MenuModel(rows: [.course(Build.civics)]))

        // Assert
        let sub = try submenu(ofCourseTitled: Build.civicsTitle, in: menu)
        let row = try item(titled: "Untitled", in: sub)
        #expect(row.title == "Untitled")
        #expect(!row.title.contains("nil"), "interpolated a nil optional into the row title")
        #expect(!row.title.contains(Expected.separator), "left a dangling separator with no due date")
        #expect(!row.title.contains("1970"), "rendered an epoch date for an assignment with no due date")
    }

    @Test("assignment rows are enabled and carry an action")
    func assignmentRowsAreActionable() throws {
        // Arrange
        let assembler = Build.assembler()
        let menu = assembler.assemble(MenuModel(rows: [.course(Build.scholarly)]))

        // Act
        let sub = try submenu(ofCourseTitled: Build.scholarlyTitle, in: menu)

        // Assert — count guard first, else the loop passes vacuously.
        let assignmentRows = Array(sub.items.dropFirst(2))
        try #require(assignmentRows.count == Build.scholarlyAssignments.count)
        for row in assignmentRows {
            #expect(row.action != nil, "assignment row '\(row.title)' has no action")
            #expect(row.isEnabled, "assignment row '\(row.title)' is disabled")
        }
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// PRIORITY 1 — Click-target correctness
// ═════════════════════════════════════════════════════════════════════════════

@MainActor
@Suite("MenuAssembler — submenu click routing")
struct MenuAssemblerSubmenuRoutingTests {

    @Test("clicking an assignment opens that assignment's URL")
    func clickingAnAssignmentOpensItsURL() throws {
        // Arrange
        let opener = FakeURLOpener()
        let assembler = Build.assembler(opener: opener)
        let menu = assembler.assemble(MenuModel(rows: [.course(Build.scholarly)]))
        let sub = try submenu(ofCourseTitled: Build.scholarlyTitle, in: menu)
        let target = Build.scholarlyAssignments[1]
        let row = try item(titled: Expected.assignment(name: target.title, due: target.subtitle), in: sub)

        // Act
        try click(row)

        // Assert
        #expect(opener.opened == [target.url])
    }

    @Test("clicking an assignment opens exactly one URL")
    func clickingAnAssignmentOpensExactlyOneURL() throws {
        // Arrange
        let opener = FakeURLOpener()
        let assembler = Build.assembler(opener: opener)
        let menu = assembler.assemble(MenuModel(rows: [.course(Build.scholarly)]))
        let sub = try submenu(ofCourseTitled: Build.scholarlyTitle, in: menu)
        let first = Build.scholarlyAssignments[0]
        let row = try item(titled: Expected.assignment(name: first.title, due: first.subtitle), in: sub)

        // Act
        try click(row)

        // Assert — not zero (silently dropped) and not two (double dispatch)
        #expect(opener.openedCount == 1)
    }

    /// THE off-by-one killer. Every assignment is clicked in a FRESH menu so a
    /// stale recorder cannot mask a misroute, and all three are checked rather
    /// than one. The three ids are distinct and non-sequential in position, so a
    /// shifted index yields a genuinely different URL rather than a lucky match.
    @Test("each assignment opens its own URL, never a neighbour", arguments: [0, 1, 2])
    func eachAssignmentOpensItsOwnURL(_ index: Int) throws {
        // Arrange
        let opener = FakeURLOpener()
        let assembler = Build.assembler(opener: opener)
        let menu = assembler.assemble(MenuModel(rows: [.course(Build.scholarly)]))
        let sub = try submenu(ofCourseTitled: Build.scholarlyTitle, in: menu)
        let expected = Build.scholarlyAssignments[index]
        let row = try item(titled: Expected.assignment(name: expected.title, due: expected.subtitle), in: sub)

        // Act
        try click(row)

        // Assert
        #expect(opener.opened == [expected.url])
    }

    /// The genuinely NEW hazard this feature introduces. With two submenu-bearing
    /// courses in one menu, an implementation that resolves a submenu click against
    /// the top-level course list — or that shares one representedObject per course —
    /// opens the wrong course's assignment. Both `db=` and `ou=` must match.
    @Test("an assignment in one course never opens another course's assignment", arguments: CrossCourseCase.all)
    fileprivate func assignmentsDoNotCrossCourses(_ testCase: CrossCourseCase) throws {
        // Arrange
        let opener = FakeURLOpener()
        let assembler = Build.assembler(opener: opener)
        let menu = assembler.assemble(MenuModel(rows: [.course(Build.scholarly), .course(Build.civics)]))
        let sub = try submenu(ofCourseTitled: testCase.courseTitle, in: menu)
        let expected = testCase.assignment
        let row = try item(titled: Expected.assignment(name: expected.title, due: expected.subtitle), in: sub)

        // Act
        try click(row)

        // Assert
        #expect(opener.opened == [expected.url])
    }

    /// The escape hatch, and the reason it exists: AppKit will not deliver a click
    /// to an item that owns a submenu, so without this row `CourseRow.url` is dead.
    @Test("the course-home row opens the course's own URL")
    func courseHomeRowOpensTheCourseURL() throws {
        // Arrange
        let opener = FakeURLOpener()
        let assembler = Build.assembler(opener: opener)
        let menu = assembler.assemble(MenuModel(rows: [.course(Build.scholarly)]))
        let sub = try submenu(ofCourseTitled: Build.scholarlyTitle, in: menu)
        let row = try item(titled: Expected.courseHome, in: sub)

        // Act
        try click(row)

        // Assert — the course URL, not an assignment deep link.
        #expect(opener.opened == [Build.courseURL(Build.scholarlyID)])
    }

    @Test("an undated assignment is still clickable")
    func undatedAssignmentIsStillClickable() throws {
        // Arrange
        let opener = FakeURLOpener()
        let assembler = Build.assembler(opener: opener)
        let menu = assembler.assemble(MenuModel(rows: [.course(Build.civics)]))
        let sub = try submenu(ofCourseTitled: Build.civicsTitle, in: menu)
        let row = try item(titled: "Untitled", in: sub)

        // Act
        try click(row)

        // Assert
        #expect(opener.opened == [Build.civicsAssignment.url])
    }

    @Test("clicking an assignment does not fire a command")
    func clickingAnAssignmentFiresNoCommand() throws {
        // Arrange
        let recorder = CommandRecorder()
        let assembler = Build.assembler(recorder: recorder)
        let menu = assembler.assemble(Build.interleaved)
        let sub = try submenu(ofCourseTitled: Build.scholarlyTitle, in: menu)
        let first = Build.scholarlyAssignments[0]
        let row = try item(titled: Expected.assignment(name: first.title, due: first.subtitle), in: sub)

        // Act
        try click(row)

        // Assert
        #expect(recorder.received.isEmpty)
    }

    /// The real-world model shape: submenu-bearing courses interleaved with
    /// headers, separators, a status line and commands, so top-level item index no
    /// longer equals course index.
    @Test("submenu routing survives interleaved top-level rows", arguments: [0, 1, 2])
    func routingSurvivesInterleavedRows(_ index: Int) throws {
        // Arrange
        let opener = FakeURLOpener()
        let assembler = Build.assembler(opener: opener)
        let menu = assembler.assemble(Build.interleaved)
        let sub = try submenu(ofCourseTitled: Build.scholarlyTitle, in: menu)
        let expected = Build.scholarlyAssignments[index]
        let row = try item(titled: Expected.assignment(name: expected.title, due: expected.subtitle), in: sub)

        // Act
        try click(row)

        // Assert
        #expect(opener.opened == [expected.url])
    }

    @Test("every assignment in a realistic load routes to its own URL")
    func realisticLoadRoutesCorrectly() throws {
        // Arrange
        let opener = FakeURLOpener()
        let assembler = Build.assembler(opener: opener)
        let courses = Load.courses
        let menu = assembler.assemble(MenuModel(rows: courses.map { MenuRow.course($0) }))
        try #require(menu.items.count == courses.count)

        // Act — click every assignment in every course, in order.
        for index in courses.indices {
            let sub = try #require(menu.items[index].submenu)
            for row in sub.items.dropFirst(2) { try click(row) }
        }

        // Assert — 20 opens, each to its own deep link, order preserved.
        let expected = courses.flatMap { $0.submenu.assignments.map(\.url) }
        try #require(expected.count == 20)
        #expect(opener.opened == expected)
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// Invariants
// ═════════════════════════════════════════════════════════════════════════════

@MainActor
@Suite("MenuAssembler — submenu invariants")
struct MenuAssemblerSubmenuInvariantTests {

    /// Assembling twice must not depend on hidden mutable state. Compares the
    /// observable shape of both menus, submenus included, rather than identity.
    @Test("assembling the same model twice yields structurally equal submenus")
    func submenuAssemblyIsDeterministic() throws {
        // Arrange
        let assembler = Build.assembler()
        let model = Build.interleaved

        // Act
        let first = assembler.assemble(model)
        let second = assembler.assemble(model)

        // Assert — the guard matters: two menus that are both empty are also
        // "structurally equal", so without it this cannot tell a correct assembler
        // from one that always returns nothing.
        try #require(first.items.count == model.rows.count)
        try #require(first.items.contains { $0.submenu != nil })

        let shape = { (menu: NSMenu) in
            menu.items.flatMap { item -> [[String]] in
                let own = [[
                    item.title, "\(item.isSeparatorItem)", "\(item.isEnabled)",
                    "\(item.action != nil)", "hasSubmenu:\(item.submenu != nil)",
                ]]
                let children = (item.submenu?.items ?? []).map {
                    ["  " + $0.title, "\($0.isSeparatorItem)", "\($0.isEnabled)", "\($0.action != nil)"]
                }
                return own + children
            }
        }
        #expect(shape(first) == shape(second))
    }

    /// An NSMenuItem belongs to exactly one NSMenu, so an item reused between a
    /// rebuild's submenus would silently detach from the previous menu.
    @Test("a rebuilt submenu does not share item instances with the previous one")
    func rebuiltSubmenuDoesNotShareItems() throws {
        // Arrange
        let assembler = Build.assembler()
        let model = MenuModel(rows: [.course(Build.scholarly)])

        // Act
        let first = assembler.assemble(model)
        let second = assembler.assemble(model)

        // Assert — count guards first, else the loop is satisfied trivially.
        let firstSub = try #require(first.items.first?.submenu)
        let secondSub = try #require(second.items.first?.submenu)
        try #require(firstSub.items.count == 2 + Build.scholarlyAssignments.count)
        try #require(secondSub.items.count == firstSub.items.count)
        for item in firstSub.items {
            #expect(
                !secondSub.items.contains { $0 === item },
                "submenu item '\(item.title)' is shared between rebuilds"
            )
        }
    }
}
