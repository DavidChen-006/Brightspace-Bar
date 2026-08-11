import Foundation
import Testing
import AssignmentPipeline
import CoursePipeline

// ═════════════════════════════════════════════════════════════════════════════
// THE SHARED SEAM — two entity kinds, one pipeline.
//
// Quizzes are a separate D2L entity on a separate route with a separate envelope
// and a separate deep-link template. What they are NOT is a separate pipeline:
// fan-out, per-course folding, success-replaces/failure-preserves, orphan cleanup,
// and the three states are all indifferent to which kind of work an item is.
//
// So the generalisation is deliberately NOT a parameterised endpoint and NOT a
// second store. It is:
//
//   * `Assignment` gains `kind` — one unified "work I owe" value.
//   * A COMPOSITE source conforms to the existing `AssignmentSource` and hides the
//     two-ness *below* the store. `AssignmentFetcher` and `AssignmentStore` are
//     then reused untouched, because from their side nothing changed.
//
// PRIORITIES:
//
//   1. REUSE, NOT DUPLICATION — and this is testable rather than aspirational.
//      The tempting shortcut is a parallel `QuizStore`/`QuizFetcher`, which
//      compiles, passes its own tests, and then diverges: two folds to keep in
//      sync, two orphan-cleanup rules, and a course whose assignments succeeded
//      while its quizzes failed sitting in two contradictory states. Every test
//      below that reads BOTH kinds out of ONE `state(for:)` is unsatisfiable by a
//      two-store design — that is the point.
//
//   2. PARTIAL FAILURE ACROSS SOURCES. One request per course became TWO. If a
//      quiz fetch failing threw, the course's fresh assignments would be discarded
//      and the whole course would preserve stale — a regression of a shipped
//      feature caused by adding a new one. The composite must return what it got.
//
// CULLED: throughput, retry policy, and any per-kind display concern (that is the
// translation layer's, tested in `QuizSectionTests`).
//
// SCOPE: all small. Fakes, an injected clock, no I/O and no wall-clock waiting.
// ═════════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────
// PINNED POLICY — the builder implements exactly these.
//
// ── Assignment gains `kind`, LAST and DEFAULTED ─────────────────────────────
//     public let kind: ItemKind
//     init(id:courseId:name:dueDate:isHidden:groupTypeId:kind: = .assignment)
//   Last and defaulted so all 257 existing call sites compile untouched. The type
//   keeps the name `Assignment` for the same reason — renaming it, `AssignmentsState`
//   (whose `.assignments` accessor is used throughout), `AssignmentStore` and
//   `AssignmentFetcher` would churn every existing test for no behavioural gain.
//   The name is now slightly historical; that is a cheaper debt than the churn.
//
//     public enum ItemKind: Equatable, Sendable, CaseIterable { case assignment, quiz }
//
// ── CompositeAssignmentSource ───────────────────────────────────────────────
//     public init(sources: [any AssignmentSource])
//   Conforms to `AssignmentSource`, so it plugs into `AssignmentFetcher` with no
//   change to the fetcher at all.
//
//     all sources succeed        →  their items concatenated in SOURCE order
//     some succeed, some fail    →  the successes, and NO throw
//     every source fails         →  throws the FIRST source's error (source order)
//     no sources                 →  []
//
//   "Some fail, no throw" is the deliberate trade. The alternative — throwing —
//   would let a quiz-route failure discard freshly fetched assignments. The cost is
//   that a partial failure is invisible to the store; that is accepted here because
//   the store's job is to protect DATA, and half the data arriving is strictly
//   better than none. A per-kind failure note is a future refinement, not a
//   correctness gap.
//
//   Throwing the FIRST error (rather than a combined one) keeps the existing
//   `CourseSourceError` taxonomy intact so `.sessionExpired` still reaches the
//   store meaningfully, and source order makes it deterministic.
// ─────────────────────────────────────────────────────────────────────────────

private let scholarly = 440_703
private let civics = 412_690

private func item(_ id: Int, _ courseId: Int, _ kind: ItemKind, name: String? = nil) -> Assignment {
    Assignment(
        id: id,
        courseId: courseId,
        name: name ?? "\(kind == .quiz ? "Quiz" : "Assignment") \(id)",
        dueDate: nil,
        isHidden: false,
        groupTypeId: nil,
        kind: kind
    )
}

