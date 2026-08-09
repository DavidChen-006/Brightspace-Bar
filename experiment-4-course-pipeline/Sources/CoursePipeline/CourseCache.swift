import Foundation

/// Persistent, staleness-aware store for the parsed course list.
///
/// Imperative shell around a pure change-decision. The shell (this actor) reads
/// the facts — in-memory state and the injected clock — hands them to the pure
/// core (`fold`), and executes whatever single side effect the core prescribes:
/// at most one atomic file write. `apply` never consults disk; after `load()`,
/// memory is the source of truth.
///
/// The decisions this module hides from its callers:
/// - **Failure never degrades data.** A failed fetch preserves courses,
///   `lastFetch`, and the file byte-for-byte. Auth dying hourly must never
///   yield a blank menu that survives a relaunch. Only a *successful* empty
///   fetch clears the list — that is data, not an error.
/// - **An unchanged success is still a fetch.** `lastFetch` advances in memory
///   so staleness resets and a timer-driven poller stops hammering the server,
///   but the file is not rewritten — the cost is at most one extra fetch after
///   a relaunch, which is the right trade.
/// - **Equality is order-sensitive** (`[Course]` array equality): the menu
///   renders in list order, so a reorder is a user-visible `.updated`.
/// - **Staleness is inclusive**: `now - lastFetch >= staleAfter` is stale, and
///   never-fetched is stale — otherwise nothing would ever fetch.
/// - **The on-disk format** is a private JSON snapshot `{fetchedAt, courses}`,
///   written atomically. A missing or undecodable file is an empty cache,
///   never a crash.
public actor CourseCache {

    // MARK: - Functional core (pure)

    private struct State {
        var courses: [Course] = []
        var lastFetch: Date?
    }

    /// The on-disk shape. Private: no caller may depend on it.
    private struct Snapshot: Codable {
        var fetchedAt: Date
        var courses: [Course]
    }

    /// The whole change decision, as a pure function. Returns the next state,
    /// what to report, and the snapshot to persist — `nil` meaning the file
    /// must not be touched.
    private static func fold(
        _ state: State,
        result: Result<[Course], CourseSourceError>,
        now: Date
    ) -> (next: State, outcome: CacheOutcome, persist: Snapshot?) {
        switch result {
        case .success(let fetched) where fetched == state.courses:
            // A successful no-op fetch resets staleness but earns no write.
            return (State(courses: state.courses, lastFetch: now), .unchanged, nil)
        case .success(let fetched):
            let next = State(courses: fetched, lastFetch: now)
            return (next, .updated, Snapshot(fetchedAt: now, courses: fetched))
        case .failure(let error):
            // Not a fetch: state, timestamp, and file all stay exactly as-is,
            // so the retry that recovers the session is not suppressed.
            return (state, .preservedStale(error), nil)
        }
    }

    private static func isStale(lastFetch: Date?, now: Date, staleAfter: TimeInterval) -> Bool {
        guard let lastFetch else { return true }
        return now.timeIntervalSince(lastFetch) >= staleAfter
    }

    // MARK: - Imperative shell

    private let fileURL: URL
    private let clock: any Clock
    private let staleAfter: TimeInterval
    private var state = State()

    public init(fileURL: URL, clock: any Clock, staleAfter: TimeInterval) {
        self.fileURL = fileURL
        self.clock = clock
        self.staleAfter = staleAfter
    }

    /// Read the persisted list off disk. Never throws — a missing or corrupt
    /// file is an empty cache, not a crash.
    public func load() async {
        guard let data = try? Data(contentsOf: self.fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        self.state = State(courses: snapshot.courses, lastFetch: snapshot.fetchedAt)
    }

    public var courses: [Course] { self.state.courses }
    public var lastFetch: Date? { self.state.lastFetch }
    public var isStale: Bool {
        Self.isStale(lastFetch: self.state.lastFetch, now: self.clock.now, staleAfter: self.staleAfter)
    }

    /// Fold a fetch result in. Returns what happened; see `CacheOutcome`.
    public func apply(_ result: Result<[Course], CourseSourceError>) async -> CacheOutcome {
        let (next, outcome, persist) = Self.fold(self.state, result: result, now: self.clock.now)
        self.state = next
        if let persist, let data = try? JSONEncoder().encode(persist) {
            // Atomic, as RepoBar's RepoDetailCacheStore does. A failed write
            // leaves memory authoritative and disk merely stale.
            try? data.write(to: self.fileURL, options: .atomic)
        }
        return outcome
    }
}
