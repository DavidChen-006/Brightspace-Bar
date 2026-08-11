import Foundation
import AssignmentPipeline
import CoursePipeline

// ─────────────────────────────────────────────────────────────────────────────
// Test support for the QuizPipeline spike.
//
// Mirrors `Modules/AssignmentPipeline/Tests/TestSupport.swift` deliberately: same
// `Fixture` shape (resolved via `#filePath`, never `Bundle.module`, so no
// `resources:` entry is needed) and the same hand-transcribed `Truth`, so the two
// item backends read the same way.
// ─────────────────────────────────────────────────────────────────────────────

/// Loads the payloads in `Tests/Fixtures/`. See that directory's README for which
/// files are faithful captures and which are synthetic.
public enum QuizFixture {
    public static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures")
    }

    public static func data(_ name: String) throws -> Data {
        try Data(contentsOf: self.directory.appending(path: name))
    }

    /// The 3 genuine quizzes in Purdue Civics Knowledge Test (412690).
    public static var civics: Data { get throws { try self.data("quizzes-412690.json") } }
    /// The 1 genuine quiz in Scholarly Project Milestones (440703).
    public static var scholarly: Data { get throws { try self.data("quizzes-440703.json") } }
    /// A course with no quizzes — data, not an error.
    public static var empty: Data { get throws { try self.data("quizzes-empty.json") } }
    /// The ASSIGNMENT shape (a bare array) served on the quiz route.
    public static var bareArray: Data { get throws { try self.data("quizzes-bare-array.json") } }
    /// A `problem+json` error body where an envelope was expected.
    public static var malformed: Data { get throws { try self.data("quizzes-malformed.json") } }
    /// The HTTP-200 login stub a dead cookie produces.
    public static var sessionExpiredStub: Data { get throws { try self.data("quizzes-session-expired.html") } }
    /// Synthetic. Both ISO-8601 variants plus one unparseable date.
    public static var withDueDate: Data { get throws { try self.data("quizzes-with-due-date.json") } }
    /// Synthetic. One `IsActive: false` quiz beside a live one.
    public static var inactive: Data { get throws { try self.data("quizzes-inactive.json") } }
    /// Synthetic. The two fatal shapes.
    public static var missingName: Data { get throws { try self.data("quizzes-missing-name.json") } }
    public static var missingID: Data { get throws { try self.data("quizzes-missing-id.json") } }
}

// MARK: - Ground truth, transcribed from the 2026-08-10 live probe

/// Hand-transcribed from the probe output, never recomputed the way the code
/// computes it.
public enum QuizTruth {
    public static let baseURL = URL(string: "https://purdue.brightspace.com")!

    // Purdue Civics Knowledge Test — three quizzes.
    public static let civicsID = 412_690
    public static let honorPledgeID = 619_243
    public static let honorPledgeName = "Honor Pledge"
    public static let practiceID = 619_244
    public static let practiceName = "Practice Quiz - Requires Respondus LockDown Browser"
    public static let welcomeID = 790_340
    public static let welcomeName = "Welcome Quiz"

    // Scholarly Project Milestones — one quiz.
    public static let scholarlyID = 440_703
    public static let moduleOneID = 476_481
    public static let moduleOneName = "Module 1 Completion Quiz - What Is Research?"

    /// The exact deep links verified in a real browser, each of which rendered a
    /// page whose `<h1>` named its own quiz. Written out in full rather than
    /// interpolated, so a template change cannot silently rewrite the expectation
    /// along with the code.
    ///
    /// Note `qi=` (not the assignments' `db=`) and the absence of `grpid`.
    public static let honorPledgeURL =
        "https://purdue.brightspace.com/d2l/lms/quizzing/user/quiz_summary.d2l?qi=619243&ou=412690"
    public static let practiceURL =
        "https://purdue.brightspace.com/d2l/lms/quizzing/user/quiz_summary.d2l?qi=619244&ou=412690"
    public static let welcomeURL =
        "https://purdue.brightspace.com/d2l/lms/quizzing/user/quiz_summary.d2l?qi=790340&ou=412690"
    public static let moduleOneURL =
        "https://purdue.brightspace.com/d2l/lms/quizzing/user/quiz_summary.d2l?qi=476481&ou=440703"

    /// `2026-03-01T04:59:00.000Z` — the synthetic midterm deadline, computed
    /// independently with python3.
    public static let midtermDue = Date(timeIntervalSince1970: 1_772_341_140)
    /// `2026-09-15T23:59:00Z` — the same shape written WITHOUT fractional seconds,
    /// because D2L is not consistent about them and a strict ISO-8601 parser has
    /// already bitten this codebase once.
    public static let finalDue = Date(timeIntervalSince1970: 1_789_516_740)
}
