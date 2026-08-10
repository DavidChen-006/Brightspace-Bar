import Foundation
import Testing
import CoursePipeline
import AssignmentPipeline

// ═════════════════════════════════════════════════════════════════════════════
// AssignmentFetcher — the fan-out, and the backend spike's end-to-end test.
//
// This is the whole backend vertical in one call:
//
//     [Course]  →  N parallel GETs  →  parse  →  per-course fold  →  deep links
//
// Both priorities land here together, which is what makes this the suite the
// spike is judged by:
//
//   * PRIORITY 1: the assignments that come out must produce the exact
//     browser-verified URLs, having travelled through real fixture bytes and the
//     real parser rather than being hand-built.
//   * PRIORITY 2: one course failing must not disturb another, and must not
//     empty its own submenu.
//
// Parallelism is asserted as an OVERLAP COUNT on the fake, never as elapsed
// time. A wall-clock assertion here would be flaky and would not actually prove
// concurrency.
//
// SCOPE: small. Multiple in-process components, but no I/O, no network, no real
// clock — the only file access is reading checked-in fixtures.
// ═════════════════════════════════════════════════════════════════════════════

private func makeFetcher(
    _ source: FakeAssignmentSource,
    clock: TestClock = TestClock()
) -> (fetcher: AssignmentFetcher, store: AssignmentStore) {
    let store = AssignmentStore(clock: clock)
    return (AssignmentFetcher(source: source, store: store), store)
}

/// The two real courses, as the course pipeline would hand them over.
private let realCourses = [
    makeCourse(id: Truth.scholarlyID, name: "Scholarly Project Milestones"),
    makeCourse(id: Truth.civicsID, name: "Purdue Civics Knowledge Test"),
]

@Suite("AssignmentFetcher — fan-out over courses")
struct AssignmentFetcherTests {

    // ── THE END-TO-END HAPPY PATH ────────────────────────────────────────────

    @Test("real bytes for both courses become assignments with browser-verified links")
    func theWholeBackendVerticalWorks() async throws {
        // Arrange — the genuine captured payloads, fed through the real parser by
        // the fake. Nothing in this test is hand-built except the course list.
        let source = FakeAssignmentSource([
            Truth.scholarlyID: [.bytes(try Fixture.folders440703)],
            Truth.civicsID: [.bytes(try Fixture.folders412690)],
        ])
        let (fetcher, store) = makeFetcher(source)

        // Act
        _ = await fetcher.refresh(courses: realCourses)

        // Assert — the four real assignments, in their courses, with their names.
        let scholarly = await store.state(for: Truth.scholarlyID).assignments
        let civics = await store.state(for: Truth.civicsID).assignments
        #expect(scholarly.map(\.id) == [Truth.citiID, Truth.purcID, Truth.ideationID])
        #expect(civics.map(\.id) == [Truth.untitledID])
        #expect(scholarly.first?.name == Truth.citiName)

        // And the payoff: every link matches what experiment 7 opened in a browser.
        let links = (scholarly + civics).map {
            AssignmentLink.url(courseId: $0.courseId, assignmentId: $0.id, baseURL: Truth.baseURL)
                .absoluteString
        }
        #expect(links == [Truth.citiURL, Truth.purcURL, Truth.ideationURL, Truth.untitledURL])
    }

    @Test("every assignment's due date survives the full pipeline")
    func dueDatesSurviveTheFullPipeline() async throws {
        // Arrange — the third contract field, end to end. Uses the synthetic
        // fixture because no reachable course has a due date; this is the test
        // that will matter the day a semester course goes live.
        let source = FakeAssignmentSource([777: [.bytes(try Fixture.foldersWithDueDate)]])
        let (fetcher, store) = makeFetcher(source)

        // Act
        _ = await fetcher.refresh(courses: [makeCourse(id: 777)])

        // Assert
        let assignments = await store.state(for: 777).assignments
        #expect(assignments.first { $0.id == 700_001 }?.dueDate == Truth.homework3Due)
        #expect(assignments.first { $0.id == 700_002 }?.dueDate == Truth.groupProjectDue)
        #expect(assignments.first { $0.id == 700_003 }?.dueDate == nil)
    }

    // ── Fan-out shape ────────────────────────────────────────────────────────

