import Foundation
import Testing
import QuizPipeline

// ═════════════════════════════════════════════════════════════════════════════
// QuizLink — the click target for one quiz.
//
// PRIORITY 1 (click-target correctness) lands here more sharply than anywhere
// else in this vertical, because the app now has TWO templates and TWO id
// namespaces. Three distinct silent failures become possible:
//
//   1. `qi`/`ou` TRANSPOSED. Both are `Int`, both plausible in either slot. The
//      URL is well-formed, Brightspace answers it, and the user lands somewhere
//      real that is not their quiz.
//   2. The ASSIGNMENT template used for a quiz. `folder_submit_files.d2l?db=…`
//      with a quiz id is a valid-looking dropbox URL for a folder that does not
//      exist — again a real page, again the wrong one.
//   3. A `grpid` carried over from the assignment template. Quizzes have no group
//      parameter; the harvested href had none.
//
// None of these is catchable downstream: `MenuAssembler` opens whatever URL it is
// handed, and it was deliberately built with no index arithmetic precisely so the
// whole burden sits in pure functions like this one.
//
// SCOPE: small — two integers and a base URL in, a URL out. No I/O, no state.
// ═════════════════════════════════════════════════════════════════════════════

/// One browser-verified (course, quiz) pair. Named so a failure says which.
private struct LinkCase: Sendable, CustomStringConvertible {
    let label: String
    let courseId: Int
    let quizId: Int
    let expected: String
    var description: String { self.label }
}

@Suite("QuizLink — the verified deep link")
struct QuizLinkTests {

    /// All four real quizzes. The ids are deliberately non-adjacent and the two
    /// courses differ, so a `qi`/`ou` transposition cannot coincidentally produce
    /// the right string for any of them.
    private static let cases: [LinkCase] = [
        LinkCase(label: "Honor Pledge", courseId: QuizTruth.civicsID,
                 quizId: QuizTruth.honorPledgeID, expected: QuizTruth.honorPledgeURL),
        LinkCase(label: "Practice Quiz", courseId: QuizTruth.civicsID,
                 quizId: QuizTruth.practiceID, expected: QuizTruth.practiceURL),
        LinkCase(label: "Welcome Quiz", courseId: QuizTruth.civicsID,
                 quizId: QuizTruth.welcomeID, expected: QuizTruth.welcomeURL),
        LinkCase(label: "Module 1 Completion Quiz", courseId: QuizTruth.scholarlyID,
                 quizId: QuizTruth.moduleOneID, expected: QuizTruth.moduleOneURL),
    ]

    @Test("each real quiz gets the exact URL a browser confirmed", arguments: QuizLinkTests.cases)
    fileprivate func realQuizzesGetTheirVerifiedURL(_ testCase: LinkCase) {
        // Arrange / Act
        let url = QuizLink.url(
            courseId: testCase.courseId,
            quizId: testCase.quizId,
            baseURL: QuizTruth.baseURL
        )

        // Assert — full-string equality against a hand-written literal. A weaker
        // assertion (contains "qi=…") would pass a URL pointing at the wrong path.
        #expect(url.absoluteString == testCase.expected)
    }

    @Test("the quiz id lands in qi and the course id in ou, never the reverse")
    func idsAreNotTransposed() {
        // Arrange — two ids that are both plausible as either, so only correct
        // placement can satisfy both halves.
        let url = QuizLink.url(courseId: 412_690, quizId: 619_243, baseURL: QuizTruth.baseURL)

        // Act
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        // Assert
        #expect(query.first { $0.name == "qi" }?.value == "619243")
        #expect(query.first { $0.name == "ou" }?.value == "412690")
    }

    @Test("the path is the quizzing summary page, not the dropbox submit page")
    func usesTheQuizPathNotTheAssignmentPath() {
        // Arrange / Act — the cross-template mistake: a quiz routed through the
        // assignment template yields a real dropbox URL for a folder that does not
        // exist, which is the "valid page, wrong destination" failure.
        let url = QuizLink.url(courseId: 412_690, quizId: 619_243, baseURL: QuizTruth.baseURL)

        // Assert
        #expect(url.path == "/d2l/lms/quizzing/user/quiz_summary.d2l")
        #expect(!url.absoluteString.contains("dropbox"))
        #expect(!url.absoluteString.contains("db="))
    }

    @Test("no grpid parameter is carried over from the assignment template")
    func carriesNoGroupParameter() {
        // Arrange / Act — the harvested href had no `grpid`. Adding one because the
        // sibling template has one would be inventing a parameter D2L never sent.
        let url = QuizLink.url(courseId: 412_690, quizId: 619_243, baseURL: QuizTruth.baseURL)

        // Assert
        #expect(!url.absoluteString.contains("grpid"))
    }

    @Test("a baseURL with a trailing slash does not produce a doubled slash")
    func trailingSlashInBaseURLIsHandled() throws {
        // Arrange — a caller passing "https://host/" is entirely plausible, and
        // "host//d2l/..." is a different URL that may not resolve.
        let base = try #require(URL(string: "https://purdue.brightspace.com/"))

        // Act
        let url = QuizLink.url(courseId: 412_690, quizId: 619_243, baseURL: base)

        // Assert
        #expect(url.absoluteString == QuizTruth.honorPledgeURL)
    }

    @Test("distinct quizzes in one course get distinct URLs")
    func distinctQuizzesGetDistinctURLs() {
        // Arrange — the three Civics quizzes. If the builder ever hardcodes an id
        // or reads the wrong one, these collapse to a single URL and every row in
        // the submenu opens the same page.
        let urls = [QuizTruth.honorPledgeID, QuizTruth.practiceID, QuizTruth.welcomeID].map {
            QuizLink.url(courseId: QuizTruth.civicsID, quizId: $0, baseURL: QuizTruth.baseURL).absoluteString
        }

        // Assert
        #expect(Set(urls).count == 3)
    }
}
