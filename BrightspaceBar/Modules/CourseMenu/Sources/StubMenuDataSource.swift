import Foundation

/// Seeded data so the GUI can be built, run, and demoed with no backend at all.
///
/// This is what phase 2 develops against. It is production code, not test-only: the
/// app is launchable against it, which is what makes "develop the frontend
/// independently" real rather than aspirational.
///
/// The shape mirrors genuine tenant data — real Purdue-style codes, a mix of terms,
/// and one deliberately long title — so the GUI meets realistic strings before it
/// ever meets the network.
public struct StubMenuDataSource: MenuDataSource {
    private let model: MenuModel

    public init(model: MenuModel = StubMenuDataSource.seeded) {
        self.model = model
    }

    public func currentMenu() async -> MenuModel { self.model }
    public func refresh() async -> MenuModel { self.model }

    private static func url(_ id: Int) -> URL {
        URL(string: "https://purdue.brightspace.com/d2l/home/\(id)")!
    }

    /// The deep-link shape proven against the live tenant: an assignment is
    /// addressed by its dropbox folder id (`db`) within its course (`ou`).
    private static func assignmentURL(folder: Int, course: Int) -> URL {
        URL(string:
            "https://purdue.brightspace.com/d2l/lms/dropbox/user/folder_submit_files.d2l"
            + "?db=\(folder)&grpid=0&ou=\(course)"
        )!
    }

    private static func assignment(
        _ id: Int, _ title: String, due: String? = nil, dueDate: Date? = nil, course: Int
    ) -> MenuRow {
        .assignment(AssignmentRow(
            id: id, title: title, subtitle: due, dueDate: dueDate,
            url: assignmentURL(folder: id, course: course)
        ))
    }

    public static let seeded = MenuModel(rows: [
        .sectionHeader("Fall 2026"),
        // Dated assignments, so the "name — due date" format is visible in the
        // running app even though no reachable real course has a due date yet.
        .course(CourseRow(
            id: 1_498_777, title: "Data Engineering", subtitle: "CS 17600", url: url(1_498_777),
            submenu: [
                assignment(2_001, "Project 1: ETL Pipeline", due: "Due Sep 12", dueDate: Date(timeIntervalSince1970: 1_789_516_800), course: 1_498_777),
                assignment(2_002, "Lab 3 Write-up", due: "Due Sep 19", dueDate: Date(timeIntervalSince1970: 1_790_121_600), course: 1_498_777),
            ]
        )),
        // Undated assignments — the shape of every assignment in the real tenant
        // today, and the case where a naive formatter ships the literal "nil".
        .course(CourseRow(
            id: 1_415_558, title: "Multivariate Calculus", subtitle: "MA 26100", url: url(1_415_558),
            submenu: [
                assignment(2_101, "Homework 1", course: 1_415_558),
                assignment(2_102, "Homework 2", course: 1_415_558),
                assignment(2_103, "Written Reflection on Vector Fields", course: 1_415_558),
            ]
        )),
        // The empty state: a course fetched successfully with zero assignments.
        // Says so rather than opening onto a blank box.
        .course(CourseRow(
            id: 1_452_301, title: "Computer Graphics Technology", subtitle: "CGT 11800", url: url(1_452_301),
            submenu: [.message("No assignments")]
        )),
        // Long title on purpose — the GUI should meet an awkward string before the
        // network hands it one. Real tenant max is 49 characters.
        .course(CourseRow(id: 1_460_912, title: "Transformative Texts: Critical Thinking", subtitle: "SCLA 10100", url: url(1_460_912))),
        // No subtitle on purpose — `subtitle` is optional and must render cleanly nil.
        // Also no submenu, so the legacy directly-clickable row stays demoable.
        .course(CourseRow(id: 412_690, title: "Purdue Civics Knowledge Test", subtitle: nil, url: url(412_690))),
        .separator,
        .status("Updated just now"),
        .command(.refresh),
        .command(.quit),
    ])
}