    @Test("each course is fetched exactly once per refresh")
    func eachCourseIsFetchedOnce() async {
        // Arrange — N+1 network calls is the cost model the design accepted; N+2
        // would mean a duplicated request per course, doubling the load on the
        // tenant for nothing.
        let source = FakeAssignmentSource()
        let (fetcher, _) = makeFetcher(source)
        let courses = (1 ... 5).map { makeCourse(id: $0) }

        // Act
        _ = await fetcher.refresh(courses: courses)

        // Assert
        for course in courses {
            #expect(await source.callCount(for: course.id) == 1, "course \(course.id)")
        }
        #expect(await source.totalCallCount == 5)
    }

    @Test("an empty course list performs no fetches at all")
    func noCoursesMeansNoRequests() async {
        // Arrange — during a semester break the currentness filter can legitimately
        // yield zero courses. That must cost zero requests, not one bare call.
        let source = FakeAssignmentSource()
        let (fetcher, _) = makeFetcher(source)

        // Act
        let outcomes = await fetcher.refresh(courses: [])

        // Assert
        #expect(await source.totalCallCount == 0)
        #expect(outcomes.isEmpty)
    }

    @Test("the courses are fetched concurrently rather than one after another")
    func fanOutIsParallel() async {
        // Arrange — the fake records a high-water mark of simultaneously in-flight
        // fetches. A sequential loop pins it at 1; a task group pushes it above 1.
        // This is the deterministic way to assert concurrency — no sleeping, no
        // timing, no flakiness.
        let source = FakeAssignmentSource()
        let (fetcher, _) = makeFetcher(source)

        // Act
        _ = await fetcher.refresh(courses: (1 ... 4).map { makeCourse(id: $0) })

        // Assert
        #expect(await source.maxConcurrentFetches > 1, "fan-out ran sequentially")
    }

    @Test("refresh reports an outcome for every course it was given")
    func everyCourseGetsAnOutcome() async {
        // Arrange — the caller decides whether to rebuild the menu from these, so
        // a missing entry is a course whose result was silently dropped.
        let source = FakeAssignmentSource([
            2: [.failure(.sessionExpired)],
        ])
        let (fetcher, _) = makeFetcher(source)
        let courses = (1 ... 3).map { makeCourse(id: $0) }

        // Act
        let outcomes = await fetcher.refresh(courses: courses)

        // Assert
        #expect(Set(outcomes.keys) == Set([1, 2, 3]))
    }

    // ── PARTIAL FAILURE — the case the design exists for ─────────────────────

    @Test("one course failing leaves the other course's assignments updated")
    func partialFailureIsolatesTheDamage() async throws {
        // Arrange — Scholarly succeeds, Civics fails with the 403 that experiment 6
        // showed is what Brightspace actually returns for an inaccessible course.
        let source = FakeAssignmentSource([
            Truth.scholarlyID: [.bytes(try Fixture.folders440703)],
            Truth.civicsID: [.failure(.httpStatus(403))],
        ])
        let (fetcher, store) = makeFetcher(source)

        // Act
        let outcomes = await fetcher.refresh(courses: realCourses)

        // Assert
        #expect(outcomes[Truth.scholarlyID] == .updated)
        #expect(outcomes[Truth.civicsID] == .preservedStale(.httpStatus(403)))
        #expect(await store.state(for: Truth.scholarlyID).assignments.count == 3)
    }

    @Test("a course that fails on a later refresh keeps the assignments it already had")
    func failureOnRefreshPreservesPreviousAssignments() async throws {
        // Arrange — the realistic sequence: everything loads, then the session
        // dies, then the user opens the menu. Both courses must still show work.
        let source = FakeAssignmentSource([
            Truth.scholarlyID: [.bytes(try Fixture.folders440703), .failure(.sessionExpired)],
            Truth.civicsID: [.bytes(try Fixture.folders412690), .failure(.sessionExpired)],
        ])
        let (fetcher, store) = makeFetcher(source)
        _ = await fetcher.refresh(courses: realCourses)

        // Act — second refresh, both fail.
        _ = await fetcher.refresh(courses: realCourses)

        // Assert
        #expect(await store.state(for: Truth.scholarlyID).assignments.count == 3)
        #expect(await store.state(for: Truth.civicsID).assignments.count == 1)
    }