/// A source that answers per course, counts its calls, and can be made to fail.
/// Separate from `FakeAssignmentSource` because these tests need TWO independent
/// sources with independent call counts.
private actor CountingSource: AssignmentSource {
    private let byCourse: [Int: Result<[Assignment], CourseSourceError>]
    private let yields: Int
    private(set) var callCounts: [Int: Int] = [:]

    init(_ byCourse: [Int: Result<[Assignment], CourseSourceError>], yields: Int = 4) {
        self.byCourse = byCourse
        self.yields = yields
    }

    func callCount(for courseId: Int) -> Int { self.callCounts[courseId] ?? 0 }
    var totalCalls: Int { self.callCounts.values.reduce(0, +) }

    func fetchAssignments(courseId: Int) async throws -> [Assignment] {
        self.callCounts[courseId, default: 0] += 1
        // Real suspension points so genuine parallelism overlaps, with no clock.
        for _ in 0 ..< self.yields { await Task.yield() }
        switch self.byCourse[courseId] {
        case .success(let items): return items
        case .failure(let error): throw error
        case nil: return []
        }
    }
}

/// Records how many fetches were in flight at once, ACROSS sources — the
/// deterministic way to assert parallel fan-out without measuring time.
private actor ConcurrencyWitness {
    private var inFlight = 0
    private(set) var high = 0

    func enter() { self.inFlight += 1; self.high = max(self.high, self.inFlight) }
    func leave() { self.inFlight -= 1 }
}

private actor WitnessedSource: AssignmentSource {
    private let items: [Assignment]
    private let witness: ConcurrencyWitness

    init(items: [Assignment], witness: ConcurrencyWitness) {
        self.items = items
        self.witness = witness
    }

    func fetchAssignments(courseId: Int) async throws -> [Assignment] {
        await self.witness.enter()
        for _ in 0 ..< 6 { await Task.yield() }
        await self.witness.leave()
        return self.items.filter { $0.courseId == courseId }
    }
}

@Suite("CompositeAssignmentSource — merging two entity kinds")
struct CompositeSourceTests {

    @Test("both sources' items come back from one fetch")
    func mergesBothSources() async throws {
        // Arrange — the real shape: three assignments and three quizzes in Civics.
        let assignments = CountingSource([civics: .success([
            item(445_296, civics, .assignment), item(445_297, civics, .assignment),
        ])])
        let quizzes = CountingSource([civics: .success([
            item(619_243, civics, .quiz), item(619_244, civics, .quiz), item(790_340, civics, .quiz),
        ])])
        let composite = CompositeAssignmentSource(sources: [assignments, quizzes])

        // Act
        let items = try await composite.fetchAssignments(courseId: civics)

        // Assert
        #expect(items.count == 5)
        #expect(items.filter { $0.kind == .assignment }.count == 2)
        #expect(items.filter { $0.kind == .quiz }.count == 3)
    }

    @Test("each source is asked exactly once per course")
    func asksEachSourceOncePerCourse() async throws {
        // Arrange
        let assignments = CountingSource([civics: .success([item(1, civics, .assignment)])])
        let quizzes = CountingSource([civics: .success([item(2, civics, .quiz)])])
        let composite = CompositeAssignmentSource(sources: [assignments, quizzes])

        // Act
        _ = try await composite.fetchAssignments(courseId: civics)

        // Assert — a call count, never a timing claim.
        #expect(await assignments.callCount(for: civics) == 1)
        #expect(await quizzes.callCount(for: civics) == 1)
    }

    @Test("the two sources are fetched in parallel, not one after the other")
    func fetchesSourcesInParallel() async throws {
        // Arrange — a shared witness sees both sources' fetches. A sequential
        // implementation never has two in flight, so its high-water mark stays 1.
        let witness = ConcurrencyWitness()
        let composite = CompositeAssignmentSource(sources: [
            WitnessedSource(items: [item(1, civics, .assignment)], witness: witness),
            WitnessedSource(items: [item(2, civics, .quiz)], witness: witness),
        ])

        // Act
        _ = try await composite.fetchAssignments(courseId: civics)

        // Assert
        #expect(await witness.high > 1, "sources were fetched sequentially")
    }

    @Test("merged order follows source order, so output is deterministic")
    func mergedOrderIsSourceOrder() async throws {
        // Arrange — `MenuModel`'s `Equatable` drives the GUI's skip-rebuild, so a
        // composite whose output order depended on which request finished first
        // would make identical data compare unequal between refreshes.
        let assignments = CountingSource([civics: .success([item(11, civics, .assignment)])])
        let quizzes = CountingSource([civics: .success([item(22, civics, .quiz)])])
        let composite = CompositeAssignmentSource(sources: [assignments, quizzes])

        // Act — twice, from a fresh composite each time.
        let first = try await composite.fetchAssignments(courseId: civics).map(\.id)
        let second = try await CompositeAssignmentSource(sources: [assignments, quizzes])
            .fetchAssignments(courseId: civics).map(\.id)

        // Assert
        #expect(first == [11, 22])
        #expect(second == [11, 22])
    }

