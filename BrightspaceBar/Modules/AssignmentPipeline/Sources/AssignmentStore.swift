import Foundation
import CoursePipeline

/// In-memory, per-course store for parsed assignments.
///
/// Imperative shell around a pure change-decision, exactly as `CourseCache` is:
/// the shell (this actor) reads the facts — its own entries and the injected clock
/// — hands them to the pure core (`fold`), and stores what the core returns.
/// Nothing here calls `Date()`, so staleness is testable without waiting.
///
/// The rule is inherited verbatim from `CourseCache`, so the two backend modules
/// cannot disagree about what a failed fetch means:
///
///     SUCCESS replaces.  FAILURE preserves.  A successful EMPTY is data.
///
/// What is genuinely new is **granularity**. `CourseCache` folds one result for the
/// whole list; this folds one result *per course*, because with one request per
/// course partial failure is the normal case rather than the exotic one — this
/// tenant's session dies within hours, and experiment 6 proved an inaccessible
/// course answers 403. Course A updating while course B fails is a state the
/// list-wide cache literally cannot express.
///
/// The decisions this module hides from its callers:
/// - **Failure never degrades data.** A failed fetch keeps the assignments, keeps
///   the timestamp, and records why. Only a *successful* empty fetch clears a
///   course — that is the server saying there are none.
/// - **A failed fetch does not advance `lastFetch`.** If it did, preserved data
///   would look fresh and the staleness hint would lie about how old it is.
/// - **Equality is order-sensitive** (`[Assignment]` array equality): the submenu
///   renders in list order, so a reorder is a user-visible `.updated`.
/// - **Deliberately not persisted.** Unlike the course list, assignments are not
///   worth surviving a relaunch: they are cheap to refetch once courses are known,
///   and a stale-on-disk assignment list would need its own invalidation rules.
///   Courses are the warm-start data; assignments follow them.
public actor AssignmentStore {

    // MARK: - Functional core (pure)

    private struct Entry {
        var state: AssignmentsState
        var lastFetch: Date?
    }

    /// The whole change decision for one course, as a pure function.
    ///
    /// `nil` in means a course with no entry yet — which is why "unchanged" is
    /// tested as `entry?.state == .loaded(fetched)` rather than by comparing
    /// lists: a first fetch that happens to return `[]` is a genuine transition
    /// out of `neverFetched`, not a no-op.
    private static func fold(
        _ entry: Entry?,
        result: Result<[Assignment], CourseSourceError>,
        now: Date
    ) -> (next: Entry, outcome: CacheOutcome) {
        switch result {
        case .success(let fetched) where entry?.state == .loaded(fetched):
            // A successful no-op still counts as a fetch: the timestamp advances
            // so staleness resets, but the caller is told nothing changed and can
            // skip rebuilding the menu.
            return (Entry(state: .loaded(fetched), lastFetch: now), .unchanged)

        case .success(let fetched):
            return (Entry(state: .loaded(fetched), lastFetch: now), .updated)

        case .failure(let error):
            // Not a fetch. The list and the timestamp both stay as they were, so
            // the retry that recovers the session is never suppressed and the
            // staleness hint keeps telling the truth about the data's age.
            return (
                Entry(
                    state: .failed(lastKnown: entry?.state.assignments ?? [], error: error),
                    lastFetch: entry?.lastFetch
                ),
                .preservedStale(error)
            )
        }
    }

    // MARK: - Imperative shell

    private let clock: any Clock
    /// Absence of a key *is* `neverFetched`. Keeping that implicit means orphan
    /// cleanup is a removal rather than a separate "forgotten" state to maintain.
    private var entries: [Int: Entry] = [:]

    public init(clock: any Clock) {
        self.clock = clock
    }

    /// What is known about this course. `neverFetched` for one never seen.
    public func state(for courseId: Int) -> AssignmentsState {
        self.entries[courseId]?.state ?? .neverFetched
    }

    /// When this course last fetched *successfully*, or nil if it never has.
    public func lastFetch(for courseId: Int) -> Date? {
        self.entries[courseId]?.lastFetch
    }

    /// Fold one course's fetch result in. Returns what happened; see `CacheOutcome`.
    public func apply(
        courseId: Int,
        result: Result<[Assignment], CourseSourceError>
    ) -> CacheOutcome {
        let (next, outcome) = Self.fold(self.entries[courseId], result: result, now: self.clock.now)
        self.entries[courseId] = next
        return outcome
    }

    /// Drop every course outside `courseIds`.
    ///
    /// Internal, not public: the caller says "here are my current courses" via
    /// `AssignmentFetcher.refresh`, and cleanup is implied by that. Exposing it
    /// would invite a caller to forget to call it, and orphans accumulate silently.
    ///
    /// Removal rather than emptying, deliberately: an emptied entry renders as
    /// "No assignments" for a class the student is not even enrolled in, and a
    /// `.failed` entry would keep apologising about a course they dropped.
    func retain(courseIds: Set<Int>) {
        self.entries = self.entries.filter { courseIds.contains($0.key) }
    }
}
