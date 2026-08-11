import Foundation
import Testing
import AssignmentPipeline
import CoursePipeline
import QuizPipeline

// ═════════════════════════════════════════════════════════════════════════════
// QuizParser — D2L's `quizzes/` payload becomes `[Assignment]` with `kind: .quiz`.
//
// PRIORITY 2 (no silent data loss) is what shapes this file, and the reason is
// downstream: `AssignmentStore` maps success to REPLACE and failure to PRESERVE.
// So "success, zero quizzes" is not a cosmetic answer to a bad body — it
// **discards the quizzes the user had**. Every classification below exists to keep
// failures classified as failures.
//
// The sharpest instance is structural rather than hypothetical: quizzes arrive in
// an `{"Objects": [...]}` envelope while assignments arrive as a BARE ARRAY. A
// decoder that reached for the assignment shape — the obvious copy-paste — would
// decode zero and report success. `theAssignmentShapeIsNotSilentlyAccepted` is the
// test that catches exactly that.
//
// SCOPE: small. Bytes plus a course id in, values or a typed error out.
// ═════════════════════════════════════════════════════════════════════════════

@Suite("QuizParser — the Objects envelope")
struct QuizParserEnvelopeTests {

    @Test("the three real Civics quizzes decode with their exact ids and names")
    func realCivicsQuizzesDecode() throws {
        // Arrange — the faithful capture.
        let bytes = try QuizFixture.civics

        // Act
        let quizzes = try QuizParser.parse(bytes, courseId: QuizTruth.civicsID)

        // Assert — ids and names transcribed from the probe, not recomputed.
        #expect(quizzes.map(\.id) == [
            QuizTruth.honorPledgeID, QuizTruth.practiceID, QuizTruth.welcomeID,
        ])
        #expect(quizzes.map(\.name) == [
            QuizTruth.honorPledgeName, QuizTruth.practiceName, QuizTruth.welcomeName,
        ])
    }

    @Test("the one real Scholarly Project quiz decodes")
    func realScholarlyQuizDecodes() throws {
        // Arrange / Act
        let quizzes = try QuizParser.parse(try QuizFixture.scholarly, courseId: QuizTruth.scholarlyID)

        // Assert
        #expect(quizzes.count == 1)
        #expect(quizzes.first?.id == QuizTruth.moduleOneID)
        #expect(quizzes.first?.name == QuizTruth.moduleOneName)
    }

    @Test("every parsed quiz carries kind .quiz")
    func parsedQuizzesCarryTheQuizKind() throws {
        // Arrange / Act — the kind is what lets one list hold both entities and
        // what the submenu groups its sections by. An unstamped quiz would render
        // among the assignments and open through the wrong link template.
        let quizzes = try QuizParser.parse(try QuizFixture.civics, courseId: QuizTruth.civicsID)

        // Assert
        #expect(quizzes.allSatisfy { $0.kind == .quiz })
    }

    @Test("the course id is stamped from the request, since the payload omits it")
    func courseIdIsStampedFromTheRequest() throws {
        // Arrange / Act — D2L returns a course's quizzes without naming the course.
        // An unstamped quiz renders a correct name pointing at course 0.
        let quizzes = try QuizParser.parse(try QuizFixture.civics, courseId: QuizTruth.civicsID)

        // Assert
        #expect(quizzes.allSatisfy { $0.courseId == QuizTruth.civicsID })
    }

    @Test("an empty Objects array is data, not an error")
    func emptyEnvelopeYieldsNoQuizzes() throws {
        // Arrange / Act — a course genuinely without quizzes. Throwing here would
        // make the store preserve stale data forever for such a course.
        let quizzes = try QuizParser.parse(try QuizFixture.empty, courseId: QuizTruth.civicsID)

        // Assert
        #expect(quizzes.isEmpty)
    }

    @Test("the assignment shape — a bare array — is rejected, not silently read as zero")
    func theAssignmentShapeIsNotSilentlyAccepted() async throws {
        // Arrange — the exact body `dropbox/folders` returns. If a copy-pasted
        // decoder expects this shape, the REAL envelope decodes to zero and the
        // store wipes the user's quizzes on a successful fetch. This test makes the
        // envelope difference load-bearing instead of incidental.
        let bytes = try QuizFixture.bareArray

        // Act / Assert — a typed failure, so the store preserves.
        #expect(throws: CourseSourceError.self) {
            _ = try QuizParser.parse(bytes, courseId: QuizTruth.civicsID)
        }
    }

    @Test("an error body is malformed, never zero quizzes")
    func errorBodyIsMalformed() throws {
        // Arrange
        let bytes = try QuizFixture.malformed

        // Act
        var thrown: CourseSourceError?
        do {
            _ = try QuizParser.parse(bytes, courseId: QuizTruth.civicsID)
        } catch let error as CourseSourceError {
            thrown = error
        }

        // Assert — classified as malformed specifically, so the taxonomy the store
        // folds on stays meaningful.
        guard case .malformedBody = try #require(thrown) else {
            Issue.record("expected .malformedBody, got \(String(describing: thrown))")
            return
        }
    }

    @Test("the HTTP-200 login stub is classified as an expired session")
    func loginStubIsSessionExpired() throws {
        // Arrange — a dead cookie reaching this route answers 200 with an HTML stub
        // redirecting to `/d2l/login?sessionExpired=1`. Reported as `.malformedBody`
        // it would send the user hunting a parsing bug instead of re-authenticating.
        let bytes = try QuizFixture.sessionExpiredStub

        // Act / Assert
        #expect(throws: CourseSourceError.sessionExpired) {
            _ = try QuizParser.parse(bytes, courseId: QuizTruth.civicsID)
        }
    }
}

