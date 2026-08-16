import Foundation
import AssignmentPipeline
import CourseMenu

// ─────────────────────────────────────────────────────────────────────────────
// SEAM: [Announcement] → the tail of CourseRow.submenu. The join's second half.
//
//   AssignmentPipeline.AnnouncementsState  ← backend vocabulary (left of here)
//   CourseMenu.MenuRow / AnnouncementRow   ← frontend vocabulary (right of here)
//
// Built exactly like `AssignmentTranslation` and for the same reasons: a pure
// function with `now` and `timeZone` as parameters, so nothing here reads a
// clock, a locale, or the world, and every display decision is made once, on
// this side of the contract.
//
// What differs is the KIND of list. Assignments are a set — all of them, ordered
// by deadline, because every one is work still owed. Announcements are a window:
// the recent few, newest first, capped. A course accumulates announcements
// forever and only the last few weeks are news, so this half is defined by what
// it LEAVES OUT, which is why the cutoff and the cap are the whole feature.
//
// It is also a SUFFIX. `MenuTranslation` appends these rows to whatever
// `AssignmentTranslation.submenu` produced, so this function can only ever be
// additive: with nothing to say it returns `[]` and the submenu is exactly what
// it was before announcements existed.
// ─────────────────────────────────────────────────────────────────────────────
public enum AnnouncementTranslation {

    /// The section's label. Mandatory whenever there are rows, unlike the
    /// assignments half's conditional headers: these rows are appended BELOW rows
    /// of another kind, so without a label they read as more assignments.
    static let header = "Announcements"

    /// How far back the window reaches.
    ///
    /// A fixed interval rather than 30 calendar days: a span this long is not
    /// anchored to a wall-clock boundary in the first place, and an elapsed-time
    /// cutoff cannot be moved by a daylight-saving transition inside the window.
    static let window: TimeInterval = 30 * 24 * 60 * 60

    /// How many rows the section may hold.
    ///
    /// A submenu that grew without bound would push the assignments above it —
    /// the half a student actually acts on — off the top of a long dropdown.
    static let limit = 5

    // MARK: - The section

    /// The announcements rows for ONE course, appended after its assignments.
    /// Pinned by `AnnouncementTranslationTests`; every rule below is specified
    /// there, not here.
    ///
    /// Empty when there is nothing recent to show — including `neverFetched`,
    /// `loaded([])`, an all-stale course, and a failure with nothing known. This
    /// is the OPPOSITE of `AssignmentTranslation`'s "No assignments" line, and
    /// deliberately so: that line exists because a submenu with no rows at all
    /// gets no NSMenu and therefore a different interaction model, whereas the
    /// assignments half has already guaranteed this submenu exists. Silence here
    /// costs nothing; a permanent empty section would cost two rows of noise in
    /// every course that does not use the feature.
    ///
    /// - Parameters:
    ///   - state: what the store knows about this course's announcements. Each
    ///     state is read through `lastKnown`/`loaded` uniformly — a failure
    ///     renders whatever survived it, SILENTLY, because the assignments half
    ///     of this same submenu already carries the staleness note and both
    ///     routes fail together on one dead session.
    ///   - courseId: the course this section belongs to. Every row's `ou=` comes
    ///     from *this* value rather than from `Announcement.courseId`, so a row in
    ///     course A's section structurally cannot carry course B's id — the same
    ///     silent failure the assignments join guards against, made possible again
    ///     by a second per-course fan-out.
    ///   - now: the window's upper edge as well as its anchor. Nothing posted
    ///     after it is shown.
    ///   - timeZone: decides which calendar day an instant falls on. See
    ///     `postedLabel`.
    public static func section(
        state: AnnouncementsState,
        courseId: Int,
        now: Date,
        baseURL: URL,
        timeZone: TimeZone
    ) -> [MenuRow] {
        let rows = self.rows(
            for: state.announcements, courseId: courseId,
            now: now, baseURL: baseURL, timeZone: timeZone
        )
        // `neverFetched` needs no branch of its own: it holds nothing, so it
        // reaches this guard with no rows, which is the answer it wanted anyway.
        guard !rows.isEmpty else { return [] }
        return [.separator, .sectionHeader(Self.header)] + rows
    }

    /// The qualifying announcements, newest first, capped.
    ///
    /// Filter, then sort, then cap — in that order, and the order is load-bearing
    /// twice over. Capping before filtering would spend the five slots on posts
    /// that are then thrown away; capping before sorting would keep the five that
    /// happened to arrive first rather than the five that are newest.
    private static func rows(
        for items: [Announcement],
        courseId: Int,
        now: Date,
        baseURL: URL,
        timeZone: TimeZone
    ) -> [MenuRow] {
        items
            .filter { Self.qualifies($0, now: now) }
            .sorted(by: Self.precedes)
            .prefix(Self.limit)
            .map {
                .announcement(self.row(
                    for: $0, courseId: courseId, baseURL: baseURL, timeZone: timeZone
                ))
            }
    }

