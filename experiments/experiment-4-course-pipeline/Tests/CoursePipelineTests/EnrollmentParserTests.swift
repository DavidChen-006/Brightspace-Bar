import Foundation
import Testing
import CoursePipeline

// ─────────────────────────────────────────────────────────────────────────────
// Concern 1 — Parsing. RED tests; `EnrollmentParser` does not exist yet.
//
// TEST DESIGN
//
// Priorities (the two that carry ~80% of the value here):
//
//   1. ERROR-TAXONOMY INTEGRITY. This parser sits at a trust boundary, and its
//      failure modes are *destructive* rather than merely cosmetic. Downstream,
//      `CourseCache.apply` maps `.success([])` to `.updated` (rewrite the file)
//      but `.failure` to `.preservedStale` (keep what we had). So a parser that
//      answers "success, zero courses" to a dead session does not just show a
//      blank menu — it persists the blankness over the user's good cache. Every
//      edge case below exists to keep failures classified as failures.
//
//   2. FAITHFUL FIELD PRESERVATION. Whatever D2L sent must arrive intact,
//      including its nulls, without fabrication or silent dropping.
//
// Deliberately NOT tested: throughput (a 14 KB body), thread safety (a pure
// `Sendable` struct — the compiler already proves it), memory. Spreading into
// those would buy little and cost focus.
//
// Scope: all small. Pure function; the only I/O is reading a checked-in fixture.
//
// Expected values come from the real captured payload, audited independently
// with python3 before any test was written — never from what an implementation
// happens to produce.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Ground truth, audited from myenrollments-200.json

private enum Truth {
    /// The live tenant returned exactly this many enrollments.
    static let courseCount = 27

    /// First and last items in server order — used to pin order preservation.
    static let firstID = 412_690
    static let lastID = 1_498_777

    /// One of only TWO items whose `OrgUnit.HomeUrl` is non-null.
    static let civicsID = 412_690
    static let civicsName = "Purdue Civics Knowledge Test"
    static let civicsCode = "wl.nc.civics.test"
    static let civicsHomeUrl = "https://purdue.brightspace.com/d2l/home/412690"

    /// A real class: `HomeUrl` is NULL, and both dates are present.
    static let cgtID = 1_092_755
    static let cgtName = "Fall 2024 CGT 11800-013 LEC"
    static let cgtCode = "wl.202510.CGT.11800.013"
    static let cgtStart = "2024-08-14T04:00:00.000Z"
    static let cgtEnd = "2024-12-29T04:59:00.000Z"

    /// Asymmetric dates: StartDate null, EndDate present.
    static let starsID = 1_415_558
    static let starsEnd = "2026-01-12T18:01:00.000Z"

    /// Audited: only ids 412690 and 440703 carry a non-null HomeUrl. 25 are null.
    static let homeUrlPresentCount = 2
}

// MARK: - Helpers

private func isMalformedBody(_ error: CourseSourceError?) -> Bool {
    guard let error else { return false }
    if case .malformedBody = error { return true }
    return false
}

