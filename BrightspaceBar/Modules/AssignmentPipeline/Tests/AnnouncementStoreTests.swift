import Foundation
import Testing
import CoursePipeline
import AssignmentPipeline

// ═════════════════════════════════════════════════════════════════════════════
// AnnouncementStore — success replaces, failure preserves, per course.
//
// PRIORITY: no silent data loss under partial failure, the same one
// `AssignmentStoreTests` defends. The rule is inherited verbatim from
// `CourseCache` and `AssignmentStore`, so the backend cannot end up with three
// opinions about what a failed fetch means:
//
//     SUCCESS replaces.  FAILURE preserves.  A successful EMPTY is data.
//
// Announcements make the "empty is data" half more load-bearing than it is for
// assignments, not less: a course that has genuinely posted nothing all term is
// the COMMON case, so "no announcements" has to be a thing the store can say
// with confidence rather than a shrug that also covers "the route 403'd".
//
// SCOPE: all small. In-memory actor, injected clock, no I/O.
// ═════════════════════════════════════════════════════════════════════════════

private func isPreservedStale(_ outcome: CacheOutcome) -> Bool {
    if case .preservedStale = outcome { return true }
    return false
}

@Suite("AnnouncementStore — success replaces, failure preserves, per course")
struct AnnouncementStoreTests {

    // ── The three states stay distinguishable ────────────────────────────────

    @Test("a course that was never fetched reports neverFetched")
    func unknownCourseIsNeverFetched() async {
        // Arrange — the state at launch. A section that says "No announcements"
        // before anything has loaded is a lie that looks exactly like the truth.
        let store = AnnouncementStore(clock: TestClock())

        // Act
        let state = await store.state(for: Truth.scholarlyID)

        // Assert
        #expect(state == .neverFetched)
    }

    @Test("a successful empty fetch is loaded-and-empty, not neverFetched")
    func successfulEmptyIsLoaded() async {
        // Arrange — the common case for announcements: a course where the
        // instructor has posted nothing. The route answered, and the answer was
        // none.
        let store = AnnouncementStore(clock: TestClock())

        // Act
        _ = await store.apply(courseId: Truth.civicsID, result: .success([]))

        // Assert
        #expect(await store.state(for: Truth.civicsID) == .loaded([]))
        #expect(await store.state(for: Truth.civicsID) != .neverFetched)
    }

