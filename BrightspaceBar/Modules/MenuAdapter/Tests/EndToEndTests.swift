import Foundation
import Testing

import BrightspaceSession
import CourseMenu
import CoursePipeline
import MenuAdapter

// ═════════════════════════════════════════════════════════════════════════════
// MenuAdapter — the wiring shell, and the whole vertical minus the GUI.
//
// PRIORITIES (the 1–2 carrying 80% of the value):
//
//   1. THE MENU NEVER WAITS ON THE NETWORK. `currentMenu()` must serve what is
//      already known and touch no socket. Expressed as a CALL COUNT on the source,
//      never as elapsed time — a timing assertion would be flaky and would not
//      actually test the property.
//
//   2. FAILURE NEVER BLANKS THE MENU. Auth here dies roughly hourly, so a failed
//      refresh is the normal case, not the exotic one. Experiment 4's cache already
//      guarantees the DATA survives (`.preservedStale`); what is untested until now
//      is whether the ADAPTER surfaces it, or hands the GUI an empty model anyway.
//
// CULLED: retry/backoff (not in this design), concurrency stress (experiment 4's
// Poller owns coalescing and tests it), disk format (experiment 4's private
// business), timing.
//
// SCOPE: medium — a real CourseCache writing a real file in a scratch directory,
// driving a real Poller and the real EnrollmentParser. Only the network is faked.
// Plus one large, gated on BS_LIVE.
// ═════════════════════════════════════════════════════════════════════════════

private let epoch = Date(timeIntervalSince1970: 1_786_230_000)

/// `true` only for `BS_LIVE=1 swift test`. Read once at load, as experiment 4 does,
/// so the gate cannot change mid-suite.
private let bsLiveEnabled = ProcessInfo.processInfo.environment["BS_LIVE"] != nil

/// Assembles the real experiment-4 stack around a scripted source.
///
/// `staleAfter` and `interval` are set long so nothing goes stale mid-test by
/// accident: every fetch in this suite happens because a test asked for one.
private func makeAdapter(
    source: CountingSource,
    file: URL,
    clock: ManualClock,
    interval: TimeInterval = 3600
) -> (adapter: MenuAdapter, cache: CourseCache) {
    let cache = CourseCache(fileURL: file, clock: clock, staleAfter: interval)
    let poller = Poller(
        source: source,
        cache: cache,
        policy: PollPolicy(interval: interval),
        clock: clock
    )
    let adapter = MenuAdapter(
        poller: poller, cache: cache, baseURL: RealData.baseURL, clock: clock
    )
    return (adapter, cache)
}

@Suite("MenuAdapter — the frontend/backend join")
struct EndToEndTests {

    // ── The headline: the whole vertical minus the GUI ────────────────────────

    @Test("real bytes flow through parser, cache and translation into a menu")
    func theFullChainYieldsTwentySevenClickableRows() async throws {
        // Arrange — the genuine 14,938-byte payload, the real parser, a real cache
        // on a real file. Nothing about this data is hand-built.
        let scratch = try ScratchDir()
        let clock = ManualClock(epoch)
        let source = CountingSource([.bytes(try CrossPackageFixture.enrollmentBytes)])
        let (adapter, _) = makeAdapter(source: source, file: scratch.file(), clock: clock)

        // Act
        let model = await adapter.refresh()

        // Assert — count, then that the rows are genuinely populated: "27" must not
        // be achievable with twenty-seven blank placeholders.
        try #require(model.courses.count == RealData.totalCourses)
        for row in model.courses {
            #expect(row.id > 0)
            #expect(!row.title.isEmpty)
            #expect(row.url.absoluteString == "https://purdue.brightspace.com/d2l/home/\(row.id)")
        }

        // And a named spot check, so a systematic id shift cannot pass.
        let compilers = try #require(model.courses.first { $0.id == RealData.compilersID })
        #expect(compilers.title == RealData.compilersName)
        #expect(compilers.subtitle == RealData.compilersShortCode)
    }

    // ── Priority 1: the menu never waits on the network ──────────────────────

    @Test("currentMenu does not fetch")
    func currentMenuTouchesNoSocket() async throws {
        // Arrange
        let scratch = try ScratchDir()
        let clock = ManualClock(epoch)
        let source = CountingSource([.bytes(try CrossPackageFixture.enrollmentBytes)])
        let (adapter, _) = makeAdapter(source: source, file: scratch.file(), clock: clock)

        // Act — several opens, as a user clicking the icon repeatedly.
        _ = await adapter.currentMenu()
        _ = await adapter.currentMenu()
        _ = await adapter.currentMenu()

        // Assert
        #expect(await source.callCount() == 0)
    }

