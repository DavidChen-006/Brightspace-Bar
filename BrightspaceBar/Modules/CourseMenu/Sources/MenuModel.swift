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

/// One clickable announcement, inside a course's submenu.
///
/// Deliberately the same shape as `AssignmentRow` — id, title, subtitle, url —
/// so the view layer renders both with one code path and the two cannot drift
/// apart. `subtitle` is the rendered posting date (e.g. `Aug 10`), pre-formatted
/// by the pure translation layer for the same reason `AssignmentRow.subtitle`
/// is: date formatting is policy, and policy does not live in view code.
public struct AnnouncementRow: Equatable, Sendable, Identifiable {
    /// D2L news item id. Unique within a course.
    public let id: Int
    /// The announcement's title.
    public let title: String
    /// The rendered posting date, e.g. `Aug 10`. Nil when D2L sent no date.
    public let subtitle: String?
    /// The raw posting date, kept alongside the rendered form because sorting
    /// and cutoff filtering need the value rather than the text.
    public let date: Date?
    /// Where clicking goes — the course's announcements page. Non-optional for
    /// the same reason as every other row: no destination, no row.
    public let url: URL

    public init(id: Int, title: String, subtitle: String? = nil, date: Date? = nil, url: URL) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.date = date
        self.url = url
    }
}

/// What kind of work a day in a course's graph holds, ranked by importance.
///
/// A ranking rather than an intensity scale, because a day with both an
/// assignment and a quiz renders as the more important kind — expressed
/// downstream as one expression, `itemsDueThatDay.map(\.tier).max()`. That
/// expression is only correct while `<` follows the rank, so the ordering is
/// part of the contract rather than an accident of declaration order.
///
/// The raw values are pinned with nothing above `quiz` so a future
/// `case test = 3` slots in with no other change.
public enum CellTier: Int, Comparable, Equatable, Sendable, CaseIterable {
    case assignment = 1
    case quiz = 2
    /// The slot the pinning above reserved. Only *manual* items carry it today —
    /// D2L reports no tests as a distinct kind — but the tier is contract
    /// vocabulary, not a manual-item detail: a cell drawn from a manual test and
    /// one drawn from a hypothetical fetched test must be the same cell.
    case test = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One work item inside a day cell's hover popup.
///
/// Deliberately the same shape as every other clickable row — title plus a
/// non-optional destination — so the popup renders it the way the menu renders
/// rows and a popup line can never exist without a working click target. The
/// kind travels as the `CellTier` the grid already speaks, not as a display
/// string: the tier is contract vocabulary, and how a tier is *named* on screen
/// ("assignment"/"quiz") is the renderer's word choice, exactly like its colour.
public struct GraphDayItem: Equatable, Sendable {
    /// The item's name, rendered as the popup row's link text.
    public let title: String
    /// What kind of work this is — the same ranking the cell's fill is drawn
    /// from, so the popup and the square can never disagree about a day.
    public let tier: CellTier
    /// Where clicking the row goes: the item's deep link, pre-built by the
    /// translation layer from the same templates the submenu rows use.
    public let url: URL

    /// Non-nil exactly for the student's own items (Intent 4): the id the
    /// delete ✕ hands back. Fetched items carry nil and get no ✕ — a refresh
    /// would resurrect them anyway.
    public let manualId: UUID?

    public init(title: String, tier: CellTier, url: URL, manualId: UUID? = nil) {
        self.title = title
        self.tier = tier
        self.url = url
        self.manualId = manualId
    }

}

/// Everything the hover popup for one non-empty day says.
///
/// `caption` is pre-formatted ("Thu Aug 27 · CS 25200") for the same reason
/// `AssignmentRow.subtitle` is: a `GraphCell` carries no date, and date
/// formatting is policy that lives in the pure translation layer, never in view
/// code. `items` is never empty by contract — an empty day has no detail at
/// all (`GraphCell.detail == nil`), not a detail with nothing to say.
public struct GraphDayDetail: Equatable, Sendable {
    /// The popup's caption line: the local day plus the course label.
    public let caption: String
    /// One entry per work item due that day, in a deterministic order the
    /// translation layer owns.
    public let items: [GraphDayItem]

    public init(caption: String, items: [GraphDayItem]) {
        self.caption = caption
        self.items = items
    }
}

/// One day in a course's graph strip.
///
/// Carries no date. The strip is positional — index is the day offset from the
/// window start and cell 0 is today — because bucketing UTC instants into local
/// calendar days is the mapping layer's job, and keeping it out of here is what
/// lets the GUI be built against hand-written strips.
public struct GraphCell: Equatable, Sendable {
    /// The most important work due that day. Nil is an empty day, not a zero-th
    /// tier; empty days still occupy their index.
    public let tier: CellTier?
    /// Whether this is today's cell.
    ///
    /// A separate field, never a fill value. The renderer draws the fill from
    /// `tier` and the outline from this independently, so "the today indicator
    /// must not obscure the underlying activity state" holds by construction
    /// rather than by careful drawing.
    public let isToday: Bool
    /// What hovering this cell shows, or nil for a day with nothing due.
    ///
    /// Nil and "tier is nil" travel together by construction in the translation
    /// layer, but the renderer keys ONLY off this field for hover behaviour —
    /// a cell with a fill and no detail simply has no popup, which is the safe
    /// degradation for any strip built without link context (stubs, old tests).
    ///
    /// Last and defaulted for the same reason `CourseRow.graph` was: every
    /// existing call site compiles untouched, and it participates in
    /// `Equatable` like every other field.
    public let detail: GraphDayDetail?