@Suite("QuizParser — fields")
struct QuizParserFieldTests {

    @Test("every real quiz has no due date, which is nil rather than a sentinel")
    func realQuizzesHaveNoDueDate() throws {
        // Arrange / Act — the normal case for this tenant: all four reachable
        // quizzes have `DueDate: null`. An epoch date here would render as a
        // deadline that does not exist.
        let quizzes = try QuizParser.parse(try QuizFixture.civics, courseId: QuizTruth.civicsID)

        // Assert
        #expect(quizzes.allSatisfy { $0.dueDate == nil })
    }

    @Test("a due date with fractional seconds parses to the exact instant")
    func fractionalSecondsDueDateParses() throws {
        // Arrange / Act — `2026-03-01T04:59:00.000Z`, the shape D2L usually sends.
        let quizzes = try QuizParser.parse(try QuizFixture.withDueDate, courseId: 999)
        let midterm = try #require(quizzes.first { $0.id == 900_101 })

        // Assert — the expected instant was computed with python3, independently.
        #expect(midterm.dueDate == QuizTruth.midtermDue)
    }

    @Test("a due date without fractional seconds also parses")
    func plainSecondsDueDateParses() throws {
        // Arrange / Act — `2026-09-15T23:59:00Z`. D2L is not consistent about
        // fractional seconds and `ISO8601FormatStyle` is strict about them; this
        // codebase has already been bitten by a parser that accepted only one form.
        let quizzes = try QuizParser.parse(try QuizFixture.withDueDate, courseId: 999)
        let final = try #require(quizzes.first { $0.id == 900_102 })

        // Assert
        #expect(final.dueDate == QuizTruth.finalDue)
    }

    @Test("an unparseable due date keeps the quiz, with no date")
    func unparseableDueDateFailsOpen() throws {
        // Arrange / Act — fail OPEN here, deliberately asymmetric with the fatal
        // id/name cases below: a bad date costs one line, whereas throwing would
        // cost every quiz in the course and freeze the menu behind a format change.
        let quizzes = try QuizParser.parse(try QuizFixture.withDueDate, courseId: 999)
        let broken = try #require(quizzes.first { $0.id == 900_103 })

        // Assert
        #expect(broken.dueDate == nil)
        #expect(broken.name == "Quiz With A Broken Date")
    }

