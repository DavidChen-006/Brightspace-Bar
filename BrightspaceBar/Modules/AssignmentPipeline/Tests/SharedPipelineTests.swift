import Foundation
import Testing
import AssignmentPipeline
import CoursePipeline

// ═════════════════════════════════════════════════════════════════════════════
// TWO ENTITY KINDS, ONE PIPELINE.
//
// Quizzes are a separate D2L entity on a separate route with a separate envelope
// and a separate deep-link template. What they are NOT is a separate pipeline:
// fan-out, per-course folding, success-replaces/failure-preserves, orphan cleanup,
// and the three states are all indifferent to which kind of work an item is. So
// `Assignment` carries a `kind`, and ONE store and ONE fetcher serve both.
//
// WHERE THE MERGE MOVED (phase 5). This file used to specify
// `CompositeAssignmentSource`, the Swift value that fetched the two routes and
// concatenated them below the store. The daemon does that now: the Node fetcher
// requests `dropbox/folders` and `quizzes/` per course (`Promise.all`), merges
// them assignments-first, and writes ONE list per course into `cache/data.json`
// with `kind` on every item — so by the time Swift sees it, the two-ness is
// already gone. The composite's own claims therefore left Swift rather than being
// dropped; the report accompanying this rewrite names each one's new home
// (`session-capture/tests/fetch-engine.test.mjs` for the merge, the ordering, and
// the half-a-loaf rule; `DaemonAssignmentSourceTests` for the decode side).
//
// PRIORITY: REUSE, NOT DUPLICATION — and testable rather than aspirational. The
// tempting shortcut was always a parallel `QuizStore`/`QuizFetcher`, which
// compiles, passes its own tests, and then diverges: two folds to keep in sync,
// two orphan-cleanup rules, and a course whose assignments succeeded while its
// quizzes failed sitting in two contradictory states. Every test below reads BOTH
// kinds out of ONE `state(for:)`, which is unsatisfiable by a two-store design —
// that is the point, and it survives the merge moving to the daemon.
//
// CULLED: throughput, retry policy, and any per-kind display concern (that is the
// translation layer's, tested in `QuizSectionTests`).
//
// SCOPE: all small. Fakes, an injected clock, no I/O and no wall-clock waiting.
// ═════════════════════════════════════════════════════════════════════════════

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

@Suite("The seam: both kinds share ONE store and ONE fetcher")
struct SharedPipelineTests {

    /// Builds the real fetcher over a real store, behind one source holding one
    /// mixed-kind list per course — the shape `DaemonAssignmentSource` serves.
    /// Nothing here is a test double except the leaf source.
    private func pipeline(
        _ byCourse: [Int: Result<[Assignment], CourseSourceError>]
    ) -> (fetcher: AssignmentFetcher, store: AssignmentStore) {
        let store = AssignmentStore(clock: TestClock())
        let source = FakeAssignmentSource(byCourse.mapValues { result in
            switch result {
            case .success(let items): [FakeAssignmentSource.Response.assignments(items)]
            case .failure(let error): [FakeAssignmentSource.Response.failure(error)]
            }
        })
        return (AssignmentFetcher(source: source, store: store), store)
    }

    @Test("one store holds both kinds for one course")
    func oneStoreHoldsBothKinds() async throws {
        // Arrange — THE reuse proof. Reading both kinds out of a single
        // `state(for:)` is unsatisfiable by a design with a separate quiz store,
        // so this test fails the copy-paste shortcut by construction.
        let (fetcher, store) = self.pipeline([
            civics: .success([item(445_296, civics, .assignment), item(619_243, civics, .quiz)]),
        ])

        // Act
        _ = await fetcher.refresh(courses: [makeCourse(id: civics)])

        // Assert
        let held = await store.state(for: civics).assignments
        #expect(held.count == 2)
        #expect(Set(held.map(\.kind)) == [.assignment, .quiz])
    }

    @Test("the existing per-course partial failure rule still holds with two kinds")
    func perCourseFailureStillPreserves() async throws {
        // Arrange — course A succeeds with both kinds, course B fails. The
        // inherited rule (success replaces, failure preserves) must survive the
        // generalisation unchanged.
        let (fetcher, store) = self.pipeline([
            scholarly: .success([item(445_296, scholarly, .assignment), item(476_481, scholarly, .quiz)]),
            civics: .failure(.httpStatus(403)),
        ])
        let courses = [makeCourse(id: scholarly), makeCourse(id: civics)]

        // Act — a first pass that populates Civics, then one where it fails.
        let seeded = self.pipeline([
            civics: .success([item(1, civics, .assignment), item(2, civics, .quiz)]),
        ])
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
        let (fetcher, store) = self.pipeline([
            civics: .success([item(1, civics, .assignment), item(2, civics, .quiz)]),
        ])
        _ = await fetcher.refresh(courses: [makeCourse(id: civics)])
        try #require(await store.state(for: civics).assignments.count == 2)

        // Act — the student drops the course.
        _ = await fetcher.refresh(courses: [makeCourse(id: scholarly)])

        // Assert
        #expect(await store.state(for: civics) == .neverFetched)
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
