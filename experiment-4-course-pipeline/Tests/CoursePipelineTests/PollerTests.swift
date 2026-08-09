import Foundation
import Testing
import CoursePipeline

/// Priorities defended here, in order:
///
/// 1. **Fetch-decision correctness**, observed as *call counts on the source*. "Polling
///    works" is not a claim about elapsed time — it is the claim that N triggers inside
///    one interval produce exactly one network call.
/// 2. **Data integrity under failure.** A failing source must never degrade a good
///    cache. The regression being guarded is a blank menu that persists to disk.
///
/// Scope is Google *medium*: these drive the REAL `CourseCache` (touching the
/// filesystem in a per-test temp directory) and the REAL `EnrollmentParser`. That is
/// deliberate — the claim "the whole vertical works" lives at the seam between these
/// modules, so no smaller scope can make it. Time is still injected; nothing sleeps.
@Suite("Poller — the imperative shell")
struct PollerTests {

    static let interval: TimeInterval = 3600
    static let epoch = Date(timeIntervalSince1970: 1_786_230_000)

    /// A course whose fields are all distinguishable, so an assertion failure names
    /// which course went missing.
    static func course(_ id: Int) -> Course {
        Course(
            id: id,
            name: "Course \(id)",
            code: "CS\(id)",
            role: "Learner",
            isActive: true,
            homeUrl: "https://purdue.brightspace.com/d2l/home/\(id)"
        )
    }

    // ── The headline: the whole vertical minus the GUI ───────────────────────

    @Test("the full chain turns real payload bytes into 27 cached courses")
    func theFullChainFromBytesToCache() async throws {
        // Arrange — every component is real except the network itself. The fake is
        // scripted with the genuine 14,938-byte tenant payload, which it decodes with
        // the real parser, exactly as the real adapter will.
        let tmp = try TempDir()
        let clock = TestClock(Self.epoch)
        let source = FakeCourseSource([.bytes(try Fixture.enrollments)])
        let cache = CourseCache(fileURL: tmp.file(), clock: clock, staleAfter: Self.interval)
        await cache.load()
        let poller = Poller(
            source: source,
            cache: cache,
            policy: PollPolicy(interval: Self.interval),
            clock: clock
        )

        // Act
        let outcome = await poller.tick(.launch)

        // Assert — the count comes from the fixture as an independent source of truth
        // (27 items, verified out-of-band), not from anything the code computed.
        #expect(outcome == .updated)
        let courses = await cache.courses
        #expect(courses.count == 27)

        // Spot-check real data actually flowed, so "27" cannot be an artifact of
        // twenty-seven empty placeholders.
        let civics = try #require(courses.first { $0.id == 412_690 })
        #expect(civics.code == "wl.nc.civics.test")
        #expect(civics.homeUrl == "https://purdue.brightspace.com/d2l/home/412690")

        // `homeUrl` is preserved verbatim, nulls included — measured ground truth is
        // non-null in exactly 2 of 27 items (412690, 440703), null for every real class.
        // An earlier SPEC draft wrongly said it was always populated; corrected by the
        // orchestrator. Pinning the true count is stronger than pinning presence: it
        // catches both a parser that synthesizes URLs and one that drops real ones.
        #expect(courses.filter { $0.homeUrl != nil }.count == 2)
        #expect(courses.first { $0.id == 1_498_777 }?.homeUrl == nil)
    }

    // ── Priority 1: fetch-decision correctness, as call counts ───────────────

    @Test("a second tick inside the interval neither fetches nor reports an outcome")
    func aSecondTickInsideTheIntervalIsDeclined() async throws {
        // Arrange
        let tmp = try TempDir()
        let clock = TestClock(Self.epoch)
        let source = FakeCourseSource([.courses([Self.course(1)])])
        let cache = CourseCache(fileURL: tmp.file(), clock: clock, staleAfter: Self.interval)
        await cache.load()
        let poller = Poller(
            source: source,
            cache: cache,
            policy: PollPolicy(interval: Self.interval),
            clock: clock
        )
        _ = await poller.tick(.launch)

        // Act — one minute later, well inside the hour.
        clock.advance(by: 60)
        let outcome = await poller.tick(.menuOpened)

        // Assert — this is what polling MEANS: the network was touched once.
        #expect(await source.callCount == 1)
        #expect(outcome == nil, "a declined poll reports no outcome")
    }