    public init(tier: CellTier?, isToday: Bool = false, detail: GraphDayDetail? = nil) {
        self.tier = tier
        self.isToday = isToday
        self.detail = detail
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
    /// The rows shown when this course is hovered. Empty means no submenu at all,
    /// and the course renders as a plain clickable item — a shape the assignment
    /// translation no longer produces for any state, since a row's interaction
    /// model must not depend on whether a fetch has happened yet. The empty case
    /// stays supported as a mechanism, not as a state the app can reach.
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
    /// The strip of upcoming days drawn beside this course. Empty means no graph,
    /// and the course renders as the plain row it was before this field existed.
    ///
    /// Last and defaulted for the same reason `AssignmentRow.subtitle` is: every
    /// existing call site — tests, stubs, the translation layer — compiles
    /// untouched. It participates in `Equatable` like every other field, so a
    /// strip that changes at midnight is a change the menu redraws.
    public let graph: [GraphCell]
    /// One entry per week COLUMN of `graph`, nil where no month begins there.
    ///
    /// The one place the backend names a column, and it belongs to the backend
    /// because "which column holds April's first" is a fact about real days and
    /// the renderer has no dates. Weekday labels are the opposite — row 0 is
    /// Sunday for every window the backend can emit — so they stay a renderer
    /// literal and never enter this contract.
    ///
    /// Last and defaulted like `graph`, so every pre-existing call site compiles
    /// untouched, and `Equatable` like every other field: a window that rolls
    /// into a new month over cells that happen to be unchanged is still a change
    /// the menu must redraw, which for an empty grid is the common case.
    public let graphMonths: [String?]
    /// The "This week" block rendered in the space right of `graph` — already
    /// formatted lines ("2 assignments · 1 quiz", "next: HW 2 · Thu"), because
    /// the derivation (calendar weeks, pluralisation) is backend policy and the
    /// renderer has no dates. Empty renders nothing, so every pre-graph and
    /// pre-stats call site keeps its output.
    public let weekLines: [String]

    public init(
        id: Int,
        title: String,
        subtitle: String? = nil,
        url: URL,
        submenu: [MenuRow] = [],
        graph: [GraphCell] = [],
        graphMonths: [String?] = [],
        weekLines: [String] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.url = url
        self.submenu = submenu
        self.graph = graph
        self.graphMonths = graphMonths
        self.weekLines = weekLines
    }
}

/// A command the user can invoke. Kept as data rather than closures so a
/// `MenuModel` stays `Equatable` and cheap to compare.
public enum MenuCommand: String, Equatable, Sendable, CaseIterable {
    case refresh
    case quit
}

/// A timestamp the GUI renders as a relative time — at *display* time, not at
/// model-build time (experiment 18).
///
/// The row carries the `Date`, never a baked string ("Refreshes in 12
/// minutes"), which would have had two costs:
///
///   1. STALE AT OPEN. A string computed when the model was built (launch, timer
///      tick, refresh click) would still read "12 minutes" when the menu is
///      opened 11 minutes later. The GUI cannot re-derive a fresher string from
///      a string.
///   2. FALSE INEQUALITY. `MenuModel`'s `Equatable` exists so an unchanged menu
///      is not rebuilt, but a baked string changing every minute would make
///      identical data compare unequal and force a full rebuild on every tick.
///
/// Carrying the `Date` avoids both: the model is time-invariant (equal data →
/// equal model, whenever built), and the GUI formats against a fresh `now` each
/// time the menu opens (`StatusText`, `menuWillOpen`). RepoBar does exactly
/// this — an absolute deadline in the model, relative formatting at paint time,
/// no ticking display timer.
///
/// A single case today (the older "Updated N ago" freshness row was removed);
/// it stays an enum because the status row is where a second timestamp kind
/// would plug in.
public enum StatusStamp: Equatable, Sendable {
    /// When the next automatic refresh fires. Renders "Refreshes in N min".
    case nextRefresh(Date)
}

/// One line in the dropdown.
public enum MenuRow: Equatable, Sendable {
    case course(CourseRow)
    /// One inline "add an item" mini-form, inside a course's submenu (Intent 1).
    /// The row is pure DATA — which course, which kind — because everything the
    /// form displays (its heading) and everything it produces (`AddItemDraft`)
    /// is derivable from those two facts plus what the student types. The GUI
    /// hosts the fields; the kind is decided by which section the form is,
    /// never asked.
    case addForm(AddItemFormRow)
    /// One assignment. Appears inside a course's `submenu`, never at top level.
    case assignment(AssignmentRow)
    /// One announcement. Appears inside a course's `submenu`, never at top level.
    case announcement(AnnouncementRow)
    /// A group label, e.g. a term name. Not selectable.
    case sectionHeader(String)
    /// Non-actionable prose — the empty state, or an error explanation. This is how
    /// the menu says something instead of appearing broken.
    case message(String)
    /// Freshness as data. The GUI formats it against `now` when the menu opens
    /// (see `StatusText`). Not selectable.
    case status(StatusStamp)
    case separator
    /// A boundary line between courses (NewVertical-3 §3.1). Not selectable.
    ///
    /// Carries no payload — a hairline knows nothing about what it separates,
    /// which is what lets the translation layer place it by rule rather than by
    /// asking a row about its neighbours. It sits ALONGSIDE `.separator`, which
    /// stays native and stays the footer's boundary above the status row.
    case hairline
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
