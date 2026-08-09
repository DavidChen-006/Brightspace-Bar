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

    public static let seeded = MenuModel(rows: [
        .sectionHeader("Fall 2026"),
        .course(CourseRow(id: 1_498_777, title: "Data Engineering", subtitle: "CS 17600", url: url(1_498_777))),
        .course(CourseRow(id: 1_415_558, title: "Multivariate Calculus", subtitle: "MA 26100", url: url(1_415_558))),
        .course(CourseRow(id: 1_452_301, title: "Computer Graphics Technology", subtitle: "CGT 11800", url: url(1_452_301))),
        // Long title on purpose — the GUI should meet an awkward string before the
        // network hands it one. Real tenant max is 49 characters.
        .course(CourseRow(id: 1_460_912, title: "Transformative Texts: Critical Thinking", subtitle: "SCLA 10100", url: url(1_460_912))),
        // No subtitle on purpose — `subtitle` is optional and must render cleanly nil.
        .course(CourseRow(id: 412_690, title: "Purdue Civics Knowledge Test", subtitle: nil, url: url(412_690))),
        .separator,
        .status("Updated just now"),
        .command(.refresh),
        .command(.quit),
    ])
}
