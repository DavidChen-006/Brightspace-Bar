import Foundation
import Testing
import AssignmentPipeline
import BrightspaceSession
import CoursePipeline
import QuizPipeline

/// `true` only when the operator asks for a live run: `BS_LIVE=1 swift test`.
/// Read once at load so the gate cannot change mid-suite.
private let bsLiveEnabled = ProcessInfo.processInfo.environment["BS_LIVE"] != nil

// ═════════════════════════════════════════════════════════════════════════════
// THE CONTRACT every quiz source must satisfy — written exactly once.
//
// A fake that drifts from reality yields a green suite and a broken app, so both
// the fixture-backed source and the real network adapter run through one set of
// claims. Mirrors `AssignmentSourceContractTests`.
//
// SCOPE: the hermetic case is small; the live case is large and gated.
// ═════════════════════════════════════════════════════════════════════════════

/// A quiz source scripted from fixture bytes, parsed with the REAL parser so the
/// fake cannot drift by skipping decoding.
private struct FixtureQuizSource: AssignmentSource {
    let payloads: [Int: Data]

    func fetchAssignments(courseId: Int) async throws -> [Assignment] {
        guard let data = self.payloads[courseId] else { return [] }
        return try QuizParser.parse(data, courseId: courseId)
    }
}

private struct SourceCase: Sendable, CustomStringConvertible {
    let name: String
    let make: @Sendable () throws -> any AssignmentSource
    var description: String { self.name }

    static let fixture = SourceCase(name: "FixtureQuizSource") {
        FixtureQuizSource(payloads: [
            QuizTruth.civicsID: try QuizFixture.civics,
            QuizTruth.scholarlyID: try QuizFixture.scholarly,
        ])
    }

    static let live = SourceCase(name: "BrightspaceQuizSource") {
        BrightspaceQuizSource(provider: FileSessionProvider.standard)
    }
}

private func assertQuizSourceContract(_ source: any AssignmentSource, courseId: Int) async throws {
    let quizzes = try await source.fetchAssignments(courseId: courseId)

    // The anti-drift canary: if the live tenant yields nothing while the fixture
    // yields three, the drift surfaces here rather than as an empty submenu.
    #expect(!quizzes.isEmpty, "a quiz source must yield at least one quiz for course \(courseId)")

    for quiz in quizzes {
        #expect(quiz.id > 0, "quiz \(quiz.id) has a non-positive id")
        #expect(!quiz.name.isEmpty, "quiz \(quiz.id) has an empty name")
        // Stamped from the request, since the payload never names the course.
        #expect(quiz.courseId == courseId, "quiz \(quiz.id) carries course \(quiz.courseId)")
        // Without this every quiz renders among the assignments and opens through
        // the wrong link template.
        #expect(quiz.kind == .quiz, "quiz \(quiz.id) is not marked as a quiz")
        // Quizzes have no group concept; a non-nil value would be meaningless and
        // would suggest the assignment decoder had been reused wholesale.
        #expect(quiz.groupTypeId == nil, "quiz \(quiz.id) carries a groupTypeId")
    }

    // Ids key the submenu rows; duplicates would collapse or duplicate entries.
    #expect(Set(quizzes.map(\.id)).count == quizzes.count, "quiz ids must be unique")
}

@Suite("AssignmentSource — the contract a quiz source must satisfy")
struct QuizSourceContractTests {

    @Test("a hermetic quiz source satisfies the contract")
    func hermeticSourceSatisfiesTheContract() async throws {
        let source = try SourceCase.fixture.make()
        try await assertQuizSourceContract(source, courseId: QuizTruth.civicsID)
        try await assertQuizSourceContract(source, courseId: QuizTruth.scholarlyID)
    }

    /// The anti-drift run. Skipped by default so `swift test` stays hermetic and
    /// needs no network, no cookie, and no `session.json`.
    ///
    /// Only works while these two administrative shells remain accessible —
    /// experiment 6 proved every ended course answers 403, so this case cannot be
    /// pointed at a semester course until Fall 2026 goes live.
    @Test("the real Brightspace quiz source satisfies the same contract", .enabled(if: bsLiveEnabled))
    func liveSourceSatisfiesTheContract() async throws {
        let source = try SourceCase.live.make()
        try await assertQuizSourceContract(source, courseId: QuizTruth.civicsID)
    }

    @Test("a course with no quizzes is not an error")
    func emptyCourseIsNotAFailure() async throws {
        // Arrange — a course absent from the script.
        let source = try SourceCase.fixture.make()

        // Act
        let quizzes = try await source.fetchAssignments(courseId: 1)

        // Assert
        #expect(quizzes.isEmpty)
    }
}
