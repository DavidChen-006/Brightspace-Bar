import Foundation
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

    /// The whole translation. Pinned by `MenuTranslationTests`; every rule below
    /// is specified there, not here.
    public static func menu(
        courses: [Course], lastFetch: Date?, now: Date, baseURL: URL
    ) -> MenuModel {
        // Cold start — nothing loaded, nothing fetched — is exactly the
        // placeholder, so the GUI's `Equatable` skip-rebuild sees one value.
        if courses.isEmpty && lastFetch == nil { return .placeholder }

        var rows: [MenuRow] = []
        if courses.isEmpty {
            // A successful fetch that returned zero courses is data, not a cold
            // start; the status row below is what distinguishes the two.
            rows.append(.message("No enrolled courses"))
        } else {
            rows.append(contentsOf: self.groupedCourseRows(courses, baseURL: baseURL))
        }
        rows.append(.separator)
        rows.append(.status(self.statusText(lastFetch: lastFetch, now: now)))
        rows.append(.command(.refresh))
        rows.append(.command(.quit))
        return MenuModel(rows: rows)
    }

    // MARK: - Grouping

    /// Header for courses whose code carries no term.
    private static let untermedHeader = "Other"

    /// `[.sectionHeader, .course...]` per term, newest term first, untermed last.
    private static func groupedCourseRows(_ courses: [Course], baseURL: URL) -> [MenuRow] {
        let grouped = Dictionary(grouping: courses) { self.term(of: $0.code) }

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
            return [.sectionHeader(group.header)] + sorted.map { .course(self.row(for: $0, baseURL: baseURL)) }
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

    private static func row(for course: Course, baseURL: URL) -> CourseRow {
        CourseRow(
            id: course.id,
            // Verbatim by design. Real names embed the term and code
            // ("Fall 2025 CS 25100-LEC - Merge"); stripping that is a
            // name-mangling heuristic deliberately deferred to a human call.
            title: course.name,
            subtitle: self.subtitle(from: course.code),
            url: self.url(id: course.id, baseURL: baseURL)
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

    // MARK: - Status

    /// Freshness line. Negative age folds into "just now": experiment 4 already
    /// treats a future timestamp as untrustworthy, and the menu must not display
    /// arithmetic ("Updated -3 minutes ago") at the user.
    private static func statusText(lastFetch: Date?, now: Date) -> String {
        guard let lastFetch else { return "Never updated" }
        let age = now.timeIntervalSince(lastFetch)
        if age < 60 { return "Updated just now" }
        if age < 3600 {
            let m = Int(age / 60)
            return "Updated \(m) minute\(m == 1 ? "" : "s") ago"
        }
        let h = Int(age / 3600)
        return "Updated \(h) hour\(h == 1 ? "" : "s") ago"
    }
}