/// Wraps item JSON in the envelope D2L actually sends.
private func envelope(items: String) -> Data {
    Data(#"{"PagingInfo":{"Bookmark":"1","HasMoreItems":false},"Items":[\#(items)]}"#.utf8)
}

/// A minimal item carrying every field `Course` treats as required.
private let wellFormedItem = #"""
{"OrgUnit":{"Id":9001,"Type":{"Id":3,"Code":"Course Offering","Name":"Course Offering"},"Name":"Nine Thousand One","Code":"wl.test.9001","HomeUrl":null,"ImageUrl":null},"Access":{"IsActive":true,"StartDate":null,"EndDate":null,"CanAccess":true,"ClasslistRoleName":"Learner","LISRoles":[],"LastAccessed":null},"PinDate":null}
"""#

/// Same item with `OrgUnit.Name` removed — `Course.name` is non-optional, so this
/// item cannot be constructed.
private let itemMissingName = #"""
{"OrgUnit":{"Id":9002,"Type":{"Id":3,"Code":"Course Offering","Name":"Course Offering"},"Code":"wl.test.9002","HomeUrl":null,"ImageUrl":null},"Access":{"IsActive":true,"StartDate":null,"EndDate":null,"CanAccess":true,"ClasslistRoleName":"Learner","LISRoles":[],"LastAccessed":null},"PinDate":null}
"""#

@Suite("EnrollmentParser")
struct EnrollmentParserTests {

    // ─────────────────────────────────────────────────────────────────────
    // PRIORITY 1 — Error-taxonomy integrity.
    //
    // The two tests that matter most are `sessionExpiredStub…` and
    // `emptyItemsArray…`. Together they prove the parser DISTINGUISHES a dead
    // session from a genuinely course-free account. Collapsing those two inputs
    // into the same answer is the single most damaging bug available here, in
    // either direction:
    //   stub  → [] : wipes a good cache to blank, and persists it
    //   empty → throw : a legitimately empty account can never load
    // ─────────────────────────────────────────────────────────────────────

    @Test("the session-expired stub is reported as an expired session, not as data")
    func sessionExpiredStubThrowsSessionExpired() throws {
        // Arrange — the real 294-byte HTML the token mint serves at HTTP 200.
        let parser = EnrollmentParser()
        let stub = try Fixture.sessionExpiredStub

        // Act + Assert
        #expect(throws: CourseSourceError.sessionExpired) {
            try parser.parse(stub)
        }
    }

    @Test("an account with no enrollments parses to an empty list rather than failing")
    func emptyItemsArrayParsesToEmptyList() throws {
        // Arrange — a real user can legitimately have zero courses.
        let parser = EnrollmentParser()
        let body = Data(#"{"PagingInfo":{"Bookmark":"0","HasMoreItems":false},"Items":[]}"#.utf8)

        // Act
        let courses = try parser.parse(body)

        // Assert
        #expect(courses.isEmpty)
    }

    @Test("HTML that is not the session stub is malformed, not a session expiry")
    func unrelatedHTMLThrowsMalformedBody() throws {
        // Arrange — a proxy/gateway error page. The stub detector must be specific;
        // if it fires on "looks like HTML" it will mislabel every outage as an auth
        // problem and send the app into a pointless re-login loop.
        let parser = EnrollmentParser()
        let body = Data("<!DOCTYPE html><html><body><h1>502 Bad Gateway</h1></body></html>".utf8)

        // Act
        let error = #expect(throws: CourseSourceError.self) {
            try parser.parse(body)
        }

        // Assert
        #expect(isMalformedBody(error))
    }

    @Test("a truncated response body is malformed")
    func truncatedJSONThrowsMalformedBody() throws {
        // Arrange — a connection cut mid-transfer. Real, and must never decode
        // to a partial course list.
        let parser = EnrollmentParser()
        let full = try Fixture.enrollments
        let half = Data(full.prefix(full.count / 2))

        // Act
        let error = #expect(throws: CourseSourceError.self) {
            try parser.parse(half)
        }

        // Assert
        #expect(isMalformedBody(error))
    }

    @Test("valid JSON of the wrong shape is malformed")
    func wrongShapeJSONThrowsMalformedBody() throws {
        // Arrange
        let parser = EnrollmentParser()
        let body = Data(#"{"foo":1}"#.utf8)

        // Act
        let error = #expect(throws: CourseSourceError.self) {
            try parser.parse(body)
        }

        // Assert
        #expect(isMalformedBody(error))
    }

    @Test("an empty body is malformed")
    func emptyDataThrowsMalformedBody() throws {
        // Arrange — a 200 with no body at all.
        let parser = EnrollmentParser()

        // Act
        let error = #expect(throws: CourseSourceError.self) {
            try parser.parse(Data())
        }

        // Assert
        #expect(isMalformedBody(error))
    }

    @Test("a bare JSON array is malformed")
    func topLevelArrayThrowsMalformedBody() throws {
        // Arrange — a plausible API-shape confusion: items without the envelope.
        let parser = EnrollmentParser()
        let body = Data("[]".utf8)

        // Act
        let error = #expect(throws: CourseSourceError.self) {
            try parser.parse(body)
        }

        // Assert — must NOT be mistaken for "zero courses".
        #expect(isMalformedBody(error))
    }

    @Test("a JSON null body is malformed")
    func jsonNullThrowsMalformedBody() throws {
        // Arrange
        let parser = EnrollmentParser()
        let body = Data("null".utf8)

        // Act
        let error = #expect(throws: CourseSourceError.self) {
            try parser.parse(body)
        }

        // Assert
        #expect(isMalformedBody(error))
    }

    @Test("a non-empty Items array in which no item is usable is malformed")
    func allItemsUnusableThrowsMalformedBody() throws {
        // Arrange — THE BACKSTOP FOR THE SKIP POLICY (see the decision note in
        // `oneUnusableItemIsSkipped…`). Per-item skipping is only safe while it
        // cannot degenerate into the silent empty list Priority 1 forbids. D2L
        // said "here are 2 enrollments"; if we can decode none of them, that is a
        // shape mismatch to report, not an account with no courses.
        let parser = EnrollmentParser()
        let body = envelope(items: "\(itemMissingName),\(itemMissingName)")

        // Act
        let error = #expect(throws: CourseSourceError.self) {
            try parser.parse(body)
        }

        // Assert
        #expect(isMalformedBody(error))
    }

    // ─────────────────────────────────────────────────────────────────────
    // PRIORITY 1 — the judgement call the SPEC leaves open.
    //
    // DECISION: skip the unusable item; keep the rest. WITH the all-items-failed
    // backstop above.
    //
    // WHY, argued by blast radius rather than taste. Suppose D2L emits one
    // malformed item out of 27 — an org unit mid-deletion, a botched migration.
    //   • Fail the whole parse → `.malformedBody` → the cache returns
    //     `.preservedStale`, and on a cold start the user sees an EMPTY MENU.
    //     One broken course costs all 27.
    //   • Skip the item → the user sees 26 courses and can get to work.
    // A menu-bar app's job is to show what it can. Partial degradation beats
    // total failure, and the whole pipeline is already built on that principle
    // (that is precisely what `.preservedStale` exists for).
    //
    // The backstop is what makes skipping safe: it bounds the policy so that
    // "skip everything" is never silently reported as "nothing to show".
    // ─────────────────────────────────────────────────────────────────────

    @Test("one unusable item is skipped while the usable ones still parse")
    func oneUnusableItemIsSkippedNotFatal() throws {
        // Arrange — one good item, one missing the required `OrgUnit.Name`.
        let parser = EnrollmentParser()
        let body = envelope(items: "\(wellFormedItem),\(itemMissingName)")

        // Act
        let courses = try parser.parse(body)

        // Assert — the good one survives; the bad one is dropped, not fatal.
        #expect(courses.count == 1)
        #expect(courses.first?.id == 9001)
    }

    // ─────────────────────────────────────────────────────────────────────
    // PRIORITY 2 — Faithful field preservation.
    // ─────────────────────────────────────────────────────────────────────

    @Test("the real tenant payload parses to all 27 enrollments")
    func realFixtureParsesToTwentySevenCourses() throws {
        // Arrange
        let parser = EnrollmentParser()
        let body = try Fixture.enrollments

        // Act
        let courses = try parser.parse(body)

        // Assert — count audited independently from the captured payload.
        #expect(courses.count == Truth.courseCount)
    }

    @Test("a course carrying a HomeUrl is reproduced field for field")
    func courseWithHomeUrlIsReproducedExactly() throws {
        // Arrange
        let parser = EnrollmentParser()
        let body = try Fixture.enrollments

        // Act
        let courses = try parser.parse(body)
        let civics = try #require(courses.first { $0.id == Truth.civicsID })

        // Assert
        #expect(civics.name == Truth.civicsName)
        #expect(civics.code == Truth.civicsCode)
        #expect(civics.role == "Learner")
        #expect(civics.isActive)
        #expect(civics.homeUrl == Truth.civicsHomeUrl)
    }

    @Test("a real class is reproduced field for field, including its null HomeUrl")
    func realClassIsReproducedExactly() throws {
        // Arrange
        let parser = EnrollmentParser()
        let body = try Fixture.enrollments

        // Act
        let courses = try parser.parse(body)
        let cgt = try #require(courses.first { $0.id == Truth.cgtID })

        // Assert
        #expect(cgt.name == Truth.cgtName)
        #expect(cgt.code == Truth.cgtCode)
        #expect(cgt.homeUrl == nil)
        #expect(cgt.startDate == Truth.cgtStart)
        #expect(cgt.endDate == Truth.cgtEnd)
    }

    // ─────────────────────────────────────────────────────────────────────
    // ⚠️ SPEC CONTRADICTION — read before "fixing" the parser.
    //
    // SPEC Concern 1 asserts: "`homeUrl` is populated for every course (it
    // drives the click action)". Audited against the captured payload, that is
    // FALSE: `OrgUnit.HomeUrl` is null in 25 of 27 items. Only ids 412690 and
    // 440703 carry one, and BOTH are non-semester shell courses — every actual
    // class (`wl.202510.*`) has null.
    //
    // The two tests below pin reality. Do not make the parser synthesize a URL
    // to satisfy the SPEC sentence: deriving `{base}/d2l/home/{id}` is a real
    // and viable option (both non-null samples match that shape exactly, and
    // `ImageUrl` independently proves `Id` is the embeddable key), but it is a
    // POLICY choice that belongs to the UI/click layer, not to a parser whose
    // contract is faithful preservation. A parser that invents data destroys the
    // caller's ability to tell "D2L told us nothing" from "D2L told us this".
    // ─────────────────────────────────────────────────────────────────────

    @Test("HomeUrl is preserved only where D2L actually sent one")
    func homeUrlIsPresentOnlyForTheTwoCoursesThatHaveIt() throws {
        // Arrange
        let parser = EnrollmentParser()
        let body = try Fixture.enrollments

        // Act
        let courses = try parser.parse(body)

        // Assert — 2, not 27. Audited from the payload.
        #expect(courses.count(where: { $0.homeUrl != nil }) == Truth.homeUrlPresentCount)
    }

    @Test("a null HomeUrl stays null and is not synthesized from the course id")
    func nullHomeUrlIsNotSynthesized() throws {
        // Arrange
        let parser = EnrollmentParser()
        let body = try Fixture.enrollments

        // Act
        let courses = try parser.parse(body)
        let cgt = try #require(courses.first { $0.id == Truth.cgtID })

        // Assert — absence must remain visible to the caller.
        #expect(cgt.homeUrl == nil)
    }

    @Test("dates are carried through verbatim, including a null start with a real end")
    func asymmetricDatesArePreservedVerbatim() throws {
        // Arrange — `Course` stores raw ISO-8601 strings by contract, so no
        // reformatting, normalizing, or zero-filling is permitted.
        let parser = EnrollmentParser()
        let body = try Fixture.enrollments

        // Act
        let courses = try parser.parse(body)
        let stars = try #require(courses.first { $0.id == Truth.starsID })

        // Assert
        #expect(stars.startDate == nil)
        #expect(stars.endDate == Truth.starsEnd)
    }

    @Test("server ordering is preserved")
    func serverOrderIsPreserved() throws {
        // Arrange — menu order must be stable across refreshes, so the parser
        // must not sort, group, or reverse.
        let parser = EnrollmentParser()
        let body = try Fixture.enrollments

        // Act
        let courses = try parser.parse(body)

        // Assert
        #expect(courses.first?.id == Truth.firstID)
        #expect(courses.last?.id == Truth.lastID)
    }

    @Test("unrecognized fields are ignored so future D2L additions do not break parsing")
    func unknownFieldsAreIgnored() throws {
        // Arrange — D2L adds fields without warning. The real fixture already
        // carries five that `Course` does not model (Type, ImageUrl, PinDate,
        // CanAccess, LISRoles); this pins the behaviour against a field that does
        // not exist yet, which is the case that will actually arrive.
        let parser = EnrollmentParser()
        let futureItem = #"""
        {"OrgUnit":{"Id":9003,"Type":{"Id":3,"Code":"Course Offering","Name":"Course Offering"},"Name":"Future","Code":"wl.test.9003","HomeUrl":null,"ImageUrl":null,"SomeFieldInventedIn2027":{"nested":[1,2,3]}},"Access":{"IsActive":true,"StartDate":null,"EndDate":null,"CanAccess":true,"ClasslistRoleName":"Learner","LISRoles":[],"LastAccessed":null,"AnotherNewThing":true},"PinDate":null,"TopLevelNovelty":"x"}
        """#
        let body = envelope(items: futureItem)

        // Act
        let courses = try parser.parse(body)

        // Assert
        #expect(courses.count == 1)
        #expect(courses.first?.id == 9003)
        #expect(courses.first?.name == "Future")
    }
}
