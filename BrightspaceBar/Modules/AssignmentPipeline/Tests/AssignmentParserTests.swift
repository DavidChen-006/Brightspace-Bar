import Foundation
import Testing
import CoursePipeline
import AssignmentPipeline

// ═════════════════════════════════════════════════════════════════════════════
// AssignmentParser — the trust boundary.
//
// Supports BOTH priorities:
//
//   * PRIORITY 1 (click target): the parser supplies the two ids the deep link
//     is built from. `courseId` does NOT appear in the payload — it comes from
//     the caller — so a parser that leaves it unset breaks every link in the
//     course while every name still renders correctly. That is the quietest
//     possible version of the transposition bug.
//
//   * PRIORITY 2 (no silent data loss): the downstream store maps success to
//     "replace" and failure to "preserve", exactly as `CourseCache` does. So a
//     parser that answers "success, zero assignments" to an error body does not
//     merely show an empty submenu — it discards the assignments the user had.
//     Every edge case here exists to keep failures classified as failures.
//
// SCOPE: all small. Pure function; the only I/O is reading a checked-in fixture.
// ═════════════════════════════════════════════════════════════════════════════

private func isMalformedBody(_ error: any Error) -> Bool {
    guard let error = error as? CourseSourceError else { return false }
    if case .malformedBody = error { return true }
    return false
}

@Suite("AssignmentParser — faithful decoding of dropbox folders")
struct AssignmentParserTests {

    // ── The happy path, against the real capture ─────────────────────────────

    @Test("the real Scholarly Project payload yields its three assignments in order")
    func realPayloadYieldsThreeAssignments() throws {
        // Arrange — the genuine bytes for course 440703.
        let data = try Fixture.folders440703

        // Act
        let assignments = try AssignmentParser.parse(data, courseId: Truth.scholarlyID)

        // Assert — server order is preserved, because the submenu renders in
        // list order and a reshuffle between refreshes is user-visible.
        #expect(assignmentIDs(assignments) == [Truth.citiID, Truth.purcID, Truth.ideationID])
        #expect(assignments.map(\.name) == [Truth.citiName, Truth.purcName, Truth.ideationName])
    }

    @Test("every parsed assignment carries the course id it was fetched for")
    func courseIdIsStampedOnEveryAssignment() throws {
        // Arrange — `courseId` is NOT in the payload. It is the `ou` half of the
        // deep link, so an unstamped assignment renders a correct name pointing
        // at the wrong course (or at course 0).
        let data = try Fixture.folders440703

        // Act
        let assignments = try AssignmentParser.parse(data, courseId: Truth.scholarlyID)

        // Assert
        #expect(assignments.allSatisfy { $0.courseId == Truth.scholarlyID })
        #expect(!assignments.isEmpty, "a vacuous allSatisfy would pass on an empty list")
    }

    @Test("the real payload's assignments have no due date, and that is represented as nil")
    func realAssignmentsHaveNoDueDate() throws {
        // Arrange — measured: all four reachable assignments have `DueDate: null`.
        // This must arrive as nil, never as a sentinel or an epoch date, so the
        // GUI can omit the line entirely.
        let data = try Fixture.folders440703

        // Act
        let assignments = try AssignmentParser.parse(data, courseId: Truth.scholarlyID)

        // Assert
        #expect(assignments.allSatisfy { $0.dueDate == nil })
    }

    @Test("the single-assignment course parses to exactly one assignment")
    func civicsPayloadYieldsOneAssignment() throws {
        // Arrange
        let data = try Fixture.folders412690

        // Act
        let assignments = try AssignmentParser.parse(data, courseId: Truth.civicsID)

        // Assert
        #expect(assignmentIDs(assignments) == [Truth.untitledID])
        #expect(assignments.first?.name == Truth.untitledName)
    }

    // ── Due dates: unreachable today, required the moment a semester starts ──