    /// The control for the test above. Without it, an adapter whose `refresh()` is
    /// also a no-op would satisfy "currentMenu does not fetch" perfectly — the
    /// classic vacuous pass. This is what makes the pair meaningful.
    @Test("refresh does fetch — the control for currentMenu not fetching")
    func refreshTouchesTheSocketExactlyOnce() async throws {
        // Arrange
        let scratch = try ScratchDir()
        let clock = ManualClock(epoch)
        let source = CountingSource([.bytes(try CrossPackageFixture.enrollmentBytes)])
        let (adapter, _) = makeAdapter(source: source, file: scratch.file(), clock: clock)

        // Act
        _ = await adapter.refresh()

        // Assert
        #expect(await source.callCount() == 1)
    }

    @Test("an explicit refresh fetches again even inside the poll interval")
    func refreshIsAlwaysHonoured() async throws {
        // Arrange — interval far longer than the gap between the two calls, so a
        // staleness-gated refresh would decline the second one.
        let scratch = try ScratchDir()
        let clock = ManualClock(epoch)
        let source = CountingSource([.bytes(try CrossPackageFixture.enrollmentBytes)])
        let (adapter, _) = makeAdapter(
            source: source, file: scratch.file(), clock: clock, interval: 86_400
        )

        // Act — a user clicking Refresh twice must be obeyed twice; being told
        // "still fresh" when you explicitly asked is a bug, not an optimisation.
        _ = await adapter.refresh()
        _ = await adapter.refresh()

        // Assert
        #expect(await source.callCount() == 2)
    }

    @Test("currentMenu after a refresh serves the fetched data without refetching")
    func currentMenuServesWhatRefreshFetched() async throws {
        // Arrange
        let scratch = try ScratchDir()
        let clock = ManualClock(epoch)
        let source = CountingSource([.bytes(try CrossPackageFixture.enrollmentBytes)])
        let (adapter, _) = makeAdapter(source: source, file: scratch.file(), clock: clock)
        _ = await adapter.refresh()

        // Act
        let model = await adapter.currentMenu()

        // Assert
        #expect(model.courses.count == RealData.totalCourses)
        #expect(await source.callCount() == 1, "currentMenu triggered a second fetch")
    }

    // ── Priority 2: failure never blanks the menu ───────────────────────────

    @Test("a failing refresh keeps the courses that were already there")
    func failurePreservesTheVisibleCourses() async throws {
        // Arrange — one good fetch, then the session dies. This is the ordinary
        // hourly case for this app, not an exotic one.
        let scratch = try ScratchDir()
        let clock = ManualClock(epoch)
        let source = CountingSource(
            [.bytes(try CrossPackageFixture.enrollmentBytes), .failure(.sessionExpired)],
            repeatLast: true
        )
        let (adapter, _) = makeAdapter(source: source, file: scratch.file(), clock: clock)

        let before = await adapter.refresh()
        try #require(before.courses.count == RealData.totalCourses)

        // Act
        let after = await adapter.refresh()

        // Assert — the whole point: a dead session must not empty the dropdown.
        #expect(after.courses.count == RealData.totalCourses)
        #expect(after.courses.map(\.id) == before.courses.map(\.id))
    }

    @Test(
        "every failure kind preserves the courses, not just session expiry",
        arguments: [
            CourseSourceError.sessionExpired,
            CourseSourceError.transport("offline"),
            CourseSourceError.httpStatus(500),
            CourseSourceError.malformedBody("garbage"),
        ]
    )
    func allFailureKindsPreserveCourses(error: CourseSourceError) async throws {
        // Arrange
        let scratch = try ScratchDir()
        let clock = ManualClock(epoch)
        let source = CountingSource(
            [.bytes(try CrossPackageFixture.enrollmentBytes), .failure(error)], repeatLast: true
        )
        let (adapter, _) = makeAdapter(source: source, file: scratch.file(), clock: clock)
        _ = await adapter.refresh()

        // Act
        let after = await adapter.refresh()

        // Assert
        #expect(after.courses.count == RealData.totalCourses)
    }

    @Test("currentMenu still serves the courses after a failed refresh")
    func openingTheMenuOfflineStillShowsCourses() async throws {
        // Arrange — the offline sentence of the success story: David clicks the
        // icon with no internet and his classes are still listed.
        let scratch = try ScratchDir()
        let clock = ManualClock(epoch)
        let source = CountingSource(
            [.bytes(try CrossPackageFixture.enrollmentBytes), .failure(.transport("offline"))],
            repeatLast: true
        )
        let (adapter, _) = makeAdapter(source: source, file: scratch.file(), clock: clock)
        _ = await adapter.refresh()
        _ = await adapter.refresh()

        // Act
        let model = await adapter.currentMenu()

        // Assert
        #expect(model.courses.count == RealData.totalCourses)
        #expect(!model.rows.isEmpty)
    }

    @Test("a failure on a cold cache yields a menu with rows, never a blank one")
    func coldFailureStillShowsSomething() async throws {
        // Arrange — worst case: first ever launch AND the session is already dead.
        let scratch = try ScratchDir()
        let clock = ManualClock(epoch)
        let source = CountingSource([.failure(.sessionExpired)])
        let (adapter, _) = makeAdapter(source: source, file: scratch.file(), clock: clock)

        // Act
        let model = await adapter.refresh()

        // Assert — no courses to show is fine; showing nothing at all is not.
        #expect(model.courses.isEmpty)
        #expect(!model.rows.isEmpty, "a blank dropdown reads as a crashed app")
    }

