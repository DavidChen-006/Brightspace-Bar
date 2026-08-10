import Foundation
import Testing
import CourseMenu

// ═════════════════════════════════════════════════════════════════════════════
// CHALLENGE 1 — the interface, verified.
//
// This suite makes exactly one claim: the three contract fields the vertical
// depends on (assignment NAME, DUE DATE, URL) survive a trip through the
// interface intact, nested inside a course's submenu.
//
// It is deliberately not a behaviour suite — no fetching, no translation, no
// rendering. Those belong to the two spikes. Its job is to prove that whatever
// the backend puts in, the GUI can get out, before either side is built.
//
// SCOPE: small. Plain values, no I/O.
// ═════════════════════════════════════════════════════════════════════════════

private let base = URL(string: "https://purdue.brightspace.com")!

/// The real deep-link shape proven by experiment 7, for one of the four genuine
/// assignments in the reachable courses (Scholarly Project Milestones, 440703).
private func realDeepLink(folderId: Int, orgUnitId: Int) -> URL {
    URL(string:
        "\(base.absoluteString)/d2l/lms/dropbox/user/folder_submit_files.d2l"
        + "?db=\(folderId)&grpid=0&ou=\(orgUnitId)"
    )!
}

@Suite("The assignment interface carries name, due date and URL")
struct AssignmentInterfaceTests {

    @Test("all three contract fields survive nesting in a course submenu")
    func contractFieldsPassThrough() throws {
        // Arrange — a real assignment id and name, with a due date the live data
        // does not have, so the date path is exercised even though every current
        // assignment is undated.
        let due = Date(timeIntervalSince1970: 1_772_323_200)  // 2026-03-01T00:00:00Z
        let assignment = AssignmentRow(
            id: 445_296,
            title: "Upload your CITI Certificate to Complete Module 2",
            subtitle: "Due Mar 1",
            dueDate: due,
            url: realDeepLink(folderId: 445_296, orgUnitId: 440_703)
        )
        let course = CourseRow(
            id: 440_703,
            title: "Scholarly Project Milestones",
            url: base.appending(path: "d2l/home/440703"),
            submenu: [.assignment(assignment)]
        )

        // Act — the trip the real data will make: row → model → back out.
        let model = MenuModel(rows: [.course(course)])
        let readBack = try #require(model.courses.first)
        let carried = try #require(readBack.submenu.assignments.first)

        // Assert — the three essential fields, plus the id the URL derives from.
        #expect(carried.title == "Upload your CITI Certificate to Complete Module 2")
        #expect(carried.dueDate == due)
        #expect(carried.subtitle == "Due Mar 1")
        #expect(carried.url.absoluteString.contains("db=445296"))
        #expect(carried.url.absoluteString.contains("ou=440703"))
        #expect(carried.id == 445_296)
    }

    @Test("a course with no submenu is unchanged from before the interface existed")
    func emptySubmenuIsTheDefault() {
        // Arrange / Act — the pre-existing initializer call shape, untouched.
        let course = CourseRow(id: 412_690, title: "Civics", url: base)

        // Assert — no submenu means the course stays a plain clickable row, which
        // is what keeps every pre-assignment test valid.
        #expect(course.submenu.isEmpty)
    }

    @Test("undated assignments carry nil, not a placeholder string")
    func undatedAssignmentsAreHonest() {
        // Arrange — the actual state of all four reachable assignments: D2L sent
        // no DueDate. The interface must represent that as absence, so the GUI can
        // omit the line rather than print "Due nil" or an epoch date.
        let assignment = AssignmentRow(
            id: 648_911,
            title: "Untitled",
            url: realDeepLink(folderId: 648_911, orgUnitId: 412_690)
        )

        // Assert
        #expect(assignment.dueDate == nil)
        #expect(assignment.subtitle == nil)
    }

    @Test("submenu rows can carry prose, so empty and stale states are expressible")
    func submenuCanHoldMessages() throws {
        // Arrange — the reason `submenu` is [MenuRow] and not [AssignmentRow]:
        // "no assignments" and "couldn't refresh" are rows the translation layer
        // must be able to emit without the GUI inventing them.
        let course = CourseRow(
            id: 412_690, title: "Civics", url: base,
            submenu: [.message("No assignments")]
        )

        // Act / Assert
        #expect(course.submenu.assignments.isEmpty)
        #expect(course.submenu == [.message("No assignments")])
    }

    @Test("two identical models compare equal so the GUI can skip rebuilding")
    func equatableSurvivesNesting() {
        // Arrange — Equatable is load-bearing: the app only rebuilds the menu when
        // the model changes. A nested submenu must not break that.
        let build = {
            MenuModel(rows: [.course(CourseRow(
                id: 440_703, title: "Scholarly Project Milestones", url: base,
                submenu: [.assignment(AssignmentRow(
                    id: 445_297, title: "Report on your PURC Experience.",
                    url: self.realDeepLinkStatic(445_297, 440_703)
                ))]
            ))])
        }

        // Act / Assert
        #expect(build() == build())
    }

    private func realDeepLinkStatic(_ folderId: Int, _ orgUnitId: Int) -> URL {
        realDeepLink(folderId: folderId, orgUnitId: orgUnitId)
    }
}