    @Test("a due date with fractional seconds parses to the exact instant")
    func fractionalSecondsDueDateParses() throws {
        // Arrange — D2L's observed format, e.g. "2026-03-01T04:59:00.000Z". The
        // expected instant was computed independently with python3, not by
        // running this parser.
        let data = try Fixture.foldersWithDueDate

        // Act
        let assignments = try AssignmentParser.parse(data, courseId: 999)
        let homework = try #require(assignments.first { $0.id == 700_001 })

        // Assert
        #expect(homework.dueDate == Truth.homework3Due)
    }

    @Test("a due date without fractional seconds also parses")
    func wholeSecondDueDateParses() throws {
        // Arrange — "2026-09-15T23:59:00Z". This codebase has ALREADY been bitten
        // by a strict ISO-8601 parser that accepted only one of the two forms
        // (see MenuTranslation's date handling), so both are pinned here.
        let data = try Fixture.foldersWithDueDate

        // Act
        let assignments = try AssignmentParser.parse(data, courseId: 999)
        let project = try #require(assignments.first { $0.id == 700_002 })

        // Assert
        #expect(project.dueDate == Truth.groupProjectDue)
    }

    @Test("an unparseable due date yields nil rather than discarding the assignment")
    func brokenDueDateFailsOpen() throws {
        // Arrange — fail OPEN, deliberately. A nil due date costs one missing
        // line; throwing would cost the user every assignment in the course,
        // and the store would then preserve stale data forever behind a format
        // change. Non-destructive beats strict here.
        let data = try Fixture.foldersWithDueDate

        // Act
        let assignments = try AssignmentParser.parse(data, courseId: 999)
        let broken = try #require(assignments.first { $0.id == 700_003 })

        // Assert
        #expect(broken.dueDate == nil)
        #expect(broken.name == "Assignment With A Broken Date")
    }

    // ── Faithful preservation of the fields policy needs later ───────────────

    @Test("isHidden and groupTypeId are preserved rather than acted on")
    func policyFieldsArePreserved() throws {
        // Arrange — the parser's job is faithful preservation, matching the
        // `Course` precedent in CoursePipeline's Contracts.swift. Whether a
        // hidden assignment should be shown, and whether a group assignment
        // needs a real `grpid`, are POLICY decisions for the translation layer.
        // Deciding them here would bury them where no test can see them.
        let data = try Fixture.foldersWithDueDate

        // Act
        let assignments = try AssignmentParser.parse(data, courseId: 999)
        let visible = try #require(assignments.first { $0.id == 700_001 })
        let hiddenGroup = try #require(assignments.first { $0.id == 700_002 })

        // Assert
        #expect(visible.isHidden == false)
        #expect(visible.groupTypeId == nil)
        #expect(hiddenGroup.isHidden == true)
        #expect(hiddenGroup.groupTypeId == 4471)
    }

    @Test("a hidden assignment is still returned, not filtered out by the parser")
    func hiddenAssignmentsSurviveParsing() throws {
        // Arrange — the counterpart to the test above, stated as its own claim
        // because silently dropping rows is exactly the failure this module's
        // priorities forbid. If hiding is wanted, it belongs downstream.
        let data = try Fixture.foldersWithDueDate

        // Act
        let assignments = try AssignmentParser.parse(data, courseId: 999)

        // Assert
        #expect(assignments.count == 3, "all three folders must survive, hidden included")
    }

    // ── THE TRAP ─────────────────────────────────────────────────────────────

    @Test("no parsed value is ever taken from LinkAttachments")
    func linkAttachmentsAreNeverUsed() throws {
        // Arrange — `LinkAttachments[].Href` looks like a link to the assignment
        // and is NOT: it is an instructor-attached external resource. The MCP
        // server surfaces this field, which makes the mistake easy to inherit.
        // A parser that reads it would send the user to citiprogram.org.
        let data = try Fixture.foldersWithLinkAttachment

        // Act
        let assignments = try AssignmentParser.parse(data, courseId: Truth.scholarlyID)
        let citi = try #require(assignments.first)

        // Assert — no field on the parsed value may contain either external host.
        let rendered = String(describing: citi)
        #expect(!rendered.contains("citiprogram.org"))
        #expect(!rendered.contains("example.invalid"))

        // And the derived link is unaffected by their presence.
        let url = AssignmentLink.url(
            courseId: citi.courseId, assignmentId: citi.id, baseURL: Truth.baseURL
        )
        #expect(url.absoluteString == Truth.citiURL)
    }

