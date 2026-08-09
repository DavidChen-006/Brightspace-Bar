import Foundation
import Testing
import CoursePipeline

/// Priority defended here: **fetch-decision correctness.**
///
/// `PollPolicy` is the functional core of polling — every "should we touch the
/// network?" decision routes through it. It takes `now` as a parameter rather than
/// holding a clock, so these are Google *small* tests: no I/O, no clock, no sleeping,
/// nothing to clean up. That makes them the cheapest place to be exhaustive, which is
/// why the boundary and skew cases live here rather than in `PollerTests`.
@Suite("PollPolicy — when to fetch")
struct PollPolicyTests {

    /// One hour — matches the JWT lifetime and the hourly refresh the SPEC recommends.
    static let interval: TimeInterval = 3600
    static let epoch = Date(timeIntervalSince1970: 1_786_230_000)

    /// `.launch`, `.menuOpened`, and `.timer` deliberately share ONE staleness rule;
    /// only `.manual` is special-cased.
    ///
    /// The SPEC only requires that `.launch` fetch when `lastFetch == nil`. Giving it
    /// the same rule as the others satisfies that for free (a nil `lastFetch` is
    /// infinitely stale) while avoiding a special case — and it means relaunching the
    /// app thirty seconds after quitting does not burn a fetch. Fresh is fresh
    /// regardless of why we are asking.
    static let staleAware: [PollTrigger] = [.launch, .menuOpened, .timer]

    // ── Invariants ──────────────────────────────────────────────────────────

    @Test("with no previous fetch, every trigger fetches", arguments: PollTrigger.allCases)
    func noPreviousFetchAlwaysFetches(_ trigger: PollTrigger) {
        // Arrange
        let policy = PollPolicy(interval: Self.interval)

        // Act
        let shouldFetch = policy.shouldFetch(
            trigger: trigger,
            lastFetch: nil,
            now: Self.epoch
        )

        // Assert — an empty cache is infinitely stale; there is nothing to serve.
        #expect(shouldFetch)
    }

    @Test("manual always fetches, even one second after the last fetch")
    func manualIgnoresTheInterval() {
        // Arrange
        let policy = PollPolicy(interval: Self.interval)

        // Act — one second is as fresh as data ever gets.
        let shouldFetch = policy.shouldFetch(
            trigger: .manual,
            lastFetch: Self.epoch,
            now: Self.epoch.addingTimeInterval(1)
        )

        // Assert — a user who clicks Refresh gets a fetch. No exceptions.
        #expect(shouldFetch)
    }

    // ── Happy path ──────────────────────────────────────────────────────────

    @Test(
        "stale-aware triggers skip the fetch while data is fresh",
        arguments: PollPolicyTests.staleAware
    )
    func freshDataIsNotRefetched(_ trigger: PollTrigger) {
        // Arrange
        let policy = PollPolicy(interval: Self.interval)

        // Act — half an interval old.
        let shouldFetch = policy.shouldFetch(
            trigger: trigger,
            lastFetch: Self.epoch,
            now: Self.epoch.addingTimeInterval(Self.interval / 2)
        )

        // Assert
        #expect(!shouldFetch)
    }

    @Test(
        "stale-aware triggers fetch once data is older than the interval",
        arguments: PollPolicyTests.staleAware
    )
    func staleDataIsRefetched(_ trigger: PollTrigger) {
        // Arrange
        let policy = PollPolicy(interval: Self.interval)

        // Act
        let shouldFetch = policy.shouldFetch(
            trigger: trigger,
            lastFetch: Self.epoch,
            now: Self.epoch.addingTimeInterval(Self.interval * 2)
        )

        // Assert
        #expect(shouldFetch)
    }

    // ── Edge cases ──────────────────────────────────────────────────────────

    @Test(
        "data exactly one interval old counts as stale",
        arguments: PollPolicyTests.staleAware
    )
    func theIntervalBoundaryIsInclusive(_ trigger: PollTrigger) {
        // Arrange
        let policy = PollPolicy(interval: Self.interval)

        // Act — precisely at the boundary.
        let shouldFetch = policy.shouldFetch(
            trigger: trigger,
            lastFetch: Self.epoch,
            now: Self.epoch.addingTimeInterval(Self.interval)
        )

        // Assert — INCLUSIVE (`age >= interval`), decided deliberately:
        //  * the interval means "data older than this is stale", and at the boundary
        //    the data has reached its expiry;
        //  * a repeating timer firing exactly on its period is the COMMON case, not an
        //    edge — an exclusive comparison would make a punctual timer decline, which
        //    would be absurd;
        //  * it makes `interval: 0` degrade to "always fetch", a sane reading.
        #expect(shouldFetch)
    }

    @Test(
        "data one second under the interval still counts as fresh",
        arguments: PollPolicyTests.staleAware
    )
    func theIntervalBoundaryIsNotOffByOne(_ trigger: PollTrigger) {
        // Arrange
        let policy = PollPolicy(interval: Self.interval)

        // Act
        let shouldFetch = policy.shouldFetch(
            trigger: trigger,
            lastFetch: Self.epoch,
            now: Self.epoch.addingTimeInterval(Self.interval - 1)
        )

        // Assert — the complement of the inclusive boundary above. Together these two
        // pin the comparison exactly; either alone would permit an off-by-one.
        #expect(!shouldFetch)
    }

    @Test(
        "a lastFetch in the future does not wedge the poller",
        arguments: PollPolicyTests.staleAware
    )
    func futureTimestampsAreTreatedAsStale(_ trigger: PollTrigger) {
        // Arrange
        let policy = PollPolicy(interval: Self.interval)

        // Act — clock skew, an NTP correction, or waking from sleep can leave a
        // persisted `lastFetch` ahead of `now`, making the age negative.
        let shouldFetch = policy.shouldFetch(
            trigger: trigger,
            lastFetch: Self.epoch.addingTimeInterval(10_000),
            now: Self.epoch
        )

        // Assert — a naive `age >= interval` fails here forever: a negative age is
        // never >= 3600, so the poller would never fetch again and no amount of
        // waiting would recover it. A future timestamp is untrustworthy data; treating
        // it as stale is self-healing and costs one request.
        #expect(shouldFetch)
    }
}