    /// Dated, not older than the window, not in the future.
    ///
    /// Undated items are excluded because a cutoff cannot be applied to a date
    /// that does not exist — and this list is ordered entirely by age, so an item
    /// of unknown age has no correct position in it either.
    ///
    /// Future-dated items are excluded because a `StartDate` ahead of `now` is a
    /// post D2L has SCHEDULED and not yet published: showing it announces
    /// something the student cannot go and read.
    ///
    /// Both boundaries are inclusive, matching the convention `dueLabel` and the
    /// currentness policy already use.
    private static func qualifies(_ item: Announcement, now: Date) -> Bool {
        guard let date = item.date else { return false }
        return date >= now.addingTimeInterval(-Self.window) && date <= now
    }

    /// Menu order, as a total order — load-bearing, not decoration.
    ///
    /// Newest first: a posting date is a past you catch up on, so the most recent
    /// post is the one you have not seen. (The assignments half sorts the other
    /// way for the mirror-image reason: a deadline is a future you act on, so the
    /// soonest leads.)
    ///
    /// The `id` tie-break is what makes the order total. Swift's sort is not
    /// stable, and two posts sharing an instant is routine when a department
    /// posts a batch — without it they would swap places between refreshes AND
    /// change which five survive the cap, so identical data would compare unequal
    /// and `MenuModel`'s `Equatable` skip-rebuild would fire on every tick.
    private static func precedes(_ a: Announcement, _ b: Announcement) -> Bool {
        // Both dates are non-nil by the time this runs — `qualifies` has already
        // dropped the undated — but the comparison stays total rather than
        // force-unwrapping a guarantee that lives in another function.
        let lhs = a.date ?? .distantPast
        let rhs = b.date ?? .distantPast
        if lhs != rhs { return lhs > rhs }
        return a.id < b.id
    }

    private static func row(
        for item: Announcement,
        courseId: Int,
        baseURL: URL,
        timeZone: TimeZone
    ) -> AnnouncementRow {
        AnnouncementRow(
            id: item.id,
            // Verbatim. Real titles are sentences with their own punctuation, and
            // reformatting them is a decision nobody asked for.
            title: item.title,
            // Pre-formatted, because the view renders `subtitle` verbatim: date
            // formatting is policy (which zone, which wording) and policy lives
            // here.
            subtitle: self.postedLabel(item.date, timeZone: timeZone),
            // The raw value travels alongside the rendered one, for the same
            // reason `AssignmentRow.dueDate` does: sorting and any future "since
            // you last looked" filter need the instant, not the text.
            date: item.date,
            // Uniformly the course's announcements page, from the courseId
            // PARAMETER. D2L offers no per-item deep link worth trusting across
            // tenants, so one destination per course is the design rather than a
            // shortcut — and it leaves nothing per-row to get wrong.
            url: AnnouncementLink.url(courseId: courseId, baseURL: baseURL)
        )
    }

    // MARK: - The posting date line

    /// Fixed English abbreviations, indexed by month number.
    ///
    /// Deliberately a table rather than `DateFormatter` or `Date.FormatStyle`:
    /// both read `Locale.current`, which would make this pure function's output
    /// depend on ambient state and its tests depend on the machine they run on.
    /// Restated rather than borrowed from `AssignmentTranslation` so this file
    /// stays self-contained; the English month names are not going to drift.
    private static let monthAbbreviations = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    /// The pre-formatted posting date the GUI renders verbatim, e.g. `Aug 10`.
    ///
    /// ABSOLUTE, never "3 days ago". A relative string is computed at model-build
    /// time and is already wrong by the time the menu is opened — the exact
    /// staleness experiment 18 removed from the status row, and the reason
    /// `StatusStamp` carries a `Date` instead of a sentence. An absolute date does
    /// not move, so the row cannot go stale between builds.
    ///
    /// No year: everything here is inside a 30-day window, so the year is never
    /// in question and would only lengthen a row the title already fills.
    ///
    /// `timeZone` is load-bearing rather than pedantic, exactly as it is for
    /// deadlines: `2026-08-11T02:30:00Z` is 22:30 on **August 10** in Indiana, and
    /// telling a student a post they read last night landed today is a small lie
    /// with no upside.
    private static func postedLabel(_ date: Date?, timeZone: TimeZone) -> String? {
        guard let date else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Pinned so no ambient locale can reach the calendar's own behaviour.
        calendar.locale = Locale(identifier: "en_US_POSIX")

        let parts = calendar.dateComponents([.month, .day], from: date)
        guard
            let month = parts.month, let day = parts.day,
            Self.monthAbbreviations.indices.contains(month - 1)
        else {
            // Unreachable for a Gregorian calendar, and answered by dropping the
            // date rather than by rendering something wrong: the announcement
            // still appears, just without a posting line.
            return nil
        }
        // Day is interpolated, never padded — "Aug 5", not "Aug 05".
        return "\(Self.monthAbbreviations[month - 1]) \(day)"
    }
}
