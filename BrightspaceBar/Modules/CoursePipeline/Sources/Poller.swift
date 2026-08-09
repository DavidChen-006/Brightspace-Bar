import Foundation

/// The imperative shell of polling. It owns no decision logic: the shell reads the
/// facts (`cache.lastFetch`, `clock.now`), the pure core (`PollPolicy`) decides,
/// and the shell executes — call the source, fold the result into the cache.
///
/// The decisions this module hides from its callers:
/// - **One source of truth for freshness.** The poller holds no `lastFetch` of its
///   own; it reads the cache's. A failed fetch never advances the cache's
///   timestamp (the cache guarantees that), so an offline app retries the moment
///   the next trigger arrives rather than waiting out an interval it never earned.
/// - **Errors are values.** `tick` does not throw: a failing source surfaces as
///   `.preservedStale(error)`, exactly what the cache reports when it keeps the
///   old list.
/// - **In-flight coalescing.** Actor isolation alone does not serialise fetches:
///   every `await` in an actor method is a suspension point that admits reentrant
///   calls, so N concurrent ticks could all clear the policy check and all call
///   the source. Instead the single in-flight fetch is stored as a `Task`, and the
///   check-and-claim happens with no suspension in between; a tick arriving while
///   a fetch is in flight awaits that same task and returns its outcome. The
///   network is touched at most once at a time.
public actor Poller {
    private let source: any CourseSource
    private let cache: CourseCache
    private let policy: PollPolicy
    private let clock: any Clock

    /// The single in-flight fetch. Non-nil from the moment a tick claims the right
    /// to fetch until that tick observes completion; later ticks coalesce onto it.
    private var inFlight: Task<CacheOutcome, Never>?
    /// Bumped each time an in-flight fetch is retired. Lets a tick detect that a
    /// whole fetch started *and* finished while it was reading `cache.lastFetch`,
    /// in which case its snapshot is stale and must be taken again.
    private var completedFetches = 0

    public init(source: any CourseSource, cache: CourseCache, policy: PollPolicy, clock: any Clock) {
        self.source = source
        self.cache = cache
        self.policy = policy
        self.clock = clock
    }

    /// nil = policy declined (data still fresh for this trigger);
    /// otherwise the `CacheOutcome` of the fetch this tick started or joined.
    public func tick(_ trigger: PollTrigger) async -> CacheOutcome? {
        while true {
            if let inFlight { return await inFlight.value }

            // Shell reads the facts. This `await` is a reentrancy point: another
            // tick may start — or even finish — a fetch while we read.
            let observed = self.completedFetches
            let lastFetch = await self.cache.lastFetch

            // Started meanwhile → coalesce onto it.
            if let inFlight { return await inFlight.value }
            // Finished meanwhile → our snapshot predates it; take it again.
            guard self.completedFetches == observed else { continue }

            // Core decides.
            guard self.policy.shouldFetch(trigger: trigger, lastFetch: lastFetch, now: self.clock.now) else {
                return nil
            }

            // Shell executes. Claiming the slot is synchronous from the re-check
            // above to the assignment below — no suspension point a reentrant
            // caller could slip through.
            let fetch = Task { [source, cache] () -> CacheOutcome in
                let result: Result<[Course], CourseSourceError>
                do {
                    result = .success(try await source.fetchCourses())
                } catch let error as CourseSourceError {
                    result = .failure(error)
                } catch {
                    result = .failure(.transport(String(describing: error)))
                }
                return await cache.apply(result)
            }
            self.inFlight = fetch
            let outcome = await fetch.value
            self.completedFetches += 1
            self.inFlight = nil
            return outcome
        }
    }
}
