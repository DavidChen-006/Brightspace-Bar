import Foundation
import AssignmentPipeline
import CourseMenu
import CoursePipeline

// ─────────────────────────────────────────────────────────────────────────────
// SEAM: backend → frontend, as a pure function.
//
// This is the one translation the contract deliberately excludes: experiment 4's
// `[Course]` (backend vocabulary) becomes `MenuModel` (frontend vocabulary) here
// and nowhere else. Everything on the left of this function is CoursePipeline;
// everything on the right is CourseMenu. Neither side knows the other exists.
//
// Functional core: no I/O, no clock, no state — `now` is a parameter. Every data
// assertion in the test suite lands on this function with plain values.
// ─────────────────────────────────────────────────────────────────────────────
public enum MenuTranslation {

    /// The whole translation. Pinned by `MenuTranslationTests`,
    /// `CurrentnessTests`, and `AssignmentWiringTests`; every rule below is
    /// specified there, not here.
    ///
    /// - Parameters:
    ///   - assignments: what is known about each course's assignments, keyed by
    ///     course id. A course absent from the map is `neverFetched`, which now
    ///     yields the same "No assignments" submenu as a fetch that found none:
    ///     the `[:]` default no longer reproduces the pre-assignment output, because
    ///     making submenu presence depend on whether a fetch had happened gave
    ///     identical-looking rows two different interaction models.
    ///   - announcements: what is known about each course's announcements, keyed
    ///     the same way. A course absent from the map is `neverFetched`, which
    ///     contributes NO rows — so unlike `assignments`, the `[:]` default
    ///     reproduces the pre-announcement output exactly. The section is a
    ///     suffix on a submenu that already exists, so it can only be additive.
    ///   - timeZone: which zone deadline dates are rendered in. A parameter for
    ///     the same reason `now` is — a pure function may not read ambient state.
    ///     `.current` belongs in the composition root.
    ///   - nextRefresh: when the next automatic refresh fires, or nil for a
    ///     build with no timer (the stub path, most tests). Emitted as a date,
    ///     never a string: status rows carry `StatusStamp`s and the GUI formats
    ///     them against its own fresh `now` at menu-open (experiment 18).
    public static func menu(
        courses: [Course],
        lastFetch: Date?,
        now: Date,
        baseURL: URL,
        assignments: [Int: AssignmentsState] = [:],
        announcements: [Int: AnnouncementsState] = [:],
        timeZone: TimeZone = .current,
        nextRefresh: Date? = nil
    ) -> MenuModel {
        // Cold start — nothing loaded, nothing fetched — is exactly the
        // placeholder, so the GUI's `Equatable` skip-rebuild sees one value.
        if courses.isEmpty && lastFetch == nil { return .placeholder }

        let visible = self.visibleCourses(courses, now: now)
        let hasCurrent = visible.contains { self.isCurrent($0, now: now) }

        var rows: [MenuRow] = []
        if courses.isEmpty {
            // A successful fetch that returned zero courses is data, not a cold
            // start; the status row below is what distinguishes the two.
            rows.append(.message("No enrolled courses"))
        } else {
            if !hasCurrent {
                // Semester break, honestly stated — the alternative readings
                // ("app broke" / "still showing last term") are both worse.
                rows.append(.message("No current courses"))
            }
            rows.append(contentsOf: self.groupedCourseRows(
                visible, baseURL: baseURL, assignments: assignments,
                announcements: announcements, now: now, timeZone: timeZone
            ))
        }
        rows.append(.separator)
        if let nextRefresh {
            rows.append(.status(.nextRefresh(nextRefresh)))
        }
        rows.append(.command(.refresh))
        rows.append(.command(.quit))
        return MenuModel(rows: rows)
    }

