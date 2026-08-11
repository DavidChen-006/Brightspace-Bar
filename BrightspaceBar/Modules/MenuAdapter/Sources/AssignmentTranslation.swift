import Foundation
import AssignmentPipeline
import CourseMenu
import CoursePipeline
import QuizPipeline

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

    // MARK: - Sections

    /// The order kinds appear in, and the label each gets.
    ///
    /// A list rather than a switch so the order is stated once, in one place, and
    /// cannot drift from the labels. Assignments come first: they are the kind that
    /// shipped, they are what a dropbox deadline usually means, and a stable order
    /// matters more than which order.
    private static let sections: [(kind: ItemKind, header: String)] = [
        (.assignment, "Assignments"),
        (.quiz, "Quizzes"),
    ]

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

    /// Visible items, grouped by kind into optionally-labelled sections, each in
    /// menu order.
    ///
    /// Headers appear **only when both kinds have visible rows**. A header exists to
    /// disambiguate, and with one kind present there is nothing to disambiguate — so
    /// a lone "Quizzes" label would be noise, and a lone "Assignments" label would
    /// add a row to every submenu that shipped without one. A kind whose only items
    /// are hidden therefore contributes no header either: labelling it would imply
    /// the student is missing something.
    ///
    /// Sections are the OUTER sort key. A quiz due sooner than an assignment stays
    /// under Quizzes rather than jumping the boundary; cross-kind deadline ordering
    /// is what a future "what's due this week" view is for, and that would read the
    /// unified item list directly rather than the submenu.
    private static func rows(
        for items: [Assignment],
        courseId: Int,
        now: Date,
        baseURL: URL,
        timeZone: TimeZone
    ) -> [MenuRow] {
        // `isHidden` is D2L's own "not visible to students" flag — `IsHidden` on a
        // dropbox folder, `IsActive: false` on a quiz, which `QuizParser` maps onto
        // this same field so one policy covers both kinds. Respecting the source of
        // truth beats second-guessing it, and a hidden item is also the case most
        // likely to answer its deep link with an access-denied page.
        let visible = items.filter { !$0.isHidden }

        let populated = Self.sections.compactMap { section -> (header: String, items: [Assignment])? in
            let group = visible.filter { $0.kind == section.kind }.sorted(by: Self.precedes)
            return group.isEmpty ? nil : (section.header, group)
        }
        let labelled = populated.count > 1

        return populated.flatMap { section in
            (labelled ? [MenuRow.sectionHeader(section.header)] : [])
                + section.items.map {
                    .assignment(self.row(for: $0, courseId: courseId, now: now,
                                         baseURL: baseURL, timeZone: timeZone))
                }
        }
    }

    private static func row(
        for item: Assignment,
        courseId: Int,
        now: Date,
        baseURL: URL,
        timeZone: TimeZone
    ) -> AssignmentRow {
        AssignmentRow(
            id: item.id,
            title: item.name,
            // Pre-formatted, because the view renders `subtitle` verbatim: date
            // formatting is policy (which zone, which wording) and policy lives
            // here. Nil, never "", so the GUI's "title — subtitle" join cannot
            // produce a dangling separator.
            subtitle: self.dueLabel(item.dueDate, now: now, timeZone: timeZone),
            // The raw value travels alongside the rendered one: sorting and any
            // future "due soon" filter need the instant, not the text.
            dueDate: item.dueDate,
            url: Self.clickTarget(for: item, courseId: courseId, baseURL: baseURL)
        )
    }

    /// The one place the two deep-link templates are chosen between.
    ///
    ///     .assignment  →  …/dropbox/user/folder_submit_files.d2l?db={id}&grpid=0&ou={courseId}
    ///     .quiz        →  …/quizzing/user/quiz_summary.d2l?qi={id}&ou={courseId}
    ///
    /// Both browser-verified. Every way of choosing wrong yields a *real* Brightspace
    /// page that is the wrong one, and nothing downstream can catch it because
    /// `MenuAssembler` opens whatever URL it is handed. Two structural defences:
    ///
    /// - The switch is exhaustive with no `default`, so adding a third `ItemKind` is a
    ///   compile error here rather than a silently mistemplated row.
    /// - Neither builder can produce the other's parameters: `AssignmentLink` names no
    ///   quizzing path and `QuizLink` names no `db` or `grpid`. `grpid` on a quiz is
    ///   unreachable rather than merely untested.
    ///
    /// `ou` comes from `courseId` — the course whose submenu this is — never from
    /// `item.courseId`, so a row structurally cannot carry another course's id even if
    /// a fan-out bug stamped one.
    private static func clickTarget(for item: Assignment, courseId: Int, baseURL: URL) -> URL {
        switch item.kind {
        case .assignment:
            AssignmentLink.url(courseId: courseId, assignmentId: item.id, baseURL: baseURL)
        case .quiz:
            QuizLink.url(courseId: courseId, quizId: item.id, baseURL: baseURL)
        }
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