    // ── Cold and warm start ─────────────────────────────────────────────────

    @Test("a cold adapter with no cache file yields the placeholder")
    func coldStartIsThePlaceholder() async throws {
        // Arrange — nothing on disk, nothing fetched.
        let scratch = try ScratchDir()
        let clock = ManualClock(epoch)
        let source = CountingSource([.courses([])])
        let (adapter, _) = makeAdapter(source: source, file: scratch.file(), clock: clock)

        // Act
        let model = await adapter.currentMenu()

        // Assert
        #expect(model == MenuModel.placeholder)
        #expect(await source.callCount() == 0)
    }

    @Test("a relaunch serves the previous courses off disk before any fetch")
    func warmStartLoadsFromDisk() async throws {
        // Arrange — first run fetches and persists; then a brand-new adapter and a
        // brand-new source stand in for a relaunched process.
        let scratch = try ScratchDir()
        let file = scratch.file()
        let clock = ManualClock(epoch)

        let firstRun = CountingSource([.bytes(try CrossPackageFixture.enrollmentBytes)])
        let (first, _) = makeAdapter(source: firstRun, file: file, clock: clock)
        _ = await first.refresh()

        let secondRun = CountingSource([.failure(.transport("should not be called"))])
        let (second, _) = makeAdapter(source: secondRun, file: file, clock: clock)

        // Act — the menu-open of a freshly launched app.
        let model = await second.currentMenu()

        // Assert — the courses came off disk, and no fetch was needed to get them.
        #expect(model.courses.count == RealData.totalCourses)
        #expect(await secondRun.callCount() == 0)
    }

    @Test("the status row reflects the age of the cached fetch after a relaunch")
    func warmStartReportsRealStaleness() async throws {
        // Arrange
        let scratch = try ScratchDir()
        let file = scratch.file()
        let clock = ManualClock(epoch)
        let firstRun = CountingSource([.bytes(try CrossPackageFixture.enrollmentBytes)])
        let (first, _) = makeAdapter(source: firstRun, file: file, clock: clock)
        _ = await first.refresh()

        // Two hours pass while the laptop is shut.
        clock.advance(by: 7200)

        let secondRun = CountingSource([.failure(.transport("offline"))])
        let (second, _) = makeAdapter(source: secondRun, file: file, clock: clock)

        // Act
        let model = await second.currentMenu()

        // Assert — the user is told the data is old rather than being misled.
        let status = try #require(
            model.rows.compactMap { if case .status(let s) = $0 { s } else { nil } }.first
        )
        #expect(status == "Updated 2 hours ago")
    }

    // ── SystemClock: the one place Date() is allowed ─────────────────────────

    @Test("SystemClock reports approximately the real time")
    func systemClockIsWiredToRealTime() {
        // Arrange / Act — nothing else in either package may call `Date()`, so if
        // this returns a constant or a distant date there is nowhere else to notice.
        let observed = SystemClock().now

        // Assert — generous window; the claim is "wired up", not "precise".
        #expect(abs(observed.timeIntervalSinceNow) < SystemClockProbe.tolerance)
    }

    // ── The live run: proof the fake did not drift ───────────────────────────

    /// Skipped by default so `swift test` stays hermetic — no network, no cookie,
    /// no `session.json`. Mirrors experiment 4's gating exactly.
    @Test("the real tenant produces a clickable menu", .enabled(if: bsLiveEnabled))
    func liveTenantYieldsAClickableMenu() async throws {
        // Arrange — the real adapter reading the captured session. Never copied
        // here, never logged.
        let scratch = try ScratchDir()
        let clock = ManualClock(Date())
        let cache = CourseCache(fileURL: scratch.file(), clock: clock, staleAfter: 3600)
        let poller = Poller(
            source: BrightspaceCourseSource(provider: FileSessionProvider.standard),
            cache: cache,
            policy: PollPolicy(interval: 3600),
            clock: clock
        )
        let adapter = MenuAdapter(
            poller: poller, cache: cache, baseURL: RealData.baseURL, clock: clock
        )

        // Act
        let model = await adapter.refresh()

        // Assert — the anti-drift claim: if the live tenant yields an empty menu
        // while the fixture yields 27, that surfaces here and not as a blank
        // dropdown in front of the user.
        try #require(!model.courses.isEmpty, "the live tenant produced no courses")
        for row in model.courses {
            #expect(row.id > 0)
            #expect(!row.title.isEmpty)
            #expect(row.url.absoluteString == "https://purdue.brightspace.com/d2l/home/\(row.id)")
        }
        #expect(Set(model.courses.map(\.id)).count == model.courses.count, "duplicate ids")
        #expect(model.rows.contains { if case .command(.refresh) = $0 { true } else { false } })
    }
}
