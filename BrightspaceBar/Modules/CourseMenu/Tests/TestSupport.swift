import Foundation
import CourseMenu

// ─────────────────────────────────────────────────────────────────────────────
// SHARED TEST SUPPORT — orchestrator-owned, like the contract itself. Frozen.
// Add your own support files rather than editing this one.
// ─────────────────────────────────────────────────────────────────────────────

/// Builders so a test can state a model in one line and keep its Arrange section
/// about the case under test rather than about `URL(string:)!`.
public enum Sample {
    public static func url(_ id: Int) -> URL {
        URL(string: "https://purdue.brightspace.com/d2l/home/\(id)")!
    }

    public static func course(
        id: Int,
        title: String = "Some Course",
        subtitle: String? = "ABC 10100"
    ) -> CourseRow {
        CourseRow(id: id, title: title, subtitle: subtitle, url: self.url(id))
    }

    /// `n` distinct courses, ids `1...n`, so count-based assertions stay readable.
    public static func courses(_ n: Int) -> [CourseRow] {
        (1...n).map { self.course(id: $0, title: "Course \($0)", subtitle: "C \($0)") }
    }

    public static func model(courseCount: Int) -> MenuModel {
        MenuModel(rows: self.courses(courseCount).map { MenuRow.course($0) })
    }
}

/// A `MenuDataSource` you control, for driving the GUI without a backend.
///
/// Records how many times each method was called: a menu that quietly refetches on
/// every open, or that blocks the dropdown on `refresh()`, is a real bug and call
/// counts are how it becomes visible.
public actor ScriptedDataSource: MenuDataSource {
    private var current: MenuModel
    private var refreshed: MenuModel?
    public private(set) var currentMenuCalls = 0
    public private(set) var refreshCalls = 0

    public init(current: MenuModel, afterRefresh: MenuModel? = nil) {
        self.current = current
        self.refreshed = afterRefresh
    }

    public func currentMenu() async -> MenuModel {
        self.currentMenuCalls += 1
        return self.current
    }

    public func refresh() async -> MenuModel {
        self.refreshCalls += 1
        if let refreshed { self.current = refreshed }
        return self.current
    }

    public func callCounts() -> (currentMenu: Int, refresh: Int) {
        (self.currentMenuCalls, self.refreshCalls)
    }
}
