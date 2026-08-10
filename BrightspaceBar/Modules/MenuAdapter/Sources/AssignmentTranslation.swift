import Foundation
import AssignmentPipeline
import CourseMenu
import CoursePipeline

// ─────────────────────────────────────────────────────────────────────────────
// SEAM: [Assignment] → CourseRow.submenu. The join between the two spikes.
//
//   AssignmentPipeline.AssignmentsState  ← backend vocabulary (left of here)
//   CourseMenu.MenuRow / AssignmentRow   ← frontend vocabulary (right of here)
//
// `AssignmentPipeline` knows how to fetch, fold, and build a link; `BrightspaceBar`
// knows how to render a submenu. Neither imports the other. This file is the only
// place the two meet, and it is a pure function: `now` and `timeZone` are
// parameters, so nothing here reads a clock, a locale, or the world.
//
// Everything the GUI would otherwise have to decide is decided here — which
// assignments are visible, what order they sit in, what the deadline line says,
// and what to show when there is nothing or when the fetch failed. The view walks
// rows; it never chooses them.
// ─────────────────────────────────────────────────────────────────────────────
public enum AssignmentTranslation {

    // MARK: - What the submenu says when it has no assignments to show

    /// A successful fetch that found nothing. Deliberately a message rather than
    /// `[]`: an empty row list makes `MenuAssembler` attach no submenu at all,
    /// which reads as "this feature does not exist" instead of "nothing is due".
    static let noAssignments = "No assignments"
    /// A failure with nothing previously known — the dead-session-on-first-fetch
    /// case. Silence here would be indistinguishable from a course that genuinely
    /// has no assignments.
    static let loadFailed = "Couldn't load assignments"
    /// A failure over assignments we already hold. The rows stay; this admits they
    /// may have moved on.
    static let refreshFailed = "Couldn't refresh — may be out of date"

    // MARK: - The submenu

    /// The submenu rows for ONE course. Pinned by `AssignmentWiringTests`; every
    /// rule below is specified there, not here.
    ///
    /// - Parameters:
    ///   - state: what the store knows about this course.
    ///   - courseId: the course this submenu belongs to. Every row's `ou=` comes
    ///     from *this* value rather than from `Assignment.courseId`, so a row in
    ///     course A's submenu structurally cannot carry course B's id — the one
    ///     failure this join newly makes possible, and one that fails silently
    ///     because the wrong page is still a real Brightspace page.
    ///   - now: decides overdue-versus-upcoming.
    ///   - timeZone: decides which calendar day an instant falls on. See `dueLabel`.
    public static func submenu(
        state: AssignmentsState,
        courseId: Int,
        now: Date,
        baseURL: URL,
        timeZone: TimeZone
    ) -> [MenuRow] {
        // `neverFetched` is the only state that yields nothing at all. Assignments
        // are deliberately not persisted, so this is every course's state at
        // launch: no submenu, and the course behaves exactly as it did before this
        // feature existed. A "Loading…" row would claim a fetch is in flight,
        // which nothing here knows to be true.
        guard state != .neverFetched else { return [] }

        let rows = self.rows(for: state.assignments, courseId: courseId, now: now,
                             baseURL: baseURL, timeZone: timeZone)

        switch state {
        case .neverFetched:
            return []  // unreachable, guarded above

        case .loaded:
            // An empty list here is data — the server said there are none.
            return rows.isEmpty ? [.message(Self.noAssignments)] : rows

        case .failed:
            // Failure must never blank a submenu that was showing real work a
            // minute ago. The separator appears only when rows precede the note;
            // with no rows it would abut the one `MenuAssembler` already prepends.
            guard !rows.isEmpty else { return [.message(Self.loadFailed)] }
            return rows + [.separator, .message(Self.refreshFailed)]
        }
    }

    /// Visible assignments, in menu order, as rows.
    private static func rows(
        for assignments: [Assignment],
        courseId: Int,
        now: Date,
        baseURL: URL,
        timeZone: TimeZone
    ) -> [MenuRow] {
        assignments
            // `IsHidden` is D2L's own "not visible to students" flag. Respecting
            // the source of truth beats second-guessing it, and a hidden folder is
            // also the case most likely to answer its deep link with an
            // access-denied page — the same wrong-destination failure the click
            // target rules exist to prevent.
            .filter { !$0.isHidden }
            .sorted(by: Self.precedes)
            .map { .assignment(self.row(for: $0, courseId: courseId, now: now,
                                        baseURL: baseURL, timeZone: timeZone)) }
    }