    /// The courses this menu would render, given `now`.
    ///
    /// Public because it answers a question the shell also has to ask: which
    /// courses are worth spending a network request on. Sharing the one filter is
    /// what keeps "what we fetch" and "what we show" from drifting — fanning out
    /// over all 27 enrollments would waste calls on ended courses that answer 403.
    ///
    /// The currentness policy (user decision, 2026-08-09): what is being taken NOW
    /// plus the undated administrative shells; ended and not-yet-started terms are
    /// hidden. `IsActive` is deliberately not consulted — it is true for every
    /// enrollment back to Fall 2024 (measured).
    public static func visibleCourses(_ courses: [Course], now: Date) -> [Course] {
        courses.filter { self.isCurrent($0, now: now) || self.isUndated($0) }
    }

    // MARK: - Currentness (pure policy on Access dates)

    /// Start ≤ now ≤ end, inclusive; a missing or unparseable bound is open.
    /// Fully undated courses are NOT current — they are a separate class
    /// (`isUndated`) rendered under "Other".
    private static func isCurrent(_ course: Course, now: Date) -> Bool {
        if self.isUndated(course) { return false }
        let start = self.parseDate(course.startDate)
        let end = self.parseDate(course.endDate)
        return (start.map { $0 <= now } ?? true) && (end.map { $0 >= now } ?? true)
    }

    /// No usable date on either side — the administrative shells (Civics Test,
    /// Scholarly Project Milestones). Also where unparseable dates degrade to:
    /// if D2L ever changes its wire format, courses fail OPEN into "Other"
    /// instead of silently vanishing.
    private static func isUndated(_ course: Course) -> Bool {
        self.parseDate(course.startDate) == nil && self.parseDate(course.endDate) == nil
    }

