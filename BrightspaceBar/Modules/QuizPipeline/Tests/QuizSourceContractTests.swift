import Foundation
import Testing
import AssignmentPipeline
import CoursePipeline
import QuizPipeline

/// `true` only when the operator asks for a live run: `BS_LIVE=1 swift test`.
/// Read once at load so the gate cannot change mid-suite.
private let bsLiveEnabled = ProcessInfo.processInfo.environment["BS_LIVE"] != nil

/// The daemon a live run spawns — the same resolution `main.swift` performs.
private let liveDaemonCLI = ProcessInfo.processInfo.environment["BSB_REFRESH_CLI"]
    ?? NSHomeDirectory() + "/PaperShelf/session-capture/src/refresh.mjs"

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
}

/// Every claim about a quiz, over a list that has already been narrowed to
/// quizzes. Split out from the source-level check in phase 5, because the live
/// source is no longer quiz-only: the daemon merges a course's assignments and
/// quizzes into one list before it ever reaches disk.
private func assertQuizContract(_ quizzes: [Assignment], courseId: Int) {
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
        assertQuizContract(
            try await source.fetchAssignments(courseId: QuizTruth.civicsID),
            courseId: QuizTruth.civicsID
        )
        assertQuizContract(
            try await source.fetchAssignments(courseId: QuizTruth.scholarlyID),
            courseId: QuizTruth.scholarlyID
        )
    }

    /// The anti-drift run. Skipped by default so `swift test` stays hermetic and
    /// needs no network, no cookie, and no daemon.
    ///
    /// Only works while these two administrative shells remain accessible —
    /// experiment 6 proved every ended course answers 403, so this case cannot be
    /// pointed at a semester course until Fall 2026 goes live.
    ///
    /// Phase 5: the live quiz source is the daemon. There is no `BrightspaceQuizSource`
    /// in the app any more — quizzes ride the same `cache/data.json` list as
    /// assignments, marked `kind: "quiz"` by the Node fetcher. So the arrangement runs
    /// the real `refresh.mjs` once (cron-safe, no `--allow-full-login`, D8) and the
    /// merged list is narrowed to quizzes before the contract is applied.
    ///
    /// This is the ONLY live test that would notice the daemon's quiz route dying:
    /// `AssignmentSourceContractTests` keeps passing on the assignment half alone,
    /// and the quizzes would simply stop appearing in the menu.
    @Test("the real daemon still serves this course's quizzes", .enabled(if: bsLiveEnabled))
    func liveSourceSatisfiesTheContract() async throws {
        // Arrange — one real daemon run against the real `BSB_ROOT`, then its cache
        // read exactly as the app reads it.
        let paths = DaemonPaths.resolve()
        _ = await DaemonRunner(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["node", liveDaemonCLI],
            paths: paths,
            timeout: 180
        ).run()
        let source = DaemonAssignmentSource(paths: paths)

        // Act
        let items = try await source.fetchAssignments(courseId: QuizTruth.civicsID)

        // Assert
        assertQuizContract(items.filter { $0.kind == .quiz }, courseId: QuizTruth.civicsID)
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
