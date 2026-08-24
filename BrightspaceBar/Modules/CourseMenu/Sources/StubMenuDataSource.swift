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

    /// A 112-cell window written the way a window is actually read: the days that
    /// carry work, by index, everything else empty. The window opens on the Sunday
    /// of today's week, so today is cell 2 (a Tuesday) for every seed — the caller
    /// never restates it, and cannot seed it somewhere else by accident.
    private static func strip(_ tiers: [Int: CellTier]) -> [GraphCell] {
        (0..<112).map { GraphCell(tier: tiers[$0], isToday: $0 == 2) }
    }

    /// The headings the seeded window implies, transcribed from a calendar. That
    /// window opens Sun Feb 8 2026 — the pinned `now` is Tue Feb 10, which is why
    /// `isToday` sits at cell 2 — and runs to Sat May 30, so Mar 1 falls in
    /// column 3, Apr 1 in column 7, May 1 in column 11, and June is out.
    ///
    /// The same headings on every course, because they describe the WINDOW and
    /// not a course: a stub that varied them would demo a menu whose grids
    /// disagree about what month it is. Literals, never `Date()`, so a screenshot
    /// taken next month shows the same grid as today's.
    private static let months: [String?] = [
        "Feb", nil, nil, "Mar", nil, nil, nil, "Apr", nil, nil, nil, "May", nil, nil, nil, nil,
    ]

    private static func assignment(
        _ id: Int, _ title: String, due: String? = nil, dueDate: Date? = nil, course: Int
    ) -> MenuRow {
        .assignment(AssignmentRow(
            id: id, title: title, subtitle: due, dueDate: dueDate,
            url: assignmentURL(folder: id, course: course)
        ))
    }

    /// The three add-forms every course submenu leads with (Intent 1), seeded
    /// exactly as `MenuTranslation` emits them: one per `AddItemKind`, in
    /// `allCases` order, stamped with this course's id.
    private static func addForms(course: Int) -> [MenuRow] {
        AddItemKind.allCases.map { .addForm(AddItemFormRow(courseId: course, kind: $0)) }
    }

    /// Every announcement in a course opens the same page — its announcements
    /// list. D2L offers no per-item deep link worth trusting, so one destination
    /// per course is the design rather than a stub simplification.
    private static func announcementURL(course: Int) -> URL {
        URL(string: "https://purdue.brightspace.com/d2l/lms/news/main.d2l?ou=\(course)")!
    }

    /// Posting dates are seeded RELATIVE to launch, unlike the fixed assignment
    /// dates above. An announcements section is a recency window — the translation
    /// layer shows only the last 30 days — so a stub pinned to literal instants
    /// would demo an empty section a month after it was written, which is the one
    /// state the GUI already handles by drawing nothing.
    ///
    /// The rendered subtitle is derived from that same instant rather than written
    /// as a literal, so a moving date and a fixed string can never disagree.
    private static func announcement(
        _ id: Int, _ title: String, daysAgo: Int, course: Int
    ) -> MenuRow {
        let posted = Date().addingTimeInterval(-Double(daysAgo) * 24 * 60 * 60)
        return .announcement(AnnouncementRow(
            id: id, title: title, subtitle: postedLabel(posted), date: posted,
            url: announcementURL(course: course)
        ))
    }

    /// The same `"MMM d"` shape `AnnouncementTranslation` produces, restated here
    /// because `CourseMenu` is the contract module and depends on nothing but
    /// Foundation — it cannot see the translation layer. A fixed table rather than
    /// a `DateFormatter` for the same reason that layer uses one: the abbreviation
    /// must not change with the machine's locale.
    ///
    /// Optional, never `""`: an empty subtitle renders as a dangling separator in
    /// the GUI's "title — subtitle" join, so the unreachable branch drops the line
    /// rather than emitting one with nothing in it.
    private static func postedLabel(_ date: Date) -> String? {
        let months = [
            "Jan", "Feb", "Mar", "Apr", "May", "Jun",
            "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        ]
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let parts = calendar.dateComponents([.month, .day], from: date)
        guard let month = parts.month, let day = parts.day, months.indices.contains(month - 1)
        else { return nil }
        return "\(months[month - 1]) \(day)"
    }

    public static let seeded = MenuModel(rows: [
        .sectionHeader("Fall 2026"),
        // A `.hairline` leads every course, mirroring `MenuTranslation` exactly —
        // otherwise the boundaries would never appear under BRIGHTSPACEBAR_STUB=1
        // and their real look would go unreviewed until it shipped.
        .hairline,
        // Dated assignments, so the "name — due date" format is visible in the
        // running app even though no reachable real course has a due date yet.
        .course(CourseRow(
            id: 1_498_777, title: "Data Engineering", subtitle: "CS 17600", url: url(1_498_777),
            // The redesigned submenu (Intent 1): the add-forms lead — the
            // fetched work listing is gone; the heatmap popup is the browsing
            // surface — then the announcements section, exactly as before.
            submenu: addForms(course: 1_498_777) + [
                // The announcements section, seeded exactly as `MenuTranslation`
                // appends it: a separator, a mandatory label, then the recent
                // posts newest first.
                .separator,
                .sectionHeader("Announcements"),
                announcement(3_001, "Project 1 spec updated — see §4", daysAgo: 2, course: 1_498_777),
                announcement(3_002, "Guest lecture Thursday: data contracts in practice", daysAgo: 6, course: 1_498_777),
                announcement(3_003, "Office hours moved to Lawson 1142", daysAgo: 13, course: 1_498_777),
            ],
            // Work on today's cell — the outline has to survive a fill underneath it.
            graph: strip([2: .assignment, 3: .quiz, 5: .assignment, 7: .quiz]), graphMonths: months
        )),
        .hairline,
        // Undated assignments — the shape of every assignment in the real tenant
        // today, and the case where a naive formatter ships the literal "nil".
        .course(CourseRow(
            id: 1_415_558, title: "Multivariate Calculus", subtitle: "MA 26100", url: url(1_415_558),
            submenu: addForms(course: 1_415_558) + [
                // A second course with announcements, so the demo shows two
                // sections side by side and a cross-wired `ou=` would be visible
                // rather than merely untested.
                .separator,
                .sectionHeader("Announcements"),
                announcement(3_101, "Exam 1 rooms posted — check your section", daysAgo: 1, course: 1_415_558),
                announcement(3_102, "Quiz 4 solutions are up", daysAgo: 9, course: 1_415_558),
            ],
            // An empty today cell, so the outline is exercised with no fill behind
            // it, and work on index 111 so the window's trailing edge is visible —
            // which matters far more at sixteen weeks than it did at four.
            // Index 11 is the "assignment and quiz on one day" case, already resolved
            // upstream to the higher tier — the stub shows the outcome, not the race.
            graph: strip([4: .quiz, 8: .assignment, 11: .quiz, 111: .assignment]), graphMonths: months
        )),
        .hairline,
        // A course with no announcements: the submenu is the add-forms alone,
        // which is the common shape and the smallest one a course can have.
        .course(CourseRow(
            id: 1_452_301, title: "Computer Graphics Technology", subtitle: "CGT 11800", url: url(1_452_301),
            submenu: addForms(course: 1_452_301),
            // "Nothing due" drawn honestly: a full-width window of empty cells. Under
            // always-emit this is the only kind of empty there is, and the common
            // case, which is why the Civics row below seeds it a second time.
            graph: strip([:]), graphMonths: months
        )),
        .hairline,
        // Long title on purpose — the GUI should meet an awkward string before the
        // network hands it one. Real tenant max is 49 characters. Its window carries
        // the state the old today-anchored one could not hold: work on days of this
        // week that have already gone by, on either side of the opening Sunday.
        .course(CourseRow(
            id: 1_460_912, title: "Transformative Texts: Critical Thinking", subtitle: "SCLA 10100", url: url(1_460_912),
            submenu: addForms(course: 1_460_912),
            // Index 9 seeds the manual-test tier, so the renderer's darkest
            // square is reviewable in the stub before a real manual item exists.
            graph: strip([0: .assignment, 1: .quiz, 9: .test]), graphMonths: months
        )),
        .hairline,
        // No subtitle on purpose — `subtitle` is optional and must render cleanly nil.
        // It still gets a submenu and a window, because every course does: a bare
        // row would demo an interaction model the app can no longer reach.
        .course(CourseRow(id: 412_690, title: "Purdue Civics Knowledge Test", subtitle: nil, url: url(412_690), submenu: addForms(course: 412_690), graph: strip([:]), graphMonths: months)),
        .separator,
        // A real date, stamped once at seed time. A long-running stub demo shows
        // the countdown count down and, past the deadline, clamp to "Refreshes
        // soon" — all with no backend.
        .status(.nextRefresh(Date().addingTimeInterval(15 * 60))),
        .command(.refresh),
        .command(.quit),
    ])
}
