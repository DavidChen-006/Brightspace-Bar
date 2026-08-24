import Foundation
import Testing
import CoursePipeline

// ─────────────────────────────────────────────────────────────────────────────
// Concern 2 — Caching.
//
// Test-design priorities, in order. Every test below traces to one of these; if
// it traced to neither it was cut.
//
//   P1. DATA INTEGRITY UNDER FETCH FAILURE.
//       This cache backs a menu bar whose auth dies hourly. The catastrophic
//       bug is: session dies -> nothing decodes -> an empty list overwrites good
//       data on disk -> the menu is blank permanently, across relaunches. Every
//       `preservedStale` assertion, and the empty-success-vs-failure
//       discrimination, exists for this.
//
//   P2. CORRECTNESS OF THE CHANGE DECISION (`unchanged` vs `updated`).
//       The cheap failure is needless disk churn. The expensive failure is
//       reporting `.unchanged` when the data really changed, so the UI never
//       rebuilds and a dropped class shows forever.
//
// Explicitly NOT prioritized: crash-atomicity of the write (cannot be observed
// without killing a process mid-write), the on-disk encoding format (that is
// implementation structure, not behavior — a format change must not break these
// tests), and concurrency stress (the `actor` provides mutual exclusion, and
// overlapping fetches are the poller's concern).
//
// Scope: Google MEDIUM throughout. The frozen seam takes a `fileURL`, so the
// filesystem *is* the contract and there is nothing smaller that can verify
// persistence. They stay fast regardless: no network, no sleeping, injected clock.
//
// This suite deliberately does NOT touch `EnrollmentParser`. The cache consumes
// `Result<[Course], CourseSourceError>`, never raw bytes, so coupling to another
// concern's in-flight module would be a defect in the test, not thoroughness.
// ─────────────────────────────────────────────────────────────────────────────

@Suite("CourseCache")
struct CourseCacheTests {

    // MARK: - Fixtures & helpers

    /// The staleness window used throughout. One hour matches the JWT lifetime.
    static let window: TimeInterval = 3600

    /// Bytes the cache would never legitimately write. Used to prove whether a
    /// write happened — see `applyingIdenticalCoursesDoesNotRewriteTheFile`.
    static let sentinel = Data("NOT-JSON-CACHE-SENTINEL".utf8)

    private func course(_ id: Int, name: String? = nil, code: String? = nil) -> Course {
        Course(
            id: id,
            name: name ?? "Course \(id)",
            code: code ?? "SUBJ-\(id)",
            role: "Learner",
            isActive: true,
            homeUrl: "https://purdue.brightspace.com/d2l/home/\(id)",
            startDate: nil,
            endDate: nil
        )
    }

    private func courses(count: Int) -> [Course] {
        (1...count).map { self.course($0) }
    }

    /// Runs `body` against an isolated cache-file path.
    ///
    /// `TempDir` is `~Copyable` and has a `deinit`, so Swift is free to end its
    /// lifetime at its LAST USE rather than at end of scope. Without the explicit
    /// `consume` below, `tmp`'s last use would be the `tmp.file()` call on the
    /// first line, and the directory could be deleted out from under a test that
    /// is still writing to it. The `consume` pins the lifetime across `body`.
    private func withCacheFile(
        _ body: (URL) async throws -> Void
    ) async throws {
        let tmp = try TempDir()
        let file = tmp.file()
        try await body(file)
        _ = consume tmp
    }

    private func makeCache(
        at file: URL,
        clock: TestClock,
        staleAfter: TimeInterval = CourseCacheTests.window
    ) -> CourseCache {
        CourseCache(fileURL: file, clock: clock, staleAfter: staleAfter)
    }

    // MARK: - P1: cold start and loading (integrity of `load`)

    @Test("A cold cache with no file on disk is empty, has never fetched, and is stale")
    func coldStartIsEmptyAndStale() async throws {
        try await self.withCacheFile { file in
            // Arrange
            let clock = TestClock()
            let cache = self.makeCache(at: file, clock: clock)

            // Act
            await cache.load()

            // Assert
            #expect(await cache.courses == [])
            #expect(await cache.lastFetch == nil)
            #expect(await cache.isStale == true, "never-fetched must be stale, or nothing ever fetches")
        }
    }

