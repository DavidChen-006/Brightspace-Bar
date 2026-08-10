import Foundation
import Testing
import CoursePipeline
import AssignmentPipeline

// ═════════════════════════════════════════════════════════════════════════════
// PRIORITY 2 — NO SILENT DATA LOSS UNDER PARTIAL FAILURE.
//
// With one call per course, partial failure is the NORMAL case, not the exotic
// one: this tenant's session dies within hours, and a fan-out of five requests
// can lose any subset of them. The store's whole job is to make that survivable.
//
// The rule is inherited verbatim from `CoursePipeline.CourseCache`, so the two
// backend modules cannot disagree about what a failed fetch means:
//
//     SUCCESS replaces.  FAILURE preserves.  A successful EMPTY is data.
//
// What is genuinely new here is GRANULARITY. `CourseCache` folds one result for
// the whole list; this store folds one result PER COURSE, so course A updating
// while course B fails is a state the old cache literally cannot express.
//
// The three states must stay distinguishable — never fetched, fetched-and-empty,
// fetch-failed. Collapsing any two makes the submenu lie: "No assignments" for a
// course that simply has not loaded, or an empty submenu for one whose fetch
// just failed.
//
// SCOPE: all small. In-memory actor, injected clock, no I/O.
// ═════════════════════════════════════════════════════════════════════════════

private func makeAssignment(
    id: Int,
    courseId: Int = Truth.scholarlyID,
    name: String? = nil,
    dueDate: Date? = nil
) -> Assignment {
    Assignment(
        id: id,
        courseId: courseId,
        name: name ?? "Assignment \(id)",
        dueDate: dueDate,
        isHidden: false,
        groupTypeId: nil
    )
}

private func isPreservedStale(_ outcome: CacheOutcome) -> Bool {
    if case .preservedStale = outcome { return true }
    return false
}

@Suite("AssignmentStore — success replaces, failure preserves, per course")
struct AssignmentStoreTests {

    // ── The three states stay distinguishable ────────────────────────────────

    @Test("a course that was never fetched reports neverFetched")
    func unknownCourseIsNeverFetched() async {
        // Arrange — the state at launch, before any network call. The submenu must
        // be able to tell this apart from "loaded, and genuinely empty".
        let store = AssignmentStore(clock: TestClock())

        // Act
        let state = await store.state(for: Truth.scholarlyID)

        // Assert
        #expect(state == .neverFetched)
    }

    @Test("a successful empty fetch is loaded-and-empty, not neverFetched")
    func successfulEmptyIsLoaded() async {
        // Arrange — a real course can have zero assignments. That is data: the
        // submenu should say "No assignments", which it can only do if this state
        // is distinct from "not loaded yet".
        let store = AssignmentStore(clock: TestClock())

        // Act
        _ = await store.apply(courseId: Truth.civicsID, result: .success([]))

        // Assert
        #expect(await store.state(for: Truth.civicsID) == .loaded([]))
        #expect(await store.state(for: Truth.civicsID) != .neverFetched)
    }

    @Test("a failure with nothing cached is failed-with-empty, not neverFetched")
    func failureWithNoPriorDataIsDistinguishable() async {
        // Arrange — first-ever fetch fails (dead cookie at launch). The submenu
        // must be able to say "couldn't load" rather than "no assignments".
        let store = AssignmentStore(clock: TestClock())

        // Act
        _ = await store.apply(courseId: Truth.civicsID, result: .failure(.sessionExpired))

        // Assert
        #expect(await store.state(for: Truth.civicsID) == .failed(lastKnown: [], error: .sessionExpired))
        #expect(await store.state(for: Truth.civicsID) != .neverFetched)
        #expect(await store.state(for: Truth.civicsID) != .loaded([]))
    }

    // ── Success replaces ─────────────────────────────────────────────────────

    @Test("the first successful fetch loads the assignments and reports updated")
    func firstSuccessIsUpdated() async {
        // Arrange
        let store = AssignmentStore(clock: TestClock())
        let assignments = [makeAssignment(id: Truth.citiID), makeAssignment(id: Truth.purcID)]

        // Act
        let outcome = await store.apply(courseId: Truth.scholarlyID, result: .success(assignments))

        // Assert
        #expect(outcome == .updated)
        #expect(await store.state(for: Truth.scholarlyID) == .loaded(assignments))
    }