    @Test("one source failing does not lose the other's items")
    func oneFailureKeepsTheOtherSourcesItems() async throws {
        // Arrange — THE test for priority 2. Quizzes 403 while assignments succeed.
        // Throwing here would make the store preserve stale for the whole course and
        // discard assignments it had just fetched successfully.
        let assignments = CountingSource([civics: .success([
            item(445_296, civics, .assignment), item(445_297, civics, .assignment),
        ])])
        let quizzes = CountingSource([civics: .failure(.httpStatus(403))])
        let composite = CompositeAssignmentSource(sources: [assignments, quizzes])

        // Act
        let items = try await composite.fetchAssignments(courseId: civics)

        // Assert
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.kind == .assignment })
    }

    @Test("a failing first source does not suppress a succeeding second")
    func failureOrderDoesNotMatter() async throws {
        // Arrange — the mirror of the above, so the behaviour cannot depend on
        // which position the failure happens to be in.
        let composite = CompositeAssignmentSource(sources: [
            CountingSource([civics: .failure(.sessionExpired)]),
            CountingSource([civics: .success([item(619_243, civics, .quiz)])]),
        ])

        // Act
        let items = try await composite.fetchAssignments(courseId: civics)

        // Assert
        #expect(items.map(\.id) == [619_243])
    }

    @Test("when every source fails the fetch fails, preserving the error taxonomy")
    func totalFailureThrowsTheFirstError() async throws {
        // Arrange — total failure must NOT read as "success, no work", which would
        // make the store replace real data with nothing. And the specific error has
        // to survive: `.sessionExpired` is what tells the app to re-authenticate.
        let composite = CompositeAssignmentSource(sources: [
            CountingSource([civics: .failure(.sessionExpired)]),
            CountingSource([civics: .failure(.httpStatus(500))]),
        ])

        // Act / Assert — the FIRST source's error, in source order, deterministically.
        await #expect(throws: CourseSourceError.sessionExpired) {
            _ = try await composite.fetchAssignments(courseId: civics)
        }
    }

    @Test("a course with nothing in either source yields no items and no error")
    func emptyEverywhereIsNotAFailure() async throws {
        // Arrange / Act — a real case: a course with neither assignments nor
        // quizzes. `loaded([])` is data and drives the "No assignments" message.
        let composite = CompositeAssignmentSource(sources: [
            CountingSource([:]), CountingSource([:]),
        ])
        let items = try await composite.fetchAssignments(courseId: civics)

        // Assert
        #expect(items.isEmpty)
    }

    @Test("a composite with no sources is empty rather than a crash")
    func noSourcesIsEmpty() async throws {
        // Arrange / Act — degenerate but reachable if a build ever disables a kind.
        let items = try await CompositeAssignmentSource(sources: []).fetchAssignments(courseId: civics)

        // Assert
        #expect(items.isEmpty)
    }
}

@Suite("The seam: both kinds share ONE store and ONE fetcher")
struct SharedPipelineTests {

    /// Builds the real fetcher over a real store with a composite source. Nothing
    /// here is a test double except the two leaf sources.
    private func pipeline(
        assignments: [Int: Result<[Assignment], CourseSourceError>],
        quizzes: [Int: Result<[Assignment], CourseSourceError>]
    ) -> (fetcher: AssignmentFetcher, store: AssignmentStore) {
        let store = AssignmentStore(clock: TestClock())
        let composite = CompositeAssignmentSource(sources: [
            CountingSource(assignments), CountingSource(quizzes),
        ])
        return (AssignmentFetcher(source: composite, store: store), store)
    }

    @Test("one store holds both kinds for one course")
    func oneStoreHoldsBothKinds() async throws {
        // Arrange — THE reuse proof. Reading both kinds out of a single
        // `state(for:)` is unsatisfiable by a design with a separate quiz store,
        // so this test fails the copy-paste shortcut by construction.
        let (fetcher, store) = self.pipeline(
            assignments: [civics: .success([item(445_296, civics, .assignment)])],
            quizzes: [civics: .success([item(619_243, civics, .quiz)])]
        )

        // Act
        _ = await fetcher.refresh(courses: [makeCourse(id: civics)])

        // Assert
        let held = await store.state(for: civics).assignments
        #expect(held.count == 2)
        #expect(Set(held.map(\.kind)) == [.assignment, .quiz])
    }