    @Test("Loading restores the courses and the fetch time persisted by a previous run")
    func loadRestoresPersistedState() async throws {
        try await self.withCacheFile { file in
            // Arrange — a previous run persisted 3 courses at T.
            let clock = TestClock()
            let start = clock.now
            let persisted = self.courses(count: 3)
            let writer = self.makeCache(at: file, clock: clock)
            _ = await writer.apply(.success(persisted))

            // Act — a fresh instance over the same file, as if the app relaunched.
            let reloaded = self.makeCache(at: file, clock: clock)
            await reloaded.load()

            // Assert
            #expect(await reloaded.courses == persisted)
            #expect(await reloaded.lastFetch == start)
        }
    }

    /// P1. A cache that crashes or throws on a damaged file is worse than useless:
    /// the app cannot launch. Every unreadable shape must degrade to "empty".
    @Test(
        "Any unreadable file loads as an empty cache rather than crashing",
        arguments: [
            "truncated",
            "wrong-shape",
            "garbage",
            "empty",
        ]
    )
    func unreadableFileLoadsAsEmptyCache(kind: String) async throws {
        try await self.withCacheFile { file in
            // Arrange — write a file the cache cannot possibly decode.
            let payload: Data
            switch kind {
            case "truncated":
                // First half of a plausible, valid encoding.
                let full = Data(#"{"fetchedAt":"2026-08-08T00:00:00Z","courses":[{"id":1,"#.utf8)
                payload = full
            case "wrong-shape":
                payload = Data(#"{"totallyDifferent":true,"courses":"not-an-array"}"#.utf8)
            case "garbage":
                payload = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
            default:
                payload = Data()
            }
            try payload.write(to: file)

            let cache = self.makeCache(at: file, clock: TestClock())

            // Act — must not throw, must not crash.
            await cache.load()

            // Assert
            #expect(await cache.courses == [], "corrupt file (\(kind)) must yield an empty cache")
            #expect(await cache.lastFetch == nil, "a corrupt file must not produce a fetch timestamp")
        }
    }

    // MARK: - P2: change detection

    @Test("Applying the identical course list reports unchanged")
    func identicalCoursesReportUnchanged() async throws {
        try await self.withCacheFile { file in
            // Arrange
            let cache = self.makeCache(at: file, clock: TestClock())
            let list = self.courses(count: 5)
            _ = await cache.apply(.success(list))

            // Act
            let outcome = await cache.apply(.success(list))

            // Assert
            #expect(outcome == .unchanged)
        }
    }

    /// P2. Proves no needless write, WITHOUT depending on filesystem timestamp
    /// granularity.
    ///
    /// The SPEC suggests comparing mtime. mtime can false-PASS: if the clock
    /// granularity ever exceeds the gap between two writes, a genuine rewrite
    /// looks identical to no rewrite and the test passes wrongly. Clobbering the
    /// file with bytes the cache would never produce and asserting they survive
    /// is deterministic and has no timing assumption at all.
    ///
    /// Note this also (correctly) fails an implementation whose `apply` consults
    /// disk before deciding: `apply` must compare against in-memory state.
    @Test("Applying the identical course list does not rewrite the file")
    func applyingIdenticalCoursesDoesNotRewriteTheFile() async throws {
        try await self.withCacheFile { file in
            // Arrange — populate, then replace the file body with a sentinel.
            let cache = self.makeCache(at: file, clock: TestClock())
            let list = self.courses(count: 5)
            _ = await cache.apply(.success(list))
            try Self.sentinel.write(to: file)

            // Act
            let outcome = await cache.apply(.success(list))

            // Assert
            #expect(outcome == .unchanged)
            #expect(
                try Data(contentsOf: file) == Self.sentinel,
                "an unchanged result must not touch the file"
            )
        }
    }

    /// The control for the test above. Without it, the sentinel could survive
    /// simply because the cache never writes anything, and both tests would pass
    /// while persistence was entirely broken.
    @Test("Applying a different course list does rewrite the file")
    func applyingDifferentCoursesRewritesTheFile() async throws {
        try await self.withCacheFile { file in
            // Arrange
            let cache = self.makeCache(at: file, clock: TestClock())
            _ = await cache.apply(.success(self.courses(count: 5)))
            try Self.sentinel.write(to: file)

            // Act
            let outcome = await cache.apply(.success(self.courses(count: 6)))

            // Assert
            #expect(outcome == .updated)
            #expect(
                try Data(contentsOf: file) != Self.sentinel,
                "a changed result must persist — otherwise the sentinel proves nothing"
            )
        }
    }

