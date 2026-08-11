import Foundation
import CoursePipeline

// ─────────────────────────────────────────────────────────────────────────────
// The values this module trades in.
//
// `CacheOutcome` and `CourseSourceError` are deliberately NOT redefined here —
// they come from `CoursePipeline`. Two backend modules with two vocabularies for
// "the fetch failed, keep what you had" would be two places to keep in sync, and
// the translation layer would have to speak both.
// ─────────────────────────────────────────────────────────────────────────────

/// Which D2L entity an item is.
///
/// The two kinds share everything the pipeline does — fan-out, folding,
/// success-replaces/failure-preserves, orphan cleanup — and differ only in three
/// places: the route they are fetched from, the decoder that reads them, and the
/// deep-link template they open. So the kind travels as a *field* rather than as a
/// second type, and the only code that switches on it is the link builder.
///
/// `CaseIterable` so a future third kind (a graded discussion, a checklist) is
/// discoverable rather than hidden inside a switch.
public enum ItemKind: Equatable, Sendable, CaseIterable {
    case assignment
    case quiz
}

/// One piece of work the student owes in a course — a dropbox assignment or a quiz.
///
/// Faithful preservation, matching the `Course` precedent: fields arrive as D2L
/// sent them and nothing here is interpreted. In particular `isHidden` and
/// `groupTypeId` are carried but never acted on — whether a hidden assignment
/// should appear in a menu is a display policy, and burying it in a parser would
/// put it where no test thinks to look.
///
/// The name is now slightly historical: this type holds quizzes too. Renaming it
/// (along with `AssignmentsState`, `AssignmentStore` and `AssignmentFetcher`) would
/// churn every existing call site for no behavioural gain, so the debt is noted
/// rather than paid.
public struct Assignment: Equatable, Sendable, Identifiable {
    /// D2L dropbox folder id, or quiz id. Unique within a course *and kind*, and
    /// the id half of the deep link — `db=` for an assignment, `qi=` for a quiz.
    public let id: Int
    /// The org unit this was fetched for — the `ou=` half of the deep link.
    ///
    /// **Not present in the payload.** D2L returns folders for a course without
    /// naming the course, so this is stamped from the request. An unstamped
    /// assignment renders a perfectly correct name pointing at course 0.
    public let courseId: Int
    /// The assignment's name, as shown to the student.
    public let name: String
    /// `DueDate`, or nil when D2L sent none.
    ///
    /// Nil is the *normal* case in every course currently reachable: all four
    /// real assignments have `DueDate: null`, because both accessible courses are
    /// self-paced shells. A sentinel or epoch date here would render as a
    /// deadline that does not exist.
    public let dueDate: Date?
    /// `IsHidden`. Preserved, not acted on.
    public let isHidden: Bool
    /// `GroupTypeId`, non-nil for a group assignment. Preserved, not acted on —
    /// and worth watching, because `AssignmentLink`'s hardcoded `grpid=0` is
    /// unverified for exactly these. Always nil for a quiz: quizzes have no group
    /// concept and their deep link has no group parameter.
    public let groupTypeId: Int?
    /// Which entity this is. Decides the deep-link template and which section of a
    /// submenu the row lands in.
    ///
    /// Part of `Equatable`, deliberately: `AssignmentStore` decides `.unchanged` by
    /// comparing lists, so a same-id assignment replaced by a quiz has to register
    /// as a change or the menu would never rebuild.
    public let kind: ItemKind

    /// `kind` comes last and defaults to `.assignment` so every call site written
    /// before quizzes existed still compiles, and so the common case reads the way
    /// it always did.
    public init(
        id: Int,
        courseId: Int,
        name: String,
        dueDate: Date?,
        isHidden: Bool,
        groupTypeId: Int?,
        kind: ItemKind = .assignment
    ) {
        self.id = id
        self.courseId = courseId
        self.name = name
        self.dueDate = dueDate
        self.isHidden = isHidden
        self.groupTypeId = groupTypeId
        self.kind = kind
    }
}

/// Anything that can produce one course's assignments.
///
/// Two implementations exist by design — a scriptable fake for tests and the real
/// network adapter — and `AssignmentSourceContractTests` runs both through one set
/// of claims so the fake cannot drift.
public protocol AssignmentSource: Sendable {
    func fetchAssignments(courseId: Int) async throws -> [Assignment]
}

/// What is known about one course's assignments.
///
/// Three cases, and keeping them distinct is load-bearing. Collapse
/// `neverFetched` into `loaded([])` and a course that has not loaded yet claims
/// to have no work; collapse `failed` into `loaded([])` and a dead session
/// silently empties a submenu that was showing real assignments a minute ago.
public enum AssignmentsState: Equatable, Sendable {
    /// No fetch has been attempted. The state at launch.
    case neverFetched
    /// A fetch succeeded. An empty array here is *data*: the course genuinely has
    /// no assignments.
    case loaded([Assignment])
    /// A fetch failed. `lastKnown` is whatever was loaded before — possibly
    /// empty, if the very first fetch failed.
    case failed(lastKnown: [Assignment], error: CourseSourceError)

    /// The best available list, whatever the state. Lets the translation layer
    /// render rows without switching, and switch only to decide what *note* to
    /// add alongside them.
    public var assignments: [Assignment] {
        switch self {
        case .neverFetched: []
        case .loaded(let assignments): assignments
        case .failed(let lastKnown, _): lastKnown
        }
    }
}