    @Test("a failure with nothing cached is failed-with-empty, not neverFetched")
    func failureWithNoPriorDataIsDistinguishable() async {
        // Arrange — first-ever fetch fails (a dead cookie at launch). "Couldn't
        // load" and "nothing posted" must stay tellable apart.
        let store = AnnouncementStore(clock: TestClock())

        // Act
        _ = await store.apply(courseId: Truth.civicsID, result: .failure(.sessionExpired))

        // Assert
        #expect(
            await store.state(for: Truth.civicsID) == .failed(lastKnown: [], error: .sessionExpired)
        )
        #expect(await store.state(for: Truth.civicsID) != .loaded([]))
    }

    // ── Success replaces ─────────────────────────────────────────────────────

    @Test("the first successful fetch loads the announcements and reports updated")
    func firstSuccessIsUpdated() async {
        // Arrange
        let store = AnnouncementStore(clock: TestClock())
        let announcements = [makeAnnouncement(id: 1), makeAnnouncement(id: 2)]

        // Act
        let outcome = await store.apply(courseId: Truth.scholarlyID, result: .success(announcements))

        // Assert
        #expect(outcome == .updated)
        #expect(await store.state(for: Truth.scholarlyID) == .loaded(announcements))
    }

    @Test("refetching identical announcements reports unchanged")
    func identicalRefetchIsUnchanged() async {
        // Arrange — matters because the GUI skips rebuilding an unchanged menu.
        // Announcements are refetched on every cycle and change rarely, so this
        // is the outcome the store reports most of the time.
        let store = AnnouncementStore(clock: TestClock())
        let announcements = [makeAnnouncement(id: 1)]
        _ = await store.apply(courseId: Truth.scholarlyID, result: .success(announcements))

        // Act
        let outcome = await store.apply(courseId: Truth.scholarlyID, result: .success(announcements))

        // Assert
        #expect(outcome == .unchanged)
    }

    @Test("a reordered list counts as a change")
    func orderIsPartOfEquality() async {
        // Arrange — the daemon sorts newest-first and the menu shows the top few,
        // so the order IS the content. Equality that ignored it would leave a new
        // post sitting behind an old one until something else changed.
        let store = AnnouncementStore(clock: TestClock())
        let first = makeAnnouncement(id: 1)
        let second = makeAnnouncement(id: 2)
        _ = await store.apply(courseId: Truth.scholarlyID, result: .success([first, second]))

        // Act
        let outcome = await store.apply(courseId: Truth.scholarlyID, result: .success([second, first]))

        // Assert
        #expect(outcome == .updated)
    }

    @Test("a successful empty fetch clears previously loaded announcements")
    func successfulEmptyClears() async {
        // Arrange — the one case where losing data is CORRECT: the daemon said,
        // successfully, that there are none.
        let store = AnnouncementStore(clock: TestClock())
        _ = await store.apply(courseId: Truth.scholarlyID, result: .success([makeAnnouncement(id: 1)]))

        // Act
        _ = await store.apply(courseId: Truth.scholarlyID, result: .success([]))

        // Assert
        #expect(await store.state(for: Truth.scholarlyID) == .loaded([]))
    }

    // ── Failure preserves ────────────────────────────────────────────────────

    @Test("a failed fetch keeps the announcements that were already loaded")
    func failurePreservesLastKnown() async {
        // Arrange — THE test this priority exists for. A dead session must not
        // empty a section that was showing real posts a minute ago.
        let store = AnnouncementStore(clock: TestClock())
        let announcements = [makeAnnouncement(id: 1), makeAnnouncement(id: 2)]
        _ = await store.apply(courseId: Truth.scholarlyID, result: .success(announcements))

        // Act
        let outcome = await store.apply(courseId: Truth.scholarlyID, result: .failure(.sessionExpired))

        // Assert
        #expect(isPreservedStale(outcome))
        #expect(await store.state(for: Truth.scholarlyID).announcements == announcements)
    }

    @Test(
        "every kind of failure preserves, not just an expired session",
        arguments: [
            CourseSourceError.sessionExpired,
            CourseSourceError.httpStatus(403),
            CourseSourceError.malformedBody("garbage"),
            CourseSourceError.transport("course 440703 is not in the daemon cache"),
        ]
    )
    func allFailureKindsPreserve(_ error: CourseSourceError) async {
        // Arrange — the transport case is the one that will actually happen here:
        // an absent course key is how the daemon spells "the news route failed",
        // and it arrives on every refresh until the route recovers.
        let store = AnnouncementStore(clock: TestClock())
        let announcements = [makeAnnouncement(id: 1)]
        _ = await store.apply(courseId: Truth.scholarlyID, result: .success(announcements))

        // Act
        _ = await store.apply(courseId: Truth.scholarlyID, result: .failure(error))

        // Assert
        #expect(await store.state(for: Truth.scholarlyID).announcements == announcements)
    }

    @Test("repeated failures do not erode the preserved announcements")
    func repeatedFailuresDoNotDegrade() async {
        // Arrange — a course whose news route stays 403 is retried every cycle.
        // The tenth failure must preserve exactly what the first one did.
        let store = AnnouncementStore(clock: TestClock())
        let announcements = [makeAnnouncement(id: 1)]
        _ = await store.apply(courseId: Truth.scholarlyID, result: .success(announcements))

        // Act
        for _ in 0 ..< 10 {
            _ = await store.apply(courseId: Truth.scholarlyID, result: .failure(.transport("offline")))
        }

        // Assert
        #expect(await store.state(for: Truth.scholarlyID).announcements == announcements)
    }

    @Test("a success after a failure returns the course to loaded")
    func recoveryAfterFailure() async {
        // Arrange — the stale marker must clear, or the section would apologise
        // forever.
        let store = AnnouncementStore(clock: TestClock())
        _ = await store.apply(courseId: Truth.scholarlyID, result: .success([makeAnnouncement(id: 1)]))
        _ = await store.apply(courseId: Truth.scholarlyID, result: .failure(.sessionExpired))

        // Act
        let fresh = [makeAnnouncement(id: 3), makeAnnouncement(id: 1)]
        let outcome = await store.apply(courseId: Truth.scholarlyID, result: .success(fresh))

        // Assert
        #expect(outcome == .updated)
        #expect(await store.state(for: Truth.scholarlyID) == .loaded(fresh))
    }

    // ── Per-course isolation ─────────────────────────────────────────────────

    @Test("applying a result to one course leaves every other course untouched")
    func coursesAreIsolated() async {
        // Arrange — one course's news route failing while another's answered is
        // the normal shape of a refresh, not an exotic one.
        let store = AnnouncementStore(clock: TestClock())
        let scholarly = [makeAnnouncement(id: 1, courseId: Truth.scholarlyID)]
        let civics = [makeAnnouncement(id: 2, courseId: Truth.civicsID)]
        _ = await store.apply(courseId: Truth.scholarlyID, result: .success(scholarly))
        _ = await store.apply(courseId: Truth.civicsID, result: .success(civics))

        // Act — only Scholarly fails.
        _ = await store.apply(courseId: Truth.scholarlyID, result: .failure(.httpStatus(403)))

        // Assert
        #expect(await store.state(for: Truth.civicsID) == .loaded(civics))
        #expect(await store.state(for: Truth.scholarlyID).announcements == scholarly)
    }

    // ── Timestamps, for the staleness hint ───────────────────────────────────

    @Test("a successful fetch records the injected clock's time for that course")
    func successRecordsLastFetch() async {
        // Arrange — taking the time from an injected clock is also what proves
        // nothing in the store calls `Date()`.
        let clock = TestClock()
        let expected = clock.now
        let store = AnnouncementStore(clock: clock)

        // Act
        _ = await store.apply(courseId: Truth.scholarlyID, result: .success([makeAnnouncement(id: 1)]))

        // Assert
        #expect(await store.lastFetch(for: Truth.scholarlyID) == expected)
    }

    @Test("a failed fetch does not advance the recorded time")
    func failureDoesNotAdvanceLastFetch() async {
        // Arrange — if failure bumped the timestamp, preserved posts would appear
        // fresh and the staleness hint would lie about their age.
        let clock = TestClock()
        let firstFetch = clock.now
        let store = AnnouncementStore(clock: clock)
        _ = await store.apply(courseId: Truth.scholarlyID, result: .success([makeAnnouncement(id: 1)]))

        // Act
        clock.advance(by: 3600)
        _ = await store.apply(courseId: Truth.scholarlyID, result: .failure(.sessionExpired))

        // Assert
        #expect(await store.lastFetch(for: Truth.scholarlyID) == firstFetch)
    }

    // ── The state's own accessor ─────────────────────────────────────────────

    @Test("announcements reads the best available list in all three states")
    func stateExposesBestAvailableList() {
        // Arrange — the translation layer should not have to switch on the state
        // just to render rows; it switches only to decide what note to add.
        let announcements = [makeAnnouncement(id: 1)]

        // Act / Assert
        #expect(AnnouncementsState.neverFetched.announcements.isEmpty)
        #expect(AnnouncementsState.loaded(announcements).announcements == announcements)
        #expect(
            AnnouncementsState.failed(lastKnown: announcements, error: .sessionExpired)
                .announcements == announcements
        )
    }
}