    @Test("a quiz with no Name fails the course, rather than rendering blank")
    func missingNameIsFatal() throws {
        // Arrange — fail CLOSED: a nameless row is an unreadable menu entry, so the
        // honest answer is to fail the fetch and let the store preserve good data.
        let bytes = try QuizFixture.missingName

        // Act / Assert
        #expect(throws: CourseSourceError.self) {
            _ = try QuizParser.parse(bytes, courseId: QuizTruth.civicsID)
        }
    }

    @Test("a quiz with no QuizId fails the course, rather than being unclickable")
    func missingIdIsFatal() throws {
        // Arrange — without an id the deep link cannot be built at all, so the row
        // could never be clicked.
        let bytes = try QuizFixture.missingID

        // Act / Assert
        #expect(throws: CourseSourceError.self) {
            _ = try QuizParser.parse(bytes, courseId: QuizTruth.civicsID)
        }
    }

    @Test("IsActive false marks a quiz hidden, reusing the assignment visibility policy")
    func inactiveQuizzesAreMarkedHidden() throws {
        // Arrange — `IsActive: false` is D2L's own "not available to students". It
        // is the quiz analogue of a dropbox folder's `IsHidden`, so mapping it onto
        // the SAME field means one visibility policy covers both kinds and the
        // translation layer needs no per-kind branch.
        //
        // The parser marks; it does not filter. Whether a hidden item renders is a
        // display decision, and burying it here would put it where no test looks.
        let quizzes = try QuizParser.parse(try QuizFixture.inactive, courseId: 999)

        // Act
        let unreleased = try #require(quizzes.first { $0.id == 910_201 })
        let released = try #require(quizzes.first { $0.id == 910_202 })

        // Assert — both still parsed. Only the flag differs.
        #expect(quizzes.count == 2)
        #expect(unreleased.isHidden)
        #expect(!released.isHidden)
    }

    @Test("the 33 unverified fields are ignored entirely")
    func unverifiedFieldsAreIgnored() throws {
        // Arrange — only QuizId, Name, DueDate and IsActive were captured WITH
        // values. `AttemptsAllowed`, `SubmissionTimeLimit`, `Description` and the
        // rest are plausible shapes, not measured ones, and the real payload has 37
        // keys. A parser that modelled any of them would be depending on data
        // nobody has verified — and `brightspace-mcp-server`'s interface, which
        // declares a `TimeLimit` field that does not exist, shows how that goes.
        //
        // Act — the same envelope with every unverified field replaced by a value
        // of a DIFFERENT type. If the parser reads any of them it fails to decode.
        let hostile = Data("""
        {"Objects":[{
          "QuizId": 619243, "Name": "Honor Pledge", "IsActive": true, "DueDate": null,
          "AttemptsAllowed": "not-an-object",
          "SubmissionTimeLimit": 42,
          "Description": ["unexpected", "array"],
          "Header": true, "Footer": 0, "Instructions": [],
          "LateSubmissionInfo": "nope", "ActivityId": 12345,
          "Shuffle": "yes", "SortOrder": "first", "CalcTypeId": null
        }], "Next": null}
        """.utf8)
        let quizzes = try QuizParser.parse(hostile, courseId: QuizTruth.civicsID)

        // Assert — the four load-bearing fields survive; nothing else was consulted.
        #expect(quizzes.count == 1)
        #expect(quizzes.first?.id == QuizTruth.honorPledgeID)
        #expect(quizzes.first?.name == QuizTruth.honorPledgeName)
    }

    @Test("a quiz never carries a groupTypeId")
    func quizzesHaveNoGroupType() throws {
        // Arrange / Act — `groupTypeId` exists on the shared item type for
        // assignments' sake and drives the unverified `grpid=0` in their link.
        // Quizzes have no group concept and their link has no group parameter, so
        // leaving this nil keeps the two templates from bleeding into each other.
        let quizzes = try QuizParser.parse(try QuizFixture.civics, courseId: QuizTruth.civicsID)

        // Assert
        #expect(quizzes.allSatisfy { $0.groupTypeId == nil })
    }
}
