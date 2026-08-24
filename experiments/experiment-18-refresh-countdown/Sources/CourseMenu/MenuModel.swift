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

    public init(id: Int, title: String, subtitle: String? = nil, url: URL) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.url = url
    }
}

/// A command the user can invoke. Kept as data rather than closures so a
/// `MenuModel` stays `Equatable` and cheap to compare.
public enum MenuCommand: String, Equatable, Sendable, CaseIterable {
    case refresh
    case quit
}

/// A timestamp the GUI renders as a relative time — at *display* time, not at
/// model-build time.
///
/// This is the experiment's load-bearing change. The row used to carry a baked
/// string ("Updated 3 minutes ago"), which had two costs:
///
///   1. STALE AT OPEN. The string was computed when the model was built (launch,
///      timer tick, refresh click) — so a menu opened 14 minutes later still said
///      "Updated just now". The GUI cannot re-derive a fresher string from a
///      string.
///   2. FALSE INEQUALITY. `MenuModel`'s `Equatable` exists so an unchanged menu
///      is not rebuilt, but the baked string changed every minute, so identical
///      data compared unequal and forced a full rebuild on every timer tick.
///
/// Carrying the `Date` fixes both: the model is now time-invariant (equal data →
/// equal model, whenever built), and the GUI formats against a fresh `now` each
/// time the menu opens. RepoBar does exactly this — an absolute deadline in the
/// model, `RelativeFormatter` at paint time, no ticking display timer.
public enum StatusStamp: Equatable, Sendable {
    /// When the data was last fetched; nil = never. Renders "Updated N min ago".
    case updated(Date?)
    /// When the next automatic refresh fires. Renders "Refreshes in N min".
    case nextRefresh(Date)
}

/// One line in the dropdown.
public enum MenuRow: Equatable, Sendable {
    case course(CourseRow)
    /// A group label, e.g. a term name. Not selectable.
    case sectionHeader(String)
    /// Non-actionable prose — the empty state, or an error explanation. This is how
    /// the menu says something instead of appearing broken.
    case message(String)
    /// Freshness as data. The GUI formats it against `now` when the menu opens
    /// (see `StatusText`). Not selectable.
    case status(StatusStamp)
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