    /// P2. The obvious wrong implementation compares `count`. This is the test
    /// that catches it: same number of courses, one renamed.
    @Test("A renamed course is an update even though the count is unchanged")
    func renamedCourseIsAnUpdate() async throws {
        try await self.withCacheFile { file in
            // Arrange
            let cache = self.makeCache(at: file, clock: TestClock())
            let before = [self.course(1, name: "Systems Programming"), self.course(2)]
            _ = await cache.apply(.success(before))
            let after = [self.course(1, name: "Systems Programming II"), self.course(2)]

            // Act
            let outcome = await cache.apply(.success(after))

            // Assert
            #expect(outcome == .updated)
            #expect(await cache.courses == after)
        }
    }

    /// Pins a design decision: `[Course]` is an ordered Array, not a Set, and the
    /// menu renders in that order — so a reordering is a user-visible change and
    /// must count as `.updated`.
    @Test("Reordering the same courses is an update, because order is user-visible")
    func reorderingIsAnUpdate() async throws {
        try await self.withCacheFile { file in
            // Arrange
            let cache = self.makeCache(at: file, clock: TestClock())
            let a = self.course(1)
            let b = self.course(2)
            _ = await cache.apply(.success([a, b]))

            // Act
            let outcome = await cache.apply(.success([b, a]))

            // Assert
            #expect(outcome == .updated)
            #expect(await cache.courses == [b, a])
        }
    }

