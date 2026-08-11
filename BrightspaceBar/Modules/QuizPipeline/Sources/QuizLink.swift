import Foundation

/// The click target for one quiz, derived from ids alone.
///
/// Pure functional core: two integers and a base URL in, a URL out. No I/O, no
/// state, no dependency on any payload field — the same shape as `AssignmentLink`
/// and for the same reason: D2L sends nothing usable as a link, so the destination
/// is *computed*, uniformly, for every quiz.
///
/// The template is measured, not guessed. A live probe on 2026-08-10 read the quiz
/// ids off `GET /d2l/api/le/1.96/{orgUnitId}/quizzes/`, and all four were then
/// navigated in a real browser, each loading a page whose `<h1>` named its own quiz:
///
///     {baseUrl}/d2l/lms/quizzing/user/quiz_summary.d2l?qi={quizId}&ou={orgUnitId}
///
/// Three silent failures this module exists to contain. Each produces a *real*
/// Brightspace page that is the wrong page, so nothing downstream can catch it —
/// `MenuAssembler` opens whatever URL it is handed.
///
/// - **`qi`/`ou` transposition.** Both halves are `Int` and both are plausible in
///   either slot. The labelled parameters are the defence: a caller has to name each
///   id, and `QuizLinkTests` pins all four browser-verified pairs.
/// - **The assignment template applied to a quiz.** `folder_submit_files.d2l?db=…`
///   with a quiz id is a well-formed dropbox URL for a folder that does not exist.
///   Unreachable here by construction: this file is the only builder of quiz links
///   and it names no dropbox path.
/// - **A `grpid` carried over from the sibling template.** Quizzes have no group
///   concept and the harvested href had no such parameter, so adding one would be
///   inventing a parameter D2L never sent. There is no group constant in this file
///   to leak.
public enum QuizLink {

    private static let path = "d2l/lms/quizzing/user/quiz_summary.d2l"

    /// The deep link for `quizId` inside `courseId`.
    ///
    /// `quiz_submissions.d2l?qi=…&ou=…` also resolves and shows past attempts; the
    /// summary page is the destination for "I owe this".
    ///
    /// - Parameters:
    ///   - courseId: the D2L org-unit id. Lands in `ou`.
    ///   - quizId: the D2L quiz id. Lands in `qi`.
    public static func url(courseId: Int, quizId: Int, baseURL: URL) -> URL {
        // `appending(path:)` normalises the join, so a caller passing
        // "https://host/" cannot produce "host//d2l/lms/...".
        let base = baseURL.appending(path: Self.path)

        // Query order is pinned to the href Brightspace's own markup carries — qi,
        // then ou.
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "qi", value: String(quizId)),
            URLQueryItem(name: "ou", value: String(courseId)),
        ]

        // The components are built from an already-valid URL plus digit-only query
        // values, so this cannot fail; falling back to `base` keeps the signature
        // non-optional rather than pushing an impossible case onto every caller.
        return components?.url ?? base
    }
}
