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

    /// How many days the strip covers, starting at today. Four weeks: far enough
    /// ahead to be worth planning against, short enough to stay legible beside a
    /// course name.
    public static let windowDays = 28

    /// The strip for ONE course. Pinned by `GraphTranslationTests`; every rule
    /// below is specified there, not here.
    ///
    /// - Parameters:
    ///   - state: what the store knows about this course. `neverFetched` is the
    ///     only state that yields no strip — assignments are deliberately not
    ///     persisted, so that is every course's state at launch and the course
    ///     renders exactly as it did before this feature existed. A `loaded([])`
    ///     or a `failed` course keeps its full window: an empty list is data, and
    ///     blanking a failed refresh would claim work vanished, the same lie the
    ///     submenu refuses to tell.
    ///   - now: decides where the window starts. Cell 0 is the local day `now`
    ///     falls on.
    ///   - timeZone: decides which calendar day an instant belongs to. Deadlines
    ///     arrive as UTC instants, and `2026-02-13T04:30:00Z` is 23:30 on
    ///     **February 12** in Indiana — drawn a day late, a student reads the
    ///     square as "not due until tomorrow".
    public static func strip(
        state: AssignmentsState,
        now: Date,
        timeZone: TimeZone
    ) -> [GraphCell] {
        guard state != .neverFetched else { return [] }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Pinned for the same reason `AssignmentTranslation.dueLabel` pins it: no
        // ambient locale may reach the calendar's own behaviour.
        calendar.locale = Locale(identifier: "en_US_POSIX")

        let windowStart = calendar.startOfDay(for: now)

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
        return (0..<Self.windowDays).map { GraphCell(tier: tiers[$0], isToday: $0 == 0) }
    }

    /// Whole calendar days between two instants' local days — the cell index.
    ///
    /// Both ends are collapsed to their local start of day first, which is what
    /// makes the answer day-granular in both directions: an instant at 23:30 lands
    /// on its own local day rather than its UTC one, and work due at 08:00 this
    /// morning still counts as day 0 when `now` is 10:00. An instant comparison
    /// would blank today's square as the day wore on.
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