    @Test("refetching identical assignments reports unchanged")
    func identicalRefetchIsUnchanged() async {
        // Arrange — matters because the GUI skips rebuilding an unchanged menu;
        // reporting `.updated` every time would defeat that optimisation.
        let store = AssignmentStore(clock: TestClock())
        let assignments = [makeAssignment(id: Truth.citiID)]
        _ = await store.apply(courseId: Truth.scholarlyID, result: .success(assignments))

        // Act
        let outcome = await store.apply(courseId: Truth.scholarlyID, result: .success(assignments))

        // Assert
        #expect(outcome == .unchanged)
    }

    @Test("a deleted assignment disappears on the next successful fetch")
    func successReplacesWholesale() async {
        // Arrange — the counterpart to preservation. An instructor deleting an
        // assignment must not leave it lingering in the menu forever, so success
        // REPLACES rather than merges.
        let store = AssignmentStore(clock: TestClock())
        let before = [makeAssignment(id: Truth.citiID), makeAssignment(id: Truth.purcID)]
        _ = await store.apply(courseId: Truth.scholarlyID, result: .success(before))

        // Act — the second fetch no longer mentions 445297.
        let after = [makeAssignment(id: Truth.citiID)]
        let outcome = await store.apply(courseId: Truth.scholarlyID, result: .success(after))

        // Assert
        #expect(outcome == .updated)
        #expect(await store.state(for: Truth.scholarlyID).assignments.map(\.id) == [Truth.citiID])
    }

    @Test("a successful empty fetch clears previously loaded assignments")
    func successfulEmptyClears() async {
        // Arrange — the one case where losing data is CORRECT: the server said,
        // successfully, that there are none.
        let store = AssignmentStore(clock: TestClock())
        _ = await store.apply(courseId: Truth.scholarlyID, result: .success([makeAssignment(id: Truth.citiID)]))

        // Act
        _ = await store.apply(courseId: Truth.scholarlyID, result: .success([]))

        // Assert
        #expect(await store.state(for: Truth.scholarlyID) == .loaded([]))
    }

    // ── Failure preserves ────────────────────────────────────────────────────

    @Test("a failed fetch keeps the assignments that were already loaded")
    func failurePreservesLastKnown() async {
        // Arrange — THE test this priority exists for. A dead session must not
        // empty a submenu that was showing real work a minute ago.
        let store = AssignmentStore(clock: TestClock())
        let assignments = [makeAssignment(id: Truth.citiID), makeAssignment(id: Truth.purcID)]
        _ = await store.apply(courseId: Truth.scholarlyID, result: .success(assignments))

        // Act
        let outcome = await store.apply(courseId: Truth.scholarlyID, result: .failure(.sessionExpired))

        // Assert
        #expect(isPreservedStale(outcome))
        #expect(await store.state(for: Truth.scholarlyID).assignments == assignments)
    }

    @Test("the outcome carries the error that caused the preservation")
    func preservedStaleCarriesItsError() async {
        // Arrange — the caller needs to know WHY, to distinguish "you are offline"
        // from "your session died and needs re-auth".
        let store = AssignmentStore(clock: TestClock())

        // Act
        let outcome = await store.apply(
            courseId: Truth.scholarlyID, result: .failure(.httpStatus(403))
        )

        // Assert
        #expect(outcome == .preservedStale(.httpStatus(403)))
    }

    @Test(
        "every kind of failure preserves, not just an expired session",
        arguments: [
            CourseSourceError.sessionExpired,
            CourseSourceError.httpStatus(403),
            CourseSourceError.httpStatus(500),
            CourseSourceError.malformedBody("garbage"),
            CourseSourceError.transport("offline"),
        ]
    )
    func allFailureKindsPreserve(_ error: CourseSourceError) async {
        // Arrange — 403 matters most here: experiment 6 proved that is exactly what
        // an ended course returns, so it will be the common failure in practice.
        let store = AssignmentStore(clock: TestClock())
        let assignments = [makeAssignment(id: Truth.citiID)]
        _ = await store.apply(courseId: Truth.scholarlyID, result: .success(assignments))

        // Act
        _ = await store.apply(courseId: Truth.scholarlyID, result: .failure(error))

        // Assert
        #expect(await store.state(for: Truth.scholarlyID).assignments == assignments)
    }

    @Test("repeated failures do not erode the preserved assignments")
    func repeatedFailuresDoNotDegrade() async {
        // Arrange — an offline laptop retries many times. The tenth failure must
        // preserve exactly what the first one did.
        let store = AssignmentStore(clock: TestClock())
        let assignments = [makeAssignment(id: Truth.citiID)]
        _ = await store.apply(courseId: Truth.scholarlyID, result: .success(assignments))

        // Act
        for _ in 0 ..< 10 {
            _ = await store.apply(courseId: Truth.scholarlyID, result: .failure(.transport("offline")))
        }

        // Assert
        #expect(await store.state(for: Truth.scholarlyID).assignments == assignments)
    }