    @Test("the existing per-course partial failure rule still holds with two kinds")
    func perCourseFailureStillPreserves() async throws {
        // Arrange — course A succeeds, course B fails in BOTH sources. The
        // inherited rule (success replaces, failure preserves) must survive the
        // generalisation unchanged.
        let (fetcher, store) = self.pipeline(
            assignments: [
                scholarly: .success([item(445_296, scholarly, .assignment)]),
                civics: .failure(.httpStatus(403)),
            ],
            quizzes: [
                scholarly: .success([item(476_481, scholarly, .quiz)]),
                civics: .failure(.httpStatus(403)),
            ]
        )
        let courses = [makeCourse(id: scholarly), makeCourse(id: civics)]

        // Act — a first pass that populates Civics, then one where it fails.
        let seeded = self.pipeline(
            assignments: [civics: .success([item(1, civics, .assignment)])],
            quizzes: [civics: .success([item(2, civics, .quiz)])]
        )
        _ = await seeded.fetcher.refresh(courses: [makeCourse(id: civics)])
        let outcomes = await fetcher.refresh(courses: courses)

        // Assert — the successful course updated; the failed one is a preserved
        // failure rather than an empty success.
        #expect(outcomes[scholarly] == .updated)
        #expect(outcomes[civics] == .preservedStale(.httpStatus(403)))
        #expect(await store.state(for: scholarly).assignments.count == 2)
        guard case .failed = await store.state(for: civics) else {
            Issue.record("Civics should be .failed, not \(await store.state(for: civics))")
            return
        }
    }

    @Test("a course dropped from the list forgets both its assignments and its quizzes")
    func orphanCleanupCoversBothKinds() async throws {
        // Arrange — orphan cleanup is implied by `refresh(courses:)`. With two
        // stores it would have to be invoked twice, and forgetting one leaves a
        // dropped class still listing quizzes.
        let (fetcher, store) = self.pipeline(
            assignments: [civics: .success([item(1, civics, .assignment)])],
            quizzes: [civics: .success([item(2, civics, .quiz)])]
        )
        _ = await fetcher.refresh(courses: [makeCourse(id: civics)])
        try #require(await store.state(for: civics).assignments.count == 2)

        // Act — the student drops the course.
        _ = await fetcher.refresh(courses: [makeCourse(id: scholarly)])

        // Assert
        #expect(await store.state(for: civics) == .neverFetched)
    }

    @Test("a quiz-route failure alone leaves the course's assignments loaded, not stale")
    func quizFailureDoesNotDegradeTheCourse() async throws {
        // Arrange — the composite's partial-success rule, observed through the
        // store. This is the regression guard: adding quizzes must not be able to
        // downgrade a course that previously loaded its assignments fine.
        let (fetcher, store) = self.pipeline(
            assignments: [civics: .success([item(445_296, civics, .assignment)])],
            quizzes: [civics: .failure(.httpStatus(403))]
        )

        // Act
        let outcomes = await fetcher.refresh(courses: [makeCourse(id: civics)])

        // Assert
        #expect(outcomes[civics] == .updated)
        guard case .loaded(let held) = await store.state(for: civics) else {
            Issue.record("expected .loaded, got \(await store.state(for: civics))")
            return
        }
        #expect(held.map(\.kind) == [.assignment])
    }
}

@Suite("ItemKind and the defaulted Assignment initialiser")
struct ItemKindTests {

    @Test("an assignment built without naming a kind is an assignment")
    func kindDefaultsToAssignment() {
        // Arrange / Act — the defaulted parameter is what keeps 257 existing call
        // sites compiling untouched, so it is worth a test of its own.
        let built = Assignment(
            id: 445_296, courseId: scholarly, name: "Upload your CITI Certificate",
            dueDate: nil, isHidden: false, groupTypeId: nil
        )

        // Assert
        #expect(built.kind == .assignment)
    }

    @Test("kind participates in equality, so a quiz never compares equal to an assignment")
    func kindAffectsEquality() {
        // Arrange — the store decides `.unchanged` by comparing lists. If `kind`
        // were excluded from equality, a course whose assignment was replaced by a
        // same-id quiz would report no change and the menu would not rebuild.
        let asAssignment = item(1, civics, .assignment, name: "Same")
        let asQuiz = item(1, civics, .quiz, name: "Same")

        // Assert
        #expect(asAssignment != asQuiz)
    }

    @Test("both kinds exist and are distinct")
    func bothKindsExist() {
        // Arrange / Act / Assert — `CaseIterable` so a future third kind (a graded
        // discussion, a checklist) is discoverable rather than hidden in a switch.
        #expect(Set(ItemKind.allCases) == [.assignment, .quiz])
    }
}
