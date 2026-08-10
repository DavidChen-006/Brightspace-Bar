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

/// One assignment, already parsed out of D2L's `dropbox/folders` payload.
///
/// Faithful preservation, matching the `Course` precedent: fields arrive as D2L
/// sent them and nothing here is interpreted. In particular `isHidden` and
/// `groupTypeId` are carried but never acted on — whether a hidden assignment
/// should appear in a menu is a display policy, and burying it in a parser would
/// put it where no test thinks to look.
public struct Assignment: Equatable, Sendable, Identifiable {
    /// D2L dropbox folder id. Unique within a course, and the `db=` half of the
    /// deep link.
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
    /// unverified for exactly these.
    public let groupTypeId: Int?

    public init(
        id: Int,
        courseId: Int,
        name: String,
        dueDate: Date?,
        isHidden: Bool,
        groupTypeId: Int?
    ) {
        self.id = id
        self.courseId = courseId
        self.name = name
        self.dueDate = dueDate
        self.isHidden = isHidden
        self.groupTypeId = groupTypeId
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