    @Test("a tick after the interval fetches again")
    func aTickAfterTheIntervalFetchesAgain() async throws {
        // Arrange
        let tmp = try TempDir()
        let clock = TestClock(Self.epoch)
        let source = FakeCourseSource([.courses([Self.course(1)])])
        let cache = CourseCache(fileURL: tmp.file(), clock: clock, staleAfter: Self.interval)
        await cache.load()
        let poller = Poller(
            source: source,
            cache: cache,
            policy: PollPolicy(interval: Self.interval),
            clock: clock
        )
        _ = await poller.tick(.launch)

        // Act
        clock.advance(by: Self.interval + 1)
        _ = await poller.tick(.timer)

        // Assert
        #expect(await source.callCount == 2)
    }

    @Test("a manual tick bypasses the interval")
    func manualBypassesTheInterval() async throws {
        // Arrange
        let tmp = try TempDir()
        let clock = TestClock(Self.epoch)
        let source = FakeCourseSource([.courses([Self.course(1)])])
        let cache = CourseCache(fileURL: tmp.file(), clock: clock, staleAfter: Self.interval)
        await cache.load()
        let poller = Poller(
            source: source,
            cache: cache,
            policy: PollPolicy(interval: Self.interval),
            clock: clock
        )
        _ = await poller.tick(.launch)

        // Act — one second later, which `.menuOpened` would decline.
        clock.advance(by: 1)
        let outcome = await poller.tick(.manual)

        // Assert
        #expect(await source.callCount == 2)
        #expect(outcome != nil, "an explicit refresh always produces an outcome")
    }

    @Test("concurrent ticks never produce overlapping fetches")
    func concurrentTicksNeverOverlap() async throws {
        // Arrange — the fake suspends several times mid-fetch, so a reentrant caller
        // genuinely CAN slip in. Swift actor isolation alone does not prevent this:
        // `await` inside an actor method is a suspension point that admits other
        // calls, which is the reentrancy trap a naive implementation falls into.
        let tmp = try TempDir()
        let clock = TestClock(Self.epoch)
        let source = FakeCourseSource([.bytes(try Fixture.enrollments)], yieldsPerFetch: 8)
        let cache = CourseCache(fileURL: tmp.file(), clock: clock, staleAfter: Self.interval)
        await cache.load()
        let poller = Poller(
            source: source,
            cache: cache,
            policy: PollPolicy(interval: Self.interval),
            clock: clock
        )

        // Act — eight triggers land at the same instant (launch racing menuOpened at
        // startup is a real scenario).
        await withTaskGroup(of: CacheOutcome?.self) { group in
            for _ in 0 ..< 8 {
                group.addTask { await poller.tick(.launch) }
            }
            for await _ in group {}
        }

        // Assert — DECISION: concurrent triggers must not produce overlapping fetches.
        // A second tick arriving while a fetch is in flight either awaits that same
        // fetch or is declined; either way the network is touched once. Asserting the
        // high-water mark rather than an interleaving makes this deterministic — no
        // sleeps, no timing assumptions, no flakiness.
        #expect(await source.maxConcurrentFetches == 1)
        #expect(await source.callCount == 1)
        #expect(await cache.courses.count == 27)
    }

    // ── Priority 2: data integrity under failure ─────────────────────────────

    @Test("a failing source leaves a previously-good cache intact")
    func aFailingSourceDoesNotDamageTheCache() async throws {
        // Arrange — a good cache first.
        let tmp = try TempDir()
        let clock = TestClock(Self.epoch)
        let source = FakeCourseSource([
            .courses([Self.course(1), Self.course(2)]),
            .failure(.transport("offline")),
        ])
        let cache = CourseCache(fileURL: tmp.file(), clock: clock, staleAfter: Self.interval)
        await cache.load()
        let poller = Poller(
            source: source,
            cache: cache,
            policy: PollPolicy(interval: Self.interval),
            clock: clock
        )
        _ = await poller.tick(.launch)

        // Act
        clock.advance(by: Self.interval + 1)
        let outcome = await poller.tick(.timer)

        // Assert — stale but correct beats blank.
        #expect(outcome == .preservedStale(.transport("offline")))
        #expect(await cache.courses.count == 2)
    }

