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

    /// A 28-cell strip written the way a strip is actually read: the days that
    /// carry work, by index, everything else empty. Cell 0 is today by definition
    /// of the positional strip, so the caller never restates it — and cannot seed
    /// it somewhere else by accident.
    private static func strip(_ tiers: [Int: CellTier]) -> [GraphCell] {
        (0..<28).map { GraphCell(tier: tiers[$0], isToday: $0 == 0) }
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
            ],
            // Work on today's cell — the outline has to survive a fill underneath it.
            graph: strip([0: .assignment, 1: .quiz, 3: .assignment, 5: .quiz])
        )),
        // Undated assignments — the shape of every assignment in the real tenant
        // today, and the case where a naive formatter ships the literal "nil".
        .course(CourseRow(
            id: 1_415_558, title: "Multivariate Calculus", subtitle: "MA 26100", url: url(1_415_558),
            submenu: [
                assignment(2_101, "Homework 1", course: 1_415_558),
                assignment(2_102, "Homework 2", course: 1_415_558),
                assignment(2_103, "Written Reflection on Vector Fields", course: 1_415_558),
            ],
            // An empty today cell, so the outline is exercised with no fill behind
            // it, and work on index 27 so the window's trailing edge is visible.
            // Index 9 is the "assignment and quiz on one day" case, already resolved
            // upstream to the higher tier — the stub shows the outcome, not the race.
            graph: strip([2: .quiz, 6: .assignment, 9: .quiz, 27: .assignment])
        )),
        // The empty state: a course fetched successfully with zero assignments.
        // Says so rather than opening onto a blank box.
        .course(CourseRow(
            id: 1_452_301, title: "Computer Graphics Technology", subtitle: "CGT 11800", url: url(1_452_301),
            submenu: [.message("No assignments")],
            // "Nothing due" drawn honestly: a full-width strip of empty cells. The
            // two courses below cover the other empty, where no strip is drawn at all.
            graph: strip([:])
        )),
        // Long title on purpose — the GUI should meet an awkward string before the
        // network hands it one. Real tenant max is 49 characters. No strip either:
        // the row must lay out with the graph absent, not with 28 empty cells.
        .course(CourseRow(id: 1_460_912, title: "Transformative Texts: Critical Thinking", subtitle: "SCLA 10100", url: url(1_460_912))),
        // No subtitle on purpose — `subtitle` is optional and must render cleanly nil.
        // Also no submenu and no strip, so the legacy directly-clickable row stays
        // demoable exactly as it was before either field existed.
        .course(CourseRow(id: 412_690, title: "Purdue Civics Knowledge Test", subtitle: nil, url: url(412_690))),
        .separator,
        .status("Updated just now"),
        .command(.refresh),
        .command(.quit),
    ])
}
