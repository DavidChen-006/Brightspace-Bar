import Foundation

/// The click target for one course's gradebook — where a heads-up row goes.
///
/// Pure functional core, the same shape as `AssignmentLink` and `QuizLink`: an id
/// and a base URL in, a URL out, no I/O and no payload field read. What differs is
/// what it does *not* take. A heads-up row is a gradebook column, and D2L's
/// gradebook is one page per course, so there is no per-column deep link:
///
///     {baseUrl}/d2l/lms/grades/my_grades/main.d2l?ou={orgUnitId}
///
/// The template is the daemon's too — it precomputes the same URL into each
/// gradeOnly item — but the translation layer builds its own from the submenu's
/// course id for the reason both sibling templates do: a stamped id can be wrong,
/// and another class's grades is a real page.
///
/// The failure this module exists to contain is the column id leaking into a slot
/// that takes one. A `GradeObjectId` in `db=` is a well-formed link to a dropbox
/// folder that does not exist and in `qi=` to a quiz that does not exist, and each
/// looks completely normal doing it. There is no item-id parameter here, so the
/// mistake is unreachable rather than merely untested.
public enum GradebookLink {

    private static let path = "d2l/lms/grades/my_grades/main.d2l"

    /// The gradebook page for `courseId`.
    ///
    /// - Parameter courseId: the D2L org-unit id. Lands in `ou`, the only variable
    ///   this template has.
    public static func url(courseId: Int, baseURL: URL) -> URL {
        // `appending(path:)` normalises the join, so a caller passing
        // "https://host/" cannot produce "host//d2l/lms/...".
        let base = baseURL.appending(path: Self.path)

        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "ou", value: String(courseId))]

        // The components are built from an already-valid URL plus a digit-only
        // query value, so this cannot fail; falling back to `base` keeps the
        // signature non-optional rather than pushing an impossible case onto every
        // caller.
        return components?.url ?? base
    }
}
