import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// THE CONTRACT between backend and GUI. Owned by the orchestrator; frozen.
//
// This is the whole API surface. It is deliberately values-only: no AppKit, no
// URLSession, no reference to `Course`, cookies, or JWTs. Two consequences that
// are the entire point:
//
//   1. The GUI can be built and tested with hand-written `MenuModel`s before any
//      wiring exists — genuine independent development, not a mock ceremony.
//   2. Backend detail cannot leak into view code, because the view target
//         literally cannot import it.
//
// Everything here is `Sendable` and `Equatable`. `Equatable` is load-bearing:
// the app rebuilds the menu only when the model actually changes.
// ─────────────────────────────────────────────────────────────────────────────

/// One clickable assignment, inside a course's submenu.
///
/// Deliberately the same shape as `CourseRow` — id, title, subtitle, url — so the
/// view layer renders both with one code path and the two cannot drift apart.
public struct AssignmentRow: Equatable, Sendable, Identifiable {
    /// D2L dropbox folder id. Unique within a course, and the `db=` value the
    /// click URL is derived from.
    public let id: Int
    /// The primary line: the assignment's name.
    public let title: String
    /// The secondary line — the rendered due date, e.g. `Due Mar 5`.
    ///
    /// Pre-formatted by the backend on purpose. Date formatting is a policy
    /// decision (locale, time zone, "tomorrow" vs a date), and policy lives in
    /// pure logic, not in view code. Nil when the assignment has no due date —
    /// which is every assignment in the currently reachable courses.
    public let subtitle: String?
    /// The raw due date, kept alongside the rendered form because sorting,
    /// "due soon" filtering, and tests all need the value rather than the text.
    /// Nil means D2L sent no `DueDate`.
    public let dueDate: Date?
    /// Where clicking goes. Non-optional for the same reason as `CourseRow.url`:
    /// a row that cannot be clicked has no business existing.
    public let url: URL

    public init(id: Int, title: String, subtitle: String? = nil, dueDate: Date? = nil, url: URL) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.dueDate = dueDate
        self.url = url
    }
}

/// One clickable class.
public struct CourseRow: Equatable, Sendable, Identifiable {
    /// D2L org-unit id. Unique per row, and what the click URL is derived from.
    public let id: Int
    /// The primary line, e.g. `Data Engineering`.
    public let title: String
    /// The secondary line, e.g. `CS 17600`. Nil when there is nothing useful to add.
    public let subtitle: String?
    /// Where clicking goes.
    ///
    /// Non-optional on purpose. `OrgUnit.HomeUrl` from D2L is null for 25 of 27 real
    /// enrollments, so the backend must *derive* `{baseUrl}/d2l/home/{id}` before
    /// building a row. Making this non-optional means a row cannot exist without a
    /// working click target, so the GUI never needs a "what if there's no URL" branch.
    public let url: URL
    /// The rows shown when this course is hovered. Empty means no submenu at all —
    /// the course renders as a plain clickable item, exactly as before this field
    /// existed.
    ///
    /// It is `[MenuRow]` rather than `[AssignmentRow]` so that *every* structural
    /// decision — order, the "No assignments" line, a staleness note — stays in the
    /// pure translation layer. The view walks rows; it never decides what belongs.
    ///
    /// AppKit constraint the backend must respect: a menu item that owns a submenu
    /// is no longer clickable, so `url` becomes unreachable by click once this is
    /// non-empty. The view layer therefore re-exposes it as a course-home row inside
    /// the submenu; see `MenuAssembler`.
    public let submenu: [MenuRow]

    public init(id: Int, title: String, subtitle: String? = nil, url: URL, submenu: [MenuRow] = []) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.url = url
        self.submenu = submenu
    }
}

/// A command the user can invoke. Kept as data rather than closures so a
/// `MenuModel` stays `Equatable` and cheap to compare.
public enum MenuCommand: String, Equatable, Sendable, CaseIterable {
    case refresh
    case quit
}

/// One line in the dropdown.
public enum MenuRow: Equatable, Sendable {
    case course(CourseRow)
    /// One assignment. Appears inside a course's `submenu`, never at top level.
    case assignment(AssignmentRow)
    /// A group label, e.g. a term name. Not selectable.
    case sectionHeader(String)
    /// Non-actionable prose — the empty state, or an error explanation. This is how
    /// the menu says something instead of appearing broken.
    case message(String)
    /// Freshness, e.g. `Updated 3 minutes ago`. Not selectable.
    case status(String)
    case separator
    case command(MenuCommand)
}

/// Everything the dropdown needs in order to draw itself.
public struct MenuModel: Equatable, Sendable {
    public let rows: [MenuRow]

    public init(rows: [MenuRow]) {
        self.rows = rows
    }

    /// Deliberately not `MenuModel(rows: [])`. A genuinely empty dropdown reads as a
    /// crashed app, so even "nothing to show" carries a message and a way out.
    public static let placeholder = MenuModel(rows: [
        .message("No courses yet"),
        .separator,
        .command(.refresh),
        .command(.quit),
    ])

    /// Convenience for the view layer and for tests.
    public var courses: [CourseRow] {
        self.rows.compactMap { if case .course(let row) = $0 { row } else { nil } }
    }
}

public extension Array where Element == MenuRow {
    /// The assignments among these rows. Used to read a course's submenu without
    /// pattern matching at every call site.
    var assignments: [AssignmentRow] {
        self.compactMap { if case .assignment(let row) = $0 { row } else { nil } }
    }
}
