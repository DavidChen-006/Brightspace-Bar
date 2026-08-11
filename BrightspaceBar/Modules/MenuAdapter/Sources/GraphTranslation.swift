import Foundation
import AssignmentPipeline
import CourseMenu

// ─────────────────────────────────────────────────────────────────────────────
// SEAM: due-date instants → CourseRow.graph. The arithmetic half of the graph.
//
//   AssignmentPipeline.AssignmentsState  ← backend vocabulary (left of here)
//   CourseMenu.GraphCell / CellTier      ← frontend vocabulary (right of here)
//
// Sibling of `AssignmentTranslation`, same shape of responsibility and the same
// purity rules: backend values plus `now` and `timeZone` in, contract values out.
// Nothing here reads a clock, a zone, or a locale, and there is no stored window
// — the strip is recomputed from `now` on every call, which is why it "shifts"
// at midnight with no state to move (RepoBar's range shape with the sign
// flipped; see decision §3).
//
// A `GraphCell` carries no date. The strip is positional, so deciding which
// local day an instant belongs to is entirely this file's job — and it is the
// half that fails silently, because a filled cell one column over is still a
// perfectly plausible-looking strip.
// ─────────────────────────────────────────────────────────────────────────────
public enum GraphTranslation {

    /// How many days the strip covers, starting at the Sunday of today's week.
    /// Sixteen weeks: a semester's worth of planning. A whole number of weeks is
    /// load-bearing rather than tidy — the renderer derives `row = i % 7` from it
    /// (§3.3), and a ragged final column is something it cannot detect.
    public static let windowDays = 112

    /// The strip for ONE course. Pinned by `GraphTranslationTests`; every rule
    /// below is specified there, not here.
    ///
    /// - Parameters:
    ///   - state: what the store knows about this course. Every state yields the
    ///     full window, `neverFetched` included: a missing grid is
    ///     indistinguishable from a rendering failure, where an empty grid
    ///     honestly says "nothing known to be due" (§2 item 2). An empty list is
    ///     data, and blanking a failed refresh would claim work vanished, the
    ///     same lie the submenu refuses to tell.
    ///   - now: decides where the window starts. Cell 0 is the local SUNDAY of
    ///     the week `now` falls in, so `now` itself lands in cells 0–6 and the
    ///     already-passed days of this week are drawn rather than dropped.
    ///   - timeZone: decides which calendar day an instant belongs to. Deadlines
    ///     arrive as UTC instants, and `2026-02-13T04:30:00Z` is 23:30 on
    ///     **February 12** in Indiana — drawn a day late, a student reads the
    ///     square as "not due until tomorrow".
    public static func strip(
        state: AssignmentsState,
        now: Date,
        timeZone: TimeZone
    ) -> [GraphCell] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Pinned for the same reason `AssignmentTranslation.dueLabel` pins it: no
        // ambient locale may reach the calendar's own behaviour.
        calendar.locale = Locale(identifier: "en_US_POSIX")

        let today = calendar.startOfDay(for: now)
        let windowStart = Self.sundayOfWeek(containing: today, in: calendar)
        // 0...6 by construction — `windowStart` is the Sunday of this very day's week.
        let todayOffset = Self.dayOffset(from: windowStart, to: today, in: calendar) ?? 0

        // Highest tier wins, accumulated per day: `itemsDueThatDay.map(\.tier).max()`
        // expressed as a fold, so the winner cannot depend on the order items
        // arrive in — which `MenuModel`'s `Equatable` skip-rebuild relies on.
        var tiers: [Int: CellTier] = [:]
        for item in state.assignments where !item.isHidden {
            guard
                let dueDate = item.dueDate,
                let offset = self.dayOffset(from: windowStart, to: dueDate, in: calendar),
                (0..<Self.windowDays).contains(offset)
            else { continue }
            let tier = Self.tier(of: item.kind)
            tiers[offset] = Swift.max(tiers[offset] ?? tier, tier)
        }

