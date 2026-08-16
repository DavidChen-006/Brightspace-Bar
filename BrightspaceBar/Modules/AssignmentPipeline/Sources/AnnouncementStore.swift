import Foundation
import CoursePipeline

/// In-memory, per-course store for announcements.
///
/// Imperative shell around a pure change-decision, exactly as `AssignmentStore`
/// is: the shell (this actor) reads the facts — its own entries and the injected
/// clock — hands them to the pure core (`fold`), and stores what the core
/// returns. Nothing here calls `Date()`, so staleness is testable without
/// waiting.
///
/// The rule is inherited verbatim from `CourseCache` and `AssignmentStore`, so
/// no third opinion about failure can enter the backend:
///
///     SUCCESS replaces.  FAILURE preserves.  A successful EMPTY is data.
///
/// A separate store rather than a widened `AssignmentStore`, because the two
/// sections fail independently all the way down: the daemon fetches them from
/// different routes, records them under different keys, and can lose either one
/// alone. One store holding both would have to fold two results into one entry
/// and would end up with a state for every combination.
///
/// The decisions this module hides from its callers:
/// - **Failure never degrades data.** A failed fetch keeps the announcements,
///   keeps the timestamp, and records why. Only a *successful* empty fetch
///   clears a course — and for announcements that is the common case, not the
///   exotic one: plenty of courses genuinely post nothing all term.
/// - **A failed fetch does not advance `lastFetch`.** Preserved data that looked
///   fresh would make the staleness hint lie about its age.
/// - **Equality is order-sensitive** (`[Announcement]` array equality): the
///   daemon sorts newest-first and the menu shows the top few, so the order is
///   the content and a reorder is a user-visible `.updated`.
/// - **Deliberately not persisted**, for the same reason assignments are not:
///   they are cheap to re-read from the cache once courses are known.
public actor AnnouncementStore {

    // MARK: - Functional core (pure)

    private struct Entry {
        var state: AnnouncementsState
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
        result: Result<[Announcement], CourseSourceError>,
        now: Date
    ) -> (next: Entry, outcome: CacheOutcome) {
        switch result {
        case .success(let fetched) where entry?.state == .loaded(fetched):
            // A successful no-op still counts as a fetch: the timestamp advances
            // so staleness resets, but the caller is told nothing changed and can
            // skip rebuilding the menu. This is the common outcome here —
            // announcements are refetched every cycle and change rarely.
            return (Entry(state: .loaded(fetched), lastFetch: now), .unchanged)

        case .success(let fetched):
            return (Entry(state: .loaded(fetched), lastFetch: now), .updated)

        case .failure(let error):
            // Not a fetch. The list and the timestamp both stay as they were, so
            // the retry that recovers the session is never suppressed and the
            // staleness hint keeps telling the truth about the data's age.
            return (
                Entry(
                    state: .failed(lastKnown: entry?.state.announcements ?? [], error: error),
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
    public func state(for courseId: Int) -> AnnouncementsState {
        self.entries[courseId]?.state ?? .neverFetched
    }

    /// When this course last fetched *successfully*, or nil if it never has.
    public func lastFetch(for courseId: Int) -> Date? {
        self.entries[courseId]?.lastFetch
    }

    /// Fold one course's fetch result in. Returns what happened; see `CacheOutcome`.
    public func apply(
        courseId: Int,
        result: Result<[Announcement], CourseSourceError>
    ) -> CacheOutcome {
        let (next, outcome) = Self.fold(self.entries[courseId], result: result, now: self.clock.now)
        self.entries[courseId] = next
        return outcome
    }

    /// Drop every course outside `courseIds`.
    ///
    /// Internal, not public: the caller says "here are my current courses" via
    /// `AnnouncementFetcher.refresh`, and cleanup is implied by that. Exposing it
    /// would invite a caller to forget to call it, and orphans accumulate silently.
    ///
    /// Removal rather than emptying, deliberately: an emptied entry renders as
    /// "No announcements" for a class the student is not even enrolled in.
    func retain(courseIds: Set<Int>) {
        self.entries = self.entries.filter { courseIds.contains($0.key) }
    }
}
