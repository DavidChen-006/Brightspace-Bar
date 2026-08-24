import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// WeekStats — the pure logic behind the "This week" block that will render in
// the blank space right of each course's heatmap grid. No GUI, no I/O: values
// in, values out, so every path here is hermetically testable.
//
// INPUT TYPE DECISION: this module defines its own minimal `WeekWorkItem`
// rather than borrowing a CourseMenu contract type. `GraphDayItem` was the
// candidate, but it carries no due `Date` (the grid resolves dates before
// building it) and its `CellTier` has no test-like case — both fields this
// computation turns on. Following ManualItems' `WorkMerge` precedent, the
// adapter maps its own richer types into this shape later; the two concurrent
// edits stay uncoupled.
// ─────────────────────────────────────────────────────────────────────────────

/// What kind of work an item is, in the vocabulary this block reports.
///
/// `test` covers tests, exams, midterms — anything test-like the adapter
/// classifies. Raw values pin a stable order for deterministic tie-breaks and
/// for the counts line, which always reads assignments → quizzes → tests.
public enum WorkKind: Int, Comparable, Equatable, Sendable, CaseIterable {
    case assignment = 1
    case quiz = 2
    case test = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One work item as this module needs to see it. The adapter maps whatever it
/// has (fetched assignment, quiz, manual item) into this; nothing here knows
/// where an item came from.
public struct WeekWorkItem: Equatable, Sendable {
    public let name: String
    public let kind: WorkKind
    /// When it is due. Non-optional on purpose: an undated item can be neither
    /// "due this week" nor "next", so the adapter filters those out before
    /// calling in rather than this module inventing a policy for them.
    public let due: Date
    /// The item's deep link, when one exists. Optional because a manual item
    /// may have nowhere to click.
    public let url: URL?

    public init(name: String, kind: WorkKind, due: Date, url: URL? = nil) {
        self.name = name
        self.kind = kind
        self.due = due
        self.url = url
    }
}

/// The computed block: per-kind counts for the current week, plus the single
/// next upcoming item (which may be beyond the week — it answers "what's
/// first", not "what's first this week").
public struct WeekStats: Equatable, Sendable {
    /// How many items of each kind are due in the current week. Kinds with
    /// zero items are absent — `counts[.quiz] ?? 0` is the read.
    public let counts: [WorkKind: Int]
    /// The next item due at or after `now`, or nil when nothing is upcoming.
    public let next: WeekWorkItem?

    public init(counts: [WorkKind: Int], next: WeekWorkItem?) {
        self.counts = counts
        self.next = next
    }
}

public enum WeekStatsBuilder {

    /// The core pure function: one course's items → its "This week" block.
    ///
    /// WEEK DEFINITION: "this week" is the `.weekOfYear` interval of the
    /// injected `Calendar` (with `timeZone` applied) that contains `now`,
    /// obtained via `Calendar.dateInterval(of:for:)` — membership is
    /// `start ≤ due < end`, so an item exactly at the week's start is in and
    /// one exactly at the next week's start is out. Delegating to Calendar
    /// rather than hand math is the point: the calendar's `firstWeekday`
    /// already encodes whether weeks start Sunday or Monday (a locale
    /// decision this module must not re-make), and a DST transition makes a
    /// week 167 or 169 hours long — `dateInterval` returns the true civil
    /// boundaries where `start + 7*86400` would drift by an hour.
    public static func stats(
        items: [WeekWorkItem],
        now: Date,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> WeekStats {
        var cal = calendar
        cal.timeZone = timeZone

        var counts: [WorkKind: Int] = [:]
        if let week = cal.dateInterval(of: .weekOfYear, for: now) {
            for item in items where item.due >= week.start && item.due < week.end {
                counts[item.kind, default: 0] += 1
            }
        }

        // "Next" scans everything upcoming, not just this week: an empty week
        // with a midterm next Tuesday should still say so. Tie-break on equal
        // due instants is name (case-sensitive, stable), then kind — so the
        // same inputs always pick the same item regardless of input order.
        let next = items
            .filter { $0.due >= now }
            .min { lhs, rhs in
                if lhs.due != rhs.due { return lhs.due < rhs.due }
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                return lhs.kind < rhs.kind
            }

        return WeekStats(counts: counts, next: next)
    }

    /// The "All classes" variant: the same computation over the union of every
    /// course's items. A union, not a per-course merge — counts add, and the
    /// single next item is the earliest across all courses under the same
    /// tie-break.
    public static func aggregate(
        courses: [[WeekWorkItem]],
        now: Date,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> WeekStats {
        stats(items: courses.flatMap { $0 }, now: now, calendar: calendar, timeZone: timeZone)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Formatters. Deterministic string logic worth pinning in tests — fixed
// English tables, never DateFormatter, for the same reason GraphTranslation's
// captions use them: a line that changes with the machine's locale is a test
// nobody trusts (and a menu that surprises its one user).
// ─────────────────────────────────────────────────────────────────────────────

public enum WeekStatsFormat {

    /// "2 assignments · 1 quiz" — kinds in fixed order (assignments, quizzes,
    /// tests), zero kinds omitted, singular/plural per count. Nil when every
    /// count is zero: the caller decides what an empty week says, not this
    /// formatter.
    public static func countsLine(_ counts: [WorkKind: Int]) -> String? {
        let parts = WorkKind.allCases.compactMap { kind -> String? in
            guard let n = counts[kind], n > 0 else { return nil }
            return "\(n) \(noun(for: kind, count: n))"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "next: Homework 4 · Wed" — the weekday of the item's due date in the
    /// given time zone, from a fixed English table indexed by the Gregorian
    /// weekday number (1 = Sunday), matching GraphTranslation's reasoning.
    public static func nextLine(
        _ item: WeekWorkItem,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> String {
        var cal = calendar
        cal.timeZone = timeZone
        let weekday = weekdayNames[cal.component(.weekday, from: item.due) - 1]
        return "next: \(item.name) · \(weekday)"
    }

    /// Indexed by the Gregorian weekday number minus one (1 = Sunday).
    private static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    private static func noun(for kind: WorkKind, count: Int) -> String {
        switch kind {
        case .assignment: return count == 1 ? "assignment" : "assignments"
        case .quiz: return count == 1 ? "quiz" : "quizzes"
        case .test: return count == 1 ? "test" : "tests"
        }
    }
}