    /// D2L sends `2025-08-14T04:00:00.000Z`. `ISO8601FormatStyle` is strict
    /// about fractional seconds, so both variants are tried. Pure: a value in,
    /// a value out, no formatter state.
    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return (try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(raw, strategy: .iso8601))
    }

    // MARK: - Grouping

    /// Header for courses whose code carries no term.
    private static let untermedHeader = "Other"

    /// `[.sectionHeader, .course...]` per term, newest term first, untermed last.
    /// Undated courses group under "Other" even when their code carries a term:
    /// with no dates, "which semester is this?" is unanswerable, and filing it
    /// under a term header would claim otherwise.
    private static func groupedCourseRows(
        _ courses: [Course],
        baseURL: URL,
        assignments: [Int: AssignmentsState],
        announcements: [Int: AnnouncementsState],
        now: Date,
        timeZone: TimeZone
    ) -> [MenuRow] {
        let grouped = Dictionary(grouping: courses) {
            self.isUndated($0) ? nil : self.term(of: $0.code)
        }

        // Dictionaries have no iteration order, so BOTH levels are sorted
        // explicitly — otherwise the menu would reshuffle between refreshes and
        // `MenuModel`'s `Equatable` (which the GUI uses to skip rebuilding)
        // would compare unequal on identical data.
        var groups: [(header: String, courses: [Course])] = grouped
            .compactMap { key, value in key.map { ($0, value) } }
            .sorted { $0.header > $1.header }  // raw term codes, descending = newest first
        if let untermed = grouped[nil] {
            groups.append((self.untermedHeader, untermed))
        }

        return groups.flatMap { group -> [MenuRow] in
            // Intra-group order: code ascending (id breaks ties for determinism).
            let sorted = group.courses.sorted { ($0.code, $0.id) < ($1.code, $1.id) }
            // A `.hairline` leads EVERY course (NewVertical-3 §3.1). Stated as
            // "before each course" rather than "between courses" because that is
            // the form with no fence posts to get wrong: one boundary per course,
            // never two adjacent, never trailing, and a group of one still gets
            // its line under the header.
            return [.sectionHeader(group.header)] + sorted.flatMap { course -> [MenuRow] in
                [.hairline, .course(self.row(
                    for: course, baseURL: baseURL,
                    // Absent key == `neverFetched`, which `AssignmentTranslation`
                    // renders as "No assignments" — the same rows as loaded-empty,
                    // so every course row carries a submenu either way.
                    assignments: assignments[course.id] ?? .neverFetched,
                    // Absent key == `neverFetched`, which contributes no rows at
                    // all — so a menu built without announcements is byte-identical
                    // to the one this function produced before they existed.
                    announcements: announcements[course.id] ?? .neverFetched,
                    now: now, timeZone: timeZone
                ))]
            }
        }
    }

    /// The term component of a code like `wl.202610.CS.25100.LE1` → `"202610"`;
    /// nil for shapes like `stars_2025` or `wl.nc.civics.test`.
    private static func term(of code: String) -> String? {
        let parts = code.components(separatedBy: ".")
        guard parts.count >= 2, self.isDigits(parts[1], exactly: 6) else { return nil }
        return parts[1]
    }

    // MARK: - Per-course derivations

    private static func row(
        for course: Course,
        baseURL: URL,
        assignments: AssignmentsState,
        announcements: AnnouncementsState,
        now: Date,
        timeZone: TimeZone
    ) -> CourseRow {
        CourseRow(
            id: course.id,
            // Verbatim by design. Real names embed the term and code
            // ("Fall 2025 CS 25100-LEC - Merge"); stripping that is a
            // name-mangling heuristic deliberately deferred to a human call.
            title: course.name,
            subtitle: self.subtitle(from: course.code),
            url: self.url(id: course.id, baseURL: baseURL),
            // SEAM: the two submenu joins. Each translation owns every decision
            // inside its own half; this only says which course they are for,
            // which is what guarantees a row can never carry another course's id.
            //
            // Two translations rather than one because the halves answer two
            // different questions — what you owe, then what was said — and the
            // work leads because it is the half a student acts on. The
            // announcements section is a pure SUFFIX: with nothing recent to show
            // it is `[]`, and the submenu is exactly what it was before.
            submenu: AssignmentTranslation.submenu(
                state: assignments, courseId: course.id,
                now: now, baseURL: baseURL, timeZone: timeZone
            ) + AnnouncementTranslation.section(
                state: announcements, courseId: course.id,
                now: now, baseURL: baseURL, timeZone: timeZone
            ),
            // SEAM: the graph join, over the same state the submenu reads.
            // `neverFetched` yields `[]`, so a course absent from the map keeps
            // the pre-graph row it had before this feature existed.
            graph: GraphTranslation.strip(state: assignments, now: now, timeZone: timeZone),
            // The headings for that same window, from the same `now` and zone —
            // two clocks here would head one menu with columns and another with
            // the months of a different week.
            graphMonths: GraphTranslation.monthLabels(now: now, timeZone: timeZone)
        )
    }

    /// The click target, derived from `id` uniformly for EVERY course.
    ///
    /// `Course.homeUrl` is deliberately never read: it is null for 25 of 27 real
    /// enrollments, and a menu where two rows follow a different rule is worse
    /// than one that ignores the field entirely.
    private static func url(id: Int, baseURL: URL) -> URL {
        // `appending(path:)` normalises the joining slash, so a caller passing
        // "https://host/" cannot produce ".../d2l/home//412690".
        baseURL.appending(path: "d2l/home/\(id)")
    }

    /// `wl.202610.CS.25100.LE1` → `"CS 25100"`; undecodable shapes → nil.
    /// A nil subtitle never drops the course — it just renders without one.
    private static func subtitle(from code: String) -> String? {
        let parts = code.components(separatedBy: ".")
        guard
            parts.count >= 5,
            self.isDigits(parts[1], exactly: 6),
            !parts[3].isEmpty, self.isDigits(parts[3])
        else { return nil }
        return "\(parts[2]) \(parts[3])"
    }

    private static func isDigits(_ s: String, exactly count: Int? = nil) -> Bool {
        if let count, s.count != count { return false }
        return s.allSatisfy(\.isNumber) && s.allSatisfy(\.isASCII)
    }

    // The status row now carries only the next-refresh date; the GUI formats it
    // against a fresh `now` when the menu opens (experiment 18). `lastFetch`
    // survives as a parameter for one reason — the cold-start test above, which
    // tells a never-fetched app (placeholder) from a fetch that found no courses
    // ("No enrolled courses").
}
