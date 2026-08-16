import Foundation
import Testing
import CoursePipeline
import AssignmentPipeline

// ═════════════════════════════════════════════════════════════════════════════
// AnnouncementFetcher — the fan-out, and the announcements vertical end to end.
//
//     [Course]  →  N parallel reads  →  per-course fold
//
// PRIORITY: one course must not be able to damage another. It is the same
// priority the assignment fetcher defends, and the same specific bug is
// available to get wrong — a throwing `TaskGroup` cancels its siblings on the
// first error, so one 403 costs every other course its announcements.
//
// Parallelism is asserted as an OVERLAP COUNT on the fake, never as elapsed
// time: a wall-clock assertion would be flaky and would not prove concurrency.
//
// SCOPE: all small. Several in-process components, no I/O, no real clock.
// ═════════════════════════════════════════════════════════════════════════════

private func makeFetcher(
    _ source: FakeAnnouncementSource,
    clock: TestClock = TestClock()
) -> (fetcher: AnnouncementFetcher, store: AnnouncementStore) {
    let store = AnnouncementStore(clock: clock)
    return (AnnouncementFetcher(source: source, store: store), store)
}

private let realCourses = [
    makeCourse(id: Truth.scholarlyID, name: "Scholarly Project Milestones"),
    makeCourse(id: Truth.civicsID, name: "Purdue Civics Knowledge Test"),
]

@Suite("AnnouncementFetcher — fan-out over courses")
struct AnnouncementFetcherTests {

    // ── The happy path ───────────────────────────────────────────────────────

    @Test("both courses' announcements land in the store, in their own courses")
    func theWholeVerticalWorks() async {
        // Arrange
        let scholarly = [
            makeAnnouncement(id: 1, courseId: Truth.scholarlyID, title: "Urdu Translation Project"),
            makeAnnouncement(id: 2, courseId: Truth.scholarlyID, title: "Mentor Winners"),
        ]
        let civics = [
            makeAnnouncement(id: 3, courseId: Truth.civicsID, title: "Due Date Error Posting")
        ]
        let source = FakeAnnouncementSource([
            Truth.scholarlyID: [.announcements(scholarly)],
            Truth.civicsID: [.announcements(civics)],
        ])
        let (fetcher, store) = makeFetcher(source)

        // Act
        _ = await fetcher.refresh(courses: realCourses)

        // Assert
        #expect(await store.state(for: Truth.scholarlyID) == .loaded(scholarly))
        #expect(await store.state(for: Truth.civicsID) == .loaded(civics))
    }

    // ── Fan-out shape ────────────────────────────────────────────────────────

    @Test("each course is fetched exactly once per refresh")
    func eachCourseIsFetchedOnce() async {
        // Arrange — the reads are free (one cache file, already written), but a
        // duplicated call per course is still a decode per course per refresh.
        let source = FakeAnnouncementSource()
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
        // Arrange — the semester-break case must cost zero calls, not one bare one.
        let source = FakeAnnouncementSource()
        let (fetcher, _) = makeFetcher(source)

        // Act
        let outcomes = await fetcher.refresh(courses: [])

        // Assert
        #expect(await source.totalCallCount == 0)
        #expect(outcomes.isEmpty)
    }

    @Test("the courses are fetched concurrently rather than one after another")
    func fanOutIsParallel() async {
        // Arrange — the fake records a high-water mark of simultaneously
        // in-flight fetches. A sequential loop pins it at 1; a task group pushes
        // it above 1. No sleeping, no timing, no flakiness.
        let source = FakeAnnouncementSource()
        let (fetcher, _) = makeFetcher(source)

        // Act
        _ = await fetcher.refresh(courses: (1 ... 4).map { makeCourse(id: $0) })

        // Assert
        #expect(await source.maxConcurrentFetches > 1, "fan-out ran sequentially")
    }

    @Test("refresh reports an outcome for every course it was given")
    func everyCourseGetsAnOutcome() async {
        // Arrange — a missing key would be a course whose result was silently
        // dropped, and the caller decides what to rebuild from these.
        let source = FakeAnnouncementSource([2: [.failure(.sessionExpired)]])
        let (fetcher, _) = makeFetcher(source)

        // Act
        let outcomes = await fetcher.refresh(courses: (1 ... 3).map { makeCourse(id: $0) })

        // Assert
        #expect(Set(outcomes.keys) == Set([1, 2, 3]))
    }