    @Test("a malformed body for one course does not corrupt another")
    func malformedBodyIsContained() async throws {
        // Arrange — a parse failure must behave like any other failure: contained
        // to its course, and preserving rather than clearing.
        let source = FakeAssignmentSource([
            Truth.scholarlyID: [.bytes(try Fixture.folders440703)],
            Truth.civicsID: [.bytes(try Fixture.foldersMalformed)],
        ])
        let (fetcher, store) = makeFetcher(source)

        // Act
        let outcomes = await fetcher.refresh(courses: realCourses)

        // Assert
        #expect(await store.state(for: Truth.scholarlyID).assignments.count == 3)
        #expect(outcomes[Truth.civicsID].map { $0 == .updated } == false)
    }

    @Test("a thrown error never aborts the whole refresh")
    func oneFailureDoesNotCancelTheRest() async throws {
        // Arrange — the specific bug a naive `TaskGroup` with a throwing child
        // produces: the first failure cancels its siblings, so a single dead
        // course silently costs you every other course's assignments.
        let source = FakeAssignmentSource([
            1: [.failure(.transport("offline"))],
            2: [.bytes(try Fixture.folders440703)],
            3: [.failure(.httpStatus(500))],
            4: [.bytes(try Fixture.folders412690)],
        ])
        let (fetcher, store) = makeFetcher(source)

        // Act
        _ = await fetcher.refresh(courses: (1 ... 4).map { makeCourse(id: $0) })

        // Assert — all four were attempted, and both survivors landed.
        #expect(await source.totalCallCount == 4)
        #expect(await store.state(for: 2).assignments.count == 3)
        #expect(await store.state(for: 4).assignments.count == 1)
    }

    // ── Orphan cleanup ───────────────────────────────────────────────────────

    @Test("a course no longer in the list has its cached assignments dropped")
    func orphanedCoursesAreForgotten() async throws {
        // Arrange — you drop a class, or a term ends and the currentness filter
        // stops listing it. Its assignments must not accumulate forever, and must
        // not reappear if the same course id is ever listed again.
        let source = FakeAssignmentSource([
            Truth.scholarlyID: [.bytes(try Fixture.folders440703)],
            Truth.civicsID: [.bytes(try Fixture.folders412690)],
        ])
        let (fetcher, store) = makeFetcher(source)
        _ = await fetcher.refresh(courses: realCourses)
        #expect(await store.state(for: Truth.civicsID) != .neverFetched)

        // Act — refresh with Civics gone from the list.
        _ = await fetcher.refresh(courses: [makeCourse(id: Truth.scholarlyID)])

        // Assert — forgotten entirely, not merely emptied: an emptied entry would
        // render as "No assignments" for a course that is not even enrolled.
        #expect(await store.state(for: Truth.civicsID) == .neverFetched)
        #expect(await store.state(for: Truth.scholarlyID).assignments.count == 3)
    }

    @Test("an empty refresh forgets every course")
    func emptyRefreshForgetsEverything() async throws {
        // Arrange — the semester-break case, following a term where courses loaded.
        let source = FakeAssignmentSource([
            Truth.scholarlyID: [.bytes(try Fixture.folders440703)],
        ])
        let (fetcher, store) = makeFetcher(source)
        _ = await fetcher.refresh(courses: [makeCourse(id: Truth.scholarlyID)])

        // Act
        _ = await fetcher.refresh(courses: [])

        // Assert
        #expect(await store.state(for: Truth.scholarlyID) == .neverFetched)
    }

    @Test("a failed course is still forgotten when it leaves the course list")
    func orphanCleanupAppliesToFailedCoursesToo() async {
        // Arrange — otherwise a dropped course could keep a stale error state
        // forever, and the submenu would apologise about a class you left.
        let source = FakeAssignmentSource([
            Truth.civicsID: [.failure(.httpStatus(403))],
        ])
        let (fetcher, store) = makeFetcher(source)
        _ = await fetcher.refresh(courses: [makeCourse(id: Truth.civicsID)])

        // Act
        _ = await fetcher.refresh(courses: [])

        // Assert
        #expect(await store.state(for: Truth.civicsID) == .neverFetched)
    }
}