    // ── Edge cases: the error taxonomy ───────────────────────────────────────

    @Test("a course with no assignments parses to an empty list rather than failing")
    func emptyArrayIsDataNotAnError() throws {
        // Arrange — a real course can legitimately have zero assignments, and
        // that fact must reach the store as a SUCCESS so the submenu can say
        // "No assignments" instead of showing yesterday's list forever.
        let data = try Fixture.foldersEmpty

        // Act
        let assignments = try AssignmentParser.parse(data, courseId: Truth.civicsID)

        // Assert
        #expect(assignments.isEmpty)
    }

    @Test("an error body served in place of an array is a typed failure, never zero assignments")
    func malformedBodyThrowsTyped() throws {
        // Arrange — the destructive case. If this returned `[]`, the store would
        // treat it as "this course now has no assignments" and replace good data.
        let data = try Fixture.foldersMalformed

        // Act / Assert
        var thrown: (any Error)?
        do {
            _ = try AssignmentParser.parse(data, courseId: Truth.civicsID)
        } catch {
            thrown = error
        }
        let error = try #require(thrown, "an error body must not parse successfully")
        #expect(isMalformedBody(error), "expected .malformedBody, got \(error)")
    }

    @Test("an item missing its name is a typed failure rather than a blank row")
    func itemMissingNameThrows() throws {
        // Arrange — `name` is the only thing the user reads. A blank menu row is
        // unclickable-looking and unexplained, so a payload that cannot supply
        // one is malformed, not empty.
        let data = Data(#"[{"Id":1,"IsHidden":false,"DueDate":null,"GroupTypeId":null}]"#.utf8)

        // Act / Assert
        var thrown: (any Error)?
        do {
            _ = try AssignmentParser.parse(data, courseId: 1)
        } catch {
            thrown = error
        }
        #expect(isMalformedBody(try #require(thrown)))
    }

    @Test("an item missing its id is a typed failure, because the link needs it")
    func itemMissingIdThrows() throws {
        // Arrange — without `Id` there is no `db=` value, so the row could exist
        // but could never be clicked. Better to fail the course's fetch loudly.
        let data = Data(#"[{"Name":"No id here","IsHidden":false}]"#.utf8)

        // Act / Assert
        var thrown: (any Error)?
        do {
            _ = try AssignmentParser.parse(data, courseId: 1)
        } catch {
            thrown = error
        }
        #expect(isMalformedBody(try #require(thrown)))
    }

    @Test("truncated JSON is a typed failure, not a crash")
    func truncatedBodyThrows() throws {
        // Arrange — a connection cut mid-body.
        let data = Data(#"[{"Id":445296,"Name":"Upload your CIT"#.utf8)

        // Act / Assert
        var thrown: (any Error)?
        do {
            _ = try AssignmentParser.parse(data, courseId: Truth.scholarlyID)
        } catch {
            thrown = error
        }
        #expect(isMalformedBody(try #require(thrown)))
    }

    @Test("the session-expired login stub is not mistaken for an empty course")
    func sessionExpiredStubIsAFailure() throws {
        // Arrange — the measured shape of a dead session: HTTP 200 carrying an
        // HTML stub. `CoursePipeline`'s parser has an explicit guard for this and
        // the assignment path is reachable with the same dead cookie, so it must
        // not decode to "zero assignments" either.
        let stub = Data(#"<html><head><script>window.location.replace("/d2l/login?sessionExpired=1");</script></head></html>"#.utf8)

        // Act / Assert
        var thrown: (any Error)?
        do {
            _ = try AssignmentParser.parse(stub, courseId: Truth.scholarlyID)
        } catch {
            thrown = error
        }
        #expect(thrown != nil, "an HTML stub must not parse to an empty assignment list")
    }
}
