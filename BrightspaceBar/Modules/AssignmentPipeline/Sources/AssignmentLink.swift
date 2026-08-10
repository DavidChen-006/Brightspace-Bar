import Foundation

/// The click target for one assignment, derived from ids alone.
///
/// Pure functional core: two integers and a base URL in, a URL out. No I/O, no
/// state, no dependency on any payload field — which is the whole point. D2L
/// sends nothing usable as a link (see the `LinkAttachments` note below), so the
/// destination is *computed*, and computing it from ids means every assignment
/// gets one, uniformly.
///
/// The template is not guessed. Experiment 7 harvested it from Brightspace's own
/// rendered markup and then navigated three distinct folder ids in a real
/// browser, each of which loaded a page naming its own folder:
///
///     {baseUrl}/d2l/lms/dropbox/user/folder_submit_files.d2l?db={folderId}&grpid=0&ou={orgUnitId}
///
/// Two hazards this module exists to contain:
///
/// - **`db`/`ou` transposition.** Both halves are `Int` and both are plausible in
///   either slot, so a swap compiles and yields a well-formed URL that quietly
///   opens the wrong page. The labelled parameters are the defence: a caller has
///   to name each id, and `AssignmentLinkTests` pins all four real pairs.
/// - **`LinkAttachments[].Href`.** It looks like a link to the assignment and is
///   not — it is an instructor-attached *external* resource. Nothing here reads
///   the payload at all, so that trap is unreachable by construction.
public enum AssignmentLink {

    private static let path = "d2l/lms/dropbox/user/folder_submit_files.d2l"

    /// Group id. Zero for every assignment we can currently reach, and
    /// **unverified for group-based folders**: `GroupTypeId` is null on all four
    /// assignments in the two accessible courses, so no observation exists of
    /// what a real group assignment needs here. Pinned by `grpidIsZero` so that
    /// changing it has to be a deliberate act.
    private static let groupId = "0"

    /// The deep link for `assignmentId` inside `courseId`.
    ///
    /// - Parameters:
    ///   - courseId: the D2L org-unit id. Lands in `ou`.
    ///   - assignmentId: the D2L dropbox folder id. Lands in `db`.
    public static func url(courseId: Int, assignmentId: Int, baseURL: URL) -> URL {
        // `appending(path:)` normalises the join, so a caller passing
        // "https://host/" cannot produce "host//d2l/lms/...".
        let base = baseURL.appending(path: Self.path)

        // Query order is pinned to Brightspace's own markup — db, grpid, ou —
        // rather than sorted or dictionary-ordered. It costs nothing and is the
        // cheapest insurance against a D2L change that turns out to care.
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "db", value: String(assignmentId)),
            URLQueryItem(name: "grpid", value: Self.groupId),
            URLQueryItem(name: "ou", value: String(courseId)),
        ]

        // The components are built from an already-valid URL plus digit-only
        // query values, so this cannot fail; falling back to `base` keeps the
        // signature non-optional rather than pushing an impossible case onto
        // every caller.
        return components?.url ?? base
    }
}