        // Always the full window: an exclusion empties a cell, it never shortens
        // the strip. `isToday` is set positionally and never as a fill, so the
        // indicator cannot obscure the activity state (decision §2).
        return (0..<Self.windowDays).map { GraphCell(tier: tiers[$0], isToday: $0 == todayOffset) }
    }

    /// The grid's column headings — one entry per week column of `strip`'s
    /// window, nil where no month begins in that column. Pinned by
    /// `GraphMonthLabelTests`; every rule below is specified there, not here.
    ///
    /// One entry per column and never a compacted list of the named ones: the
    /// renderer indexes this BY COLUMN, so dropping the nils would slide every
    /// heading left of the columns it describes — which still reads as a
    /// perfectly ordinary grid, and mis-dates every square under it.
    ///
    /// Column 0 always carries the window start's month, because a window
    /// opening on the 2nd would otherwise go nearly a month unscaled. The
    /// accepted consequence: a month whose 1st falls INSIDE column 0 is never
    /// named — a window opening Sun Dec 28 is headed "Dec" and never says
    /// January.
    ///
    /// - Parameters:
    ///   - now: decides where the window opens, exactly as it does for `strip`.
    ///   - timeZone: decides which local day `now` is, and so which week the
    ///     window opens in — 23:30 Saturday in Indiana is Sunday in UTC, and the
    ///     two readings head the grid with different months.
    public static func monthLabels(now: Date, timeZone: TimeZone) -> [String?] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")

        let windowStart = Self.sundayOfWeek(containing: calendar.startOfDay(for: now), in: calendar)

        return (0..<(Self.windowDays / 7)).map { column in
            // Stepping by `.day` components, never by 7 × 86_400 seconds: a week
            // spanning a DST transition is not 168 hours, and a window counted in
            // seconds slides an hour and mislabels every column after it.
            let days = (0..<7).compactMap {
                calendar.date(byAdding: .day, value: column * 7 + $0, to: windowStart)
            }
            // Column 0 is named from the day the window opens; every later column
            // is named only if one of its seven local days IS a 1st. "Contains
            // the 1st", not "opens in a new month" — the column opening May 31 is
            // June's, and the other rule would head the one after it.
            guard let named = column == 0 ? days.first : days.first(where: {
                calendar.component(.day, from: $0) == 1
            }) else { return nil }
            return Self.monthName(of: named, in: calendar)
        }
    }

    /// Three-letter month names, fixed rather than locale-derived, for the same
    /// reason the calendar's own locale is pinned: a suite that passes in Indiana
    /// and fails in Paris is a suite nobody trusts. Localization is future work,
    /// and lands here as a threaded locale.
    private static let monthNames = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    private static func monthName(of day: Date, in calendar: Calendar) -> String {
        Self.monthNames[calendar.component(.month, from: day) - 1]
    }

    /// The local start of the SUNDAY on or before `day`.
    ///
    /// Sunday explicitly, from the Gregorian weekday number (1 = Sunday), rather
    /// than from `calendar.firstWeekday` — that is locale-dependent, and the grid
    /// labels row 0 "Sunday" for every student regardless of where the machine
    /// thinks it is. Stepping back by `.day` components rather than by seconds for
    /// the same reason `dayOffset` does: a week containing a DST transition is not
    /// 7 × 86_400 seconds long.
    private static func sundayOfWeek(containing day: Date, in calendar: Calendar) -> Date {
        let daysSinceSunday = calendar.component(.weekday, from: day) - 1
        let sunday = calendar.date(byAdding: .day, value: -daysSinceSunday, to: day) ?? day
        return calendar.startOfDay(for: sunday)
    }

    /// Whole calendar days between two instants' local days — the cell index.
    ///
    /// Both ends are collapsed to their local start of day first, which is what
    /// makes the answer day-granular in both directions: an instant at 23:30 lands
    /// on its own local day rather than its UTC one, and work due at 08:00 this
    /// morning still counts as today's day when `now` is 10:00. An instant
    /// comparison would blank today's square as the day wore on.
    ///
    /// `dateComponents` rather than elapsed seconds ÷ 86_400: a day across a DST
    /// transition is 23 or 25 hours, so step-counting files 00:30 on the morning
    /// after a spring-forward at offset 26.98 — one cell early, and only on the
    /// dates where it is hardest to notice.
    private static func dayOffset(from windowStart: Date, to dueDate: Date, in calendar: Calendar) -> Int? {
        calendar.dateComponents([.day], from: windowStart, to: calendar.startOfDay(for: dueDate)).day
    }

    /// The kind→tier mapping, in the one place the contract's vocabulary is
    /// entered. Exhaustive with no `default`, so a third `ItemKind` is a compile
    /// error here rather than a silently unrendered day.
    private static func tier(of kind: ItemKind) -> CellTier {
        switch kind {
        case .assignment: .assignment
        case .quiz: .quiz
        }
    }
}