    @Test("an expired session does not blank the cache")
    func sessionExpiredDoesNotBlankTheCache() async throws {
        // Arrange — the specific killer case. Brightspace answers a dead session on the
        // mint path with HTTP 200 and an HTML stub, so a source that keys on the status
        // alone would report success with zero courses. If that ever reached the cache
        // it would blank the menu AND persist the blankness to disk.
        let tmp = try TempDir()
        let clock = TestClock(Self.epoch)
        let source = FakeCourseSource([
            .courses([Self.course(1), Self.course(2), Self.course(3)]),
            .failure(.sessionExpired),
        ])
        let cache = CourseCache(fileURL: tmp.file(), clock: clock, staleAfter: Self.interval)
        await cache.load()
        let poller = Poller(
            source: source,
            cache: cache,
            policy: PollPolicy(interval: Self.interval),
            clock: clock
        )
        _ = await poller.tick(.launch)

        // Act
        clock.advance(by: Self.interval + 1)
        let outcome = await poller.tick(.timer)

        // Assert
        #expect(outcome == .preservedStale(.sessionExpired))
        #expect(await cache.courses.count == 3)
    }

    @Test("success, then failure, then success ends up updated")
    func recoveryAfterAFailure() async throws {
        // Arrange
        let tmp = try TempDir()
        let clock = TestClock(Self.epoch)
        let source = FakeCourseSource([
            .courses([Self.course(1), Self.course(2)]),
            .failure(.httpStatus(500)),
            .courses([Self.course(1), Self.course(2), Self.course(3)]),
        ])
        let cache = CourseCache(fileURL: tmp.file(), clock: clock, staleAfter: Self.interval)
        await cache.load()
        let poller = Poller(
            source: source,
            cache: cache,
            policy: PollPolicy(interval: Self.interval),
            clock: clock
        )

        // Act & Assert — one behaviour, observed across three states of the world.
        _ = await poller.tick(.launch)
        #expect(await cache.courses.count == 2)

        clock.advance(by: Self.interval + 1)
        _ = await poller.tick(.timer)
        #expect(await cache.courses.count == 2, "the outage must not shrink the cache")

        clock.advance(by: Self.interval + 1)
        _ = await poller.tick(.timer)
        #expect(await cache.courses.count == 3, "recovery must take effect")
    }

    @Test("a dropped course disappears from the cache")
    func aDroppedCourseDisappears() async throws {
        // Arrange — 27 then 26. This is the transition the real backend physically
        // cannot produce on demand, and the entire reason a fake exists.
        let tmp = try TempDir()
        let clock = TestClock(Self.epoch)
        let full = (1 ... 27).map(Self.course)
        let dropped = full.filter { $0.id != 14 }
        let source = FakeCourseSource([.courses(full), .courses(dropped)])
        let cache = CourseCache(fileURL: tmp.file(), clock: clock, staleAfter: Self.interval)
        await cache.load()
        let poller = Poller(
            source: source,
            cache: cache,
            policy: PollPolicy(interval: Self.interval),
            clock: clock
        )
        _ = await poller.tick(.launch)
        #expect(await cache.courses.count == 27)

        // Act
        clock.advance(by: Self.interval + 1)
        let outcome = await poller.tick(.timer)

        // Assert
        #expect(outcome == .updated)
        let courses = await cache.courses
        #expect(courses.count == 26)
        #expect(!courses.contains { $0.id == 14 }, "the dropped course must be gone")
    }

    @Test("a failed fetch does not consume the interval")
    func aFailedFetchDoesNotConsumeTheInterval() async throws {
        // Arrange
        let tmp = try TempDir()
        let clock = TestClock(Self.epoch)
        let source = FakeCourseSource([
            .courses([Self.course(1)]),
            .failure(.transport("offline")),
        ])
        let cache = CourseCache(fileURL: tmp.file(), clock: clock, staleAfter: Self.interval)
        await cache.load()
        let poller = Poller(
            source: source,
            cache: cache,
            policy: PollPolicy(interval: Self.interval),
            clock: clock
        )
        _ = await poller.tick(.launch)
        clock.advance(by: Self.interval + 1)
        _ = await poller.tick(.timer)   // fails; `lastFetch` must NOT advance

        // Act — no clock movement at all before trying again.
        _ = await poller.tick(.timer)

        // Assert — because a failure never stamps `lastFetch`, the data is still stale
        // and the next trigger retries immediately. That is what makes an offline app
        // recover the moment the user opens the menu again, rather than waiting out a
        // full interval it never earned.
        #expect(await source.callCount == 3)
    }
}