    private static func row(
        for assignment: Assignment,
        courseId: Int,
        now: Date,
        baseURL: URL,
        timeZone: TimeZone
    ) -> AssignmentRow {
        AssignmentRow(
            id: assignment.id,
            title: assignment.name,
            // Pre-formatted, because the view renders `subtitle` verbatim: date
            // formatting is policy (which zone, which wording) and policy lives
            // here. Nil, never "", so the GUI's "title — subtitle" join cannot
            // produce a dangling separator.
            subtitle: self.dueLabel(assignment.dueDate, now: now, timeZone: timeZone),
            // The raw value travels alongside the rendered one: sorting and any
            // future "due soon" filter need the instant, not the text.
            dueDate: assignment.dueDate,
            url: AssignmentLink.url(courseId: courseId, assignmentId: assignment.id, baseURL: baseURL)
        )
    }

    // MARK: - Order

    /// Menu order, as a total order — which is load-bearing, not decoration.
    /// Without a final tie-break, network- or `Dictionary`-derived input would
    /// reshuffle the submenu between refreshes, and `MenuModel`'s `Equatable` —
    /// which the GUI uses to skip rebuilding an unchanged menu — would compare
    /// unequal on identical data.
    ///
    /// Dated before undated, soonest deadline first, then name, then id. Today
    /// every reachable assignment is undated, so the whole list is name-sorted;
    /// when a real term brings due dates, deadlines float to the top with no code
    /// change.
    private static func precedes(_ a: Assignment, _ b: Assignment) -> Bool {
        switch (a.dueDate, b.dueDate) {
        case (let lhs?, let rhs?):
            if lhs != rhs { return lhs < rhs }
        case (_?, nil):
            return true   // a deadline outranks no deadline
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }
        // Plain `<`, not locale-aware: a locale-sensitive comparison would make
        // menu order depend on ambient state, which is what this whole layer
        // avoids.
        if a.name != b.name { return a.name < b.name }
        return a.id < b.id
    }

    // MARK: - The deadline line

    /// Fixed English abbreviations, indexed by month number.
    ///
    /// Deliberately a table rather than `DateFormatter` or `Date.FormatStyle`:
    /// both read `Locale.current`, which would make this pure function's output
    /// depend on ambient state and its tests depend on the machine they run on.
    private static let monthAbbreviations = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    /// The pre-formatted deadline the GUI renders verbatim, or nil when there is
    /// no due date — the common case, since all four currently reachable
    /// assignments have `DueDate: null`.
    ///
    /// Past deadlines read `"Overdue"` with the date dropped: once a deadline has
    /// passed the date is not the actionable part. The boundary is inclusive, so
    /// an assignment is not overdue at the instant it falls due — matching the
    /// convention the currentness policy already uses.
    ///
    /// `timeZone` is load-bearing rather than pedantic. D2L states deadlines as
    /// instants, and `2026-03-01T04:59:00Z` is 23:59 on **February 28** in
    /// Indiana. Formatting in the wrong zone tells a student their work is due
    /// March 1 when Brightspace will close it on February 28.
    public static func dueLabel(_ dueDate: Date?, now: Date, timeZone: TimeZone) -> String? {
        guard let dueDate else { return nil }
        guard dueDate >= now else { return "Overdue" }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Pinned so no ambient locale can reach the calendar's own behaviour.
        // Month and day numbers are locale-independent for the Gregorian
        // calendar; this makes that explicit rather than incidental.
        calendar.locale = Locale(identifier: "en_US_POSIX")

        let parts = calendar.dateComponents([.month, .day], from: dueDate)
        guard
            let month = parts.month, let day = parts.day,
            Self.monthAbbreviations.indices.contains(month - 1)
        else {
            // Unreachable for a Gregorian calendar, and answered by dropping the
            // date rather than by rendering something wrong: the assignment still
            // appears, just without a deadline line.
            return nil
        }
        // Day is interpolated, never padded — "Due Mar 1", not "Due Mar 01".
        return "Due \(Self.monthAbbreviations[month - 1]) \(day)"
    }
}