    @Test("a success after a failure returns the course to loaded")
    func recoveryAfterFailure() async {
        // Arrange — re-auth succeeds; the stale marker must clear, or the submenu
        // would apologise forever.
        let store = AssignmentStore(clock: TestClock())
        _ = await store.apply(courseId: Truth.scholarlyID, result: .success([makeAssignment(id: Truth.citiID)]))
        _ = await store.apply(courseId: Truth.scholarlyID, result: .failure(.sessionExpired))

        // Act
        let fresh = [makeAssignment(id: Truth.citiID), makeAssignment(id: Truth.ideationID)]
        let outcome = await store.apply(courseId: Truth.scholarlyID, result: .success(fresh))

        // Assert
        #expect(outcome == .updated)
        #expect(await store.state(for: Truth.scholarlyID) == .loaded(fresh))
    }

    // ── Per-course isolation: the genuinely new granularity ──────────────────

    @Test("applying a result to one course leaves every other course untouched")
    func coursesAreIsolated() async {
        // Arrange — the whole reason this is not `CourseCache`. Course A failing
        // must not disturb course B, and vice versa.
        let store = AssignmentStore(clock: TestClock())
        let scholarly = [makeAssignment(id: Truth.citiID, courseId: Truth.scholarlyID)]
        let civics = [makeAssignment(id: Truth.untitledID, courseId: Truth.civicsID)]
        _ = await store.apply(courseId: Truth.scholarlyID, result: .success(scholarly))
        _ = await store.apply(courseId: Truth.civicsID, result: .success(civics))

        // Act — only Scholarly fails.
        _ = await store.apply(courseId: Truth.scholarlyID, result: .failure(.httpStatus(403)))

        // Assert
        #expect(await store.state(for: Truth.civicsID) == .loaded(civics))
        #expect(await store.state(for: Truth.scholarlyID).assignments == scholarly)
    }

    // ── Timestamps, for the staleness hint ───────────────────────────────────

    @Test("a successful fetch records the injected clock's time for that course")
    func successRecordsLastFetch() async {
        // Arrange — the submenu's staleness hint needs to know HOW OLD preserved
        // data is, exactly as the top-level menu's "Updated 3 hours ago" does.
        // Taking it from an injected clock is also what proves nothing here calls
        // `Date()`.
        let clock = TestClock()
        let expected = clock.now
        let store = AssignmentStore(clock: clock)

        // Act
        _ = await store.apply(courseId: Truth.scholarlyID, result: .success([makeAssignment(id: Truth.citiID)]))

        // Assert
        #expect(await store.lastFetch(for: Truth.scholarlyID) == expected)
    }

    @Test("a failed fetch does not advance the recorded time")
    func failureDoesNotAdvanceLastFetch() async {
        // Arrange — if failure bumped the timestamp, preserved data would appear
        // fresh, and the user would trust a list that is hours old.
        let clock = TestClock()
        let firstFetch = clock.now
        let store = AssignmentStore(clock: clock)
        _ = await store.apply(courseId: Truth.scholarlyID, result: .success([makeAssignment(id: Truth.citiID)]))

        // Act
        clock.advance(by: 3600)
        _ = await store.apply(courseId: Truth.scholarlyID, result: .failure(.sessionExpired))

        // Assert
        #expect(await store.lastFetch(for: Truth.scholarlyID) == firstFetch)
    }

    @Test("a never-fetched course has no recorded time")
    func neverFetchedHasNoTimestamp() async {
        // Arrange / Act
        let store = AssignmentStore(clock: TestClock())

        // Assert
        #expect(await store.lastFetch(for: Truth.scholarlyID) == nil)
    }

    // ── The state's own accessor ─────────────────────────────────────────────

    @Test("assignments reads the best available list in all three states")
    func stateExposesBestAvailableList() {
        // Arrange — the translation layer should not have to switch on the state
        // just to render rows; it switches only to decide what NOTE to add.
        let assignments = [makeAssignment(id: Truth.citiID)]

        // Act / Assert
        #expect(AssignmentsState.neverFetched.assignments.isEmpty)
        #expect(AssignmentsState.loaded(assignments).assignments == assignments)
        #expect(
            AssignmentsState.failed(lastKnown: assignments, error: .sessionExpired).assignments == assignments
        )
    }
}