    /// The case the real backend physically cannot produce — the reason a fake
    /// exists at all. Enrollments only change a few times a year.
    @Test("Dropping a course from 27 to 26 updates the cache and removes that course")
    func droppingACourseRemovesIt() async throws {
        try await self.withCacheFile { file in
            // Arrange — the live tenant returns 27.
            let cache = self.makeCache(at: file, clock: TestClock())
            let full = self.courses(count: 27)
            _ = await cache.apply(.success(full))
            let dropped = full[13]
            var remaining = full
            remaining.remove(at: 13)

            // Act
            let outcome = await cache.apply(.success(remaining))

            // Assert
            #expect(outcome == .updated)
            #expect(await cache.courses.count == 26)
            #expect(
                await cache.courses.contains(dropped) == false,
                "the dropped course must be gone, not merely outnumbered"
            )
        }
    }

    /// P2. A successful fetch that happened to return identical data is still a
    /// successful fetch. If `lastFetch` did not advance, `isStale` would stay
    /// true forever and a timer-driven poller would hit the server every tick.
    /// The file is still not rewritten (see the sentinel test) — the cost is at
    /// most one extra fetch after a relaunch, which is the right trade.
    @Test("An unchanged result still counts as a fetch, so the cache stops being stale")
    func unchangedResultStillAdvancesLastFetch() async throws {
        try await self.withCacheFile { file in
            // Arrange
            let clock = TestClock()
            let start = clock.now
            let cache = self.makeCache(at: file, clock: clock)
            let list = self.courses(count: 4)
            _ = await cache.apply(.success(list))
            clock.advance(by: Self.window * 2)
            #expect(await cache.isStale == true, "precondition: should be stale before re-fetch")

            // Act
            let outcome = await cache.apply(.success(list))

            // Assert
            #expect(outcome == .unchanged)
            #expect(await cache.lastFetch == start.addingTimeInterval(Self.window * 2))
            #expect(await cache.isStale == false, "an unchanged fetch must reset staleness")
        }
    }

    // MARK: - P1: failure must never degrade good data

    @Test(
        "A failed fetch preserves the existing courses",
        arguments: [
            CourseSourceError.sessionExpired,
            CourseSourceError.transport("offline"),
            CourseSourceError.httpStatus(500),
            CourseSourceError.malformedBody("not enrollments"),
        ]
    )
    func failedFetchPreservesExistingCourses(error: CourseSourceError) async throws {
        try await self.withCacheFile { file in
            // Arrange
            let cache = self.makeCache(at: file, clock: TestClock())
            let good = self.courses(count: 27)
            _ = await cache.apply(.success(good))

            // Act
            let outcome = await cache.apply(.failure(error))

            // Assert
            #expect(outcome == .preservedStale(error))
            #expect(
                await cache.courses == good,
                "a \(error) must not empty the menu"
            )
        }
    }

    @Test("A failed fetch does not advance the last-fetch time")
    func failedFetchDoesNotAdvanceLastFetch() async throws {
        try await self.withCacheFile { file in
            // Arrange
            let clock = TestClock()
            let start = clock.now
            let cache = self.makeCache(at: file, clock: clock)
            _ = await cache.apply(.success(self.courses(count: 3)))
            clock.advance(by: 120)

            // Act
            _ = await cache.apply(.failure(.sessionExpired))

            // Assert — a failure is not a fetch; pretending otherwise would
            // suppress the retry that recovers the session.
            #expect(await cache.lastFetch == start)
        }
    }

    @Test("A failed fetch does not touch the persisted file")
    func failedFetchDoesNotTouchTheFile() async throws {
        try await self.withCacheFile { file in
            // Arrange
            let cache = self.makeCache(at: file, clock: TestClock())
            _ = await cache.apply(.success(self.courses(count: 3)))
            try Self.sentinel.write(to: file)

            // Act
            _ = await cache.apply(.failure(.sessionExpired))

            // Assert — this is the regression that would make a blank menu
            // survive a relaunch.
            #expect(try Data(contentsOf: file) == Self.sentinel)
        }
    }

    @Test("A failure on a cold cache creates no file and fabricates no fetch time")
    func failureOnColdCacheCreatesNoFile() async throws {
        try await self.withCacheFile { file in
            // Arrange — first launch, session already dead.
            let cache = self.makeCache(at: file, clock: TestClock())
            await cache.load()

            // Act
            let outcome = await cache.apply(.failure(.sessionExpired))

            // Assert
            #expect(outcome == .preservedStale(.sessionExpired))
            #expect(await cache.courses == [])
            #expect(await cache.lastFetch == nil)
            #expect(
                FileManager.default.fileExists(atPath: file.path) == false,
                "a failure must not create a cache file"
            )
        }
    }

    /// P1. THE discrimination. Both arms end with "no new courses to show", and a
    /// naive implementation collapses them — but one is legitimate data and the
    /// other is a dead session. Deliberately two-armed: the behavior under test
    /// is the divergence itself, which no single-arm test can state.
    @Test("An empty success clears the list, whereas a failure preserves it")
    func emptySuccessClearsButFailurePreserves() async throws {
        try await self.withCacheFile { file in
            // Arrange — two caches in identical states, separate files.
            let clock = TestClock()
            let good = self.courses(count: 27)

            let emptied = self.makeCache(at: file, clock: clock)
            _ = await emptied.apply(.success(good))

            let preserved = self.makeCache(at: file.deletingLastPathComponent().appending(path: "other.json"), clock: clock)
            _ = await preserved.apply(.success(good))

            // Act — a real user who dropped everything, vs. a dead session.
            let emptyOutcome = await emptied.apply(.success([]))
            let failOutcome = await preserved.apply(.failure(.sessionExpired))

            // Assert — the two paths must diverge.
            #expect(emptyOutcome == .updated, "genuinely having no courses is data, not an error")
            #expect(await emptied.courses == [])

            #expect(failOutcome == .preservedStale(.sessionExpired))
            #expect(await preserved.courses == good)
        }
    }

    // MARK: - P2: staleness is a pure function of the injected clock

    /// Boundary decision: staleness is INCLUSIVE — `now - lastFetch >= staleAfter`
    /// is stale. With a poll interval equal to the window, an exclusive test would
    /// make the tick at exactly the boundary a no-op and effectively double the
    /// refresh period. Inclusive is the safe default.
    @Test(
        "Staleness follows elapsed time against the window",
        arguments: [
            (TimeInterval(0), false),
            (CourseCacheTests.window - 1, false),
            (CourseCacheTests.window, true),
            (CourseCacheTests.window + 1, true),
        ]
    )
    func stalenessFollowsElapsedTime(elapsed: TimeInterval, expectStale: Bool) async throws {
        try await self.withCacheFile { file in
            // Arrange
            let clock = TestClock()
            let cache = self.makeCache(at: file, clock: clock)
            _ = await cache.apply(.success(self.courses(count: 2)))

            // Act
            clock.advance(by: elapsed)

            // Assert
            #expect(await cache.isStale == expectStale, "after \(elapsed)s with a \(Self.window)s window")
        }
    }
}