    // ── Partial failure — the case the design exists for ─────────────────────

    @Test("one course failing leaves the other course's announcements updated")
    func partialFailureIsolatesTheDamage() async {
        // Arrange — the 403 experiment 6 measured on the news route of every
        // inaccessible course.
        let source = FakeAnnouncementSource([
            Truth.scholarlyID: [.announcements([makeAnnouncement(id: 1)])],
            Truth.civicsID: [.failure(.httpStatus(403))],
        ])
        let (fetcher, store) = makeFetcher(source)

        // Act
        let outcomes = await fetcher.refresh(courses: realCourses)

        // Assert
        #expect(outcomes[Truth.scholarlyID] == .updated)
        #expect(outcomes[Truth.civicsID] == .preservedStale(.httpStatus(403)))
        #expect(await store.state(for: Truth.scholarlyID).announcements.count == 1)
    }

    @Test("a thrown error never aborts the whole refresh")
    func oneFailureDoesNotCancelTheRest() async {
        // Arrange — the specific bug a naive throwing `TaskGroup` produces: the
        // first failure cancels its siblings, so one dead course silently costs
        // every other course its announcements.
        let source = FakeAnnouncementSource([
            1: [.failure(.transport("course 1 is not in the daemon cache"))],
            2: [.announcements([makeAnnouncement(id: 20, courseId: 2)])],
            3: [.failure(.malformedBody("an announcement carried no id"))],
            4: [.announcements([makeAnnouncement(id: 40, courseId: 4)])],
        ])
        let (fetcher, store) = makeFetcher(source)

        // Act
        _ = await fetcher.refresh(courses: (1 ... 4).map { makeCourse(id: $0) })

        // Assert — all four were attempted, and both survivors landed.
        #expect(await source.totalCallCount == 4)
        #expect(await store.state(for: 2).announcements.map(\.id) == [20])
        #expect(await store.state(for: 4).announcements.map(\.id) == [40])
    }

    @Test("a course that fails on a later refresh keeps the announcements it already had")
    func failureOnRefreshPreservesPrevious() async {
        // Arrange — the realistic sequence: everything loads, the session dies,
        // then the user opens the menu.
        let source = FakeAnnouncementSource([
            Truth.scholarlyID: [
                .announcements([makeAnnouncement(id: 1)]), .failure(.sessionExpired),
            ]
        ])
        let (fetcher, store) = makeFetcher(source)
        _ = await fetcher.refresh(courses: [makeCourse(id: Truth.scholarlyID)])

        // Act
        _ = await fetcher.refresh(courses: [makeCourse(id: Truth.scholarlyID)])

        // Assert
        #expect(await store.state(for: Truth.scholarlyID).announcements.map(\.id) == [1])
    }

    // ── Orphan cleanup ───────────────────────────────────────────────────────

    @Test("a course no longer in the list has its cached announcements dropped")
    func orphanedCoursesAreForgotten() async {
        // Arrange — you drop a class, or the currentness filter stops listing it.
        let source = FakeAnnouncementSource([
            Truth.scholarlyID: [.announcements([makeAnnouncement(id: 1)])],
            Truth.civicsID: [.announcements([makeAnnouncement(id: 2, courseId: Truth.civicsID)])],
        ])
        let (fetcher, store) = makeFetcher(source)
        _ = await fetcher.refresh(courses: realCourses)

        // Act
        _ = await fetcher.refresh(courses: [makeCourse(id: Truth.scholarlyID)])

        // Assert — forgotten entirely, not emptied: an emptied entry renders as
        // "No announcements" for a course the student is not enrolled in.
        #expect(await store.state(for: Truth.civicsID) == .neverFetched)
        #expect(await store.state(for: Truth.scholarlyID).announcements.count == 1)
    }

    @Test("a failed course is still forgotten when it leaves the course list")
    func orphanCleanupAppliesToFailedCoursesToo() async {
        // Arrange — otherwise a dropped course keeps a stale error forever.
        let source = FakeAnnouncementSource([Truth.civicsID: [.failure(.httpStatus(403))]])
        let (fetcher, store) = makeFetcher(source)
        _ = await fetcher.refresh(courses: [makeCourse(id: Truth.civicsID)])

        // Act
        _ = await fetcher.refresh(courses: [])

        // Assert
        #expect(await store.state(for: Truth.civicsID) == .neverFetched)
    }
}
