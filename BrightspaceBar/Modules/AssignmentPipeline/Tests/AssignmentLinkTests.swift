import Foundation
import Testing
import AssignmentPipeline

// ═════════════════════════════════════════════════════════════════════════════
// PRIORITY 1 — CLICK-TARGET CORRECTNESS.
//
// This is the highest-value suite in the module, and the reason is asymmetry:
// a menu that shows no assignments is a missing feature, but a menu that sends
// you to the WRONG assignment is worse than no feature. It fails silently —
// the page loads, it is a real Brightspace page, and nothing announces that it
// is somebody else's submission folder.
//
// The specific catastrophic bug available here is a `db`/`ou` TRANSPOSITION.
// Both are Ints, both are plausible in either position, and a swap produces a
// perfectly well-formed URL. The compiler cannot catch it and a smoke test
// cannot see it. `argumentTranspositionProducesADifferentURL` exists solely to
// catch it, and the four literal expectations below back it up.
//
// Expected values are the exact URLs experiment 7 NAVIGATED IN A REAL BROWSER,
// each of which rendered a page naming its own folder. They are written out in
// full rather than interpolated, so that editing the template cannot silently
// rewrite the expectation alongside the code.
//
// SCOPE: all small. Pure function, no I/O.
// ═════════════════════════════════════════════════════════════════════════════

/// One browser-verified (course, assignment) → URL triple.
private struct LinkCase: Sendable, CustomStringConvertible {
    let label: String
    let courseId: Int
    let assignmentId: Int
    let expected: String
    var description: String { self.label }

    static let all: [LinkCase] = [
        LinkCase(
            label: "CITI Certificate",
            courseId: Truth.scholarlyID, assignmentId: Truth.citiID, expected: Truth.citiURL
        ),
        LinkCase(
            label: "PURC Experience",
            courseId: Truth.scholarlyID, assignmentId: Truth.purcID, expected: Truth.purcURL
        ),
        LinkCase(
            label: "Scholarly Project Ideation",
            courseId: Truth.scholarlyID, assignmentId: Truth.ideationID, expected: Truth.ideationURL
        ),
        LinkCase(
            label: "Untitled (Civics)",
            courseId: Truth.civicsID, assignmentId: Truth.untitledID, expected: Truth.untitledURL
        ),
    ]
}

@Suite("AssignmentLink — the deep link proven in a browser")
struct AssignmentLinkTests {

    @Test(
        "each real assignment gets exactly the URL experiment 7 verified",
        arguments: LinkCase.all
    )
    fileprivate func realAssignmentsGetTheirVerifiedURL(_ testCase: LinkCase) {
        // Arrange / Act
        let url = AssignmentLink.url(
            courseId: testCase.courseId,
            assignmentId: testCase.assignmentId,
            baseURL: Truth.baseURL
        )

        // Assert — the whole string, so query-parameter ORDER is pinned too.
        // Experiment 7 harvested `db`, then `grpid`, then `ou` from Brightspace's
        // own markup; matching it exactly is the cheapest insurance against a
        // future D2L change that turns out to be order-sensitive.
        #expect(url.absoluteString == testCase.expected)
    }

    @Test("swapping the two ids produces a different URL")
    func argumentTranspositionProducesADifferentURL() {
        // Arrange — the transposition bug this suite exists for. Both arguments
        // are Ints, so `url(courseId: assignment, assignmentId: course)` compiles
        // and yields a valid URL that quietly goes somewhere wrong.
        let correct = AssignmentLink.url(
            courseId: Truth.scholarlyID, assignmentId: Truth.citiID, baseURL: Truth.baseURL
        )

        // Act
        let swapped = AssignmentLink.url(
            courseId: Truth.citiID, assignmentId: Truth.scholarlyID, baseURL: Truth.baseURL
        )

        // Assert
        #expect(correct != swapped)
    }

    @Test("the course id lands in ou and the assignment id lands in db, never the reverse")
    func idsLandInTheirOwnParameters() throws {
        // Arrange — asserted separately from the full-string test so a failure
        // says WHICH id went to the wrong place rather than just "string differs".
        // The ids are deliberately non-adjacent and different lengths.
        let url = AssignmentLink.url(
            courseId: Truth.civicsID, assignmentId: Truth.untitledID, baseURL: Truth.baseURL
        )

        // Act
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let byName = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value) })

        // Assert
        #expect(byName["db"] == String(Truth.untitledID), "db must carry the ASSIGNMENT id")
        #expect(byName["ou"] == String(Truth.civicsID), "ou must carry the COURSE id")
    }

    @Test("grpid is present and zero, matching the verified template")
    func grpidIsZero() throws {
        // Arrange — experiment 7 verified the template with `grpid=0`, and that
        // is a KNOWN LIMITATION rather than a proven universal: neither reachable
        // course has a group assignment (`GroupTypeId` is null on all four), so
        // the value is unverified for group-based folders. Pinning it here means
        // the day someone changes it, they are forced to acknowledge that gap.
        let url = AssignmentLink.url(
            courseId: Truth.scholarlyID, assignmentId: Truth.citiID, baseURL: Truth.baseURL
        )

        // Act
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)

        // Assert
        #expect(query.first { $0.name == "grpid" }?.value == "0")
    }

    @Test("a baseURL with a trailing slash does not produce a doubled slash")
    func trailingSlashInBaseURLIsHandled() throws {
        // Arrange — a caller passing "https://host/" is entirely plausible, and
        // "...com//d2l/lms/..." is a different URL that may not resolve. The
        // course-link code already handles this; assignments must match.
        let base = try #require(URL(string: "https://purdue.brightspace.com/"))

        // Act
        let url = AssignmentLink.url(
            courseId: Truth.scholarlyID, assignmentId: Truth.citiID, baseURL: base
        )

        // Assert
        #expect(url.absoluteString == Truth.citiURL)
        #expect(!url.absoluteString.contains("com//"))
    }

    @Test("the link is built from ids alone, so it never depends on payload fields")
    func linkNeedsNothingButIDs() {
        // Arrange — the design claim behind the whole feature: the click target is
        // DERIVED, so it exists even for an assignment whose payload carried no
        // link-shaped field at all (which is every real one). If this function
        // ever needed an `Assignment`, the derivation would be coupled to whatever
        // D2L happened to send and `LinkAttachments` would become tempting again.
        //
        // Act — two arbitrary ids, no model object anywhere.
        let url = AssignmentLink.url(courseId: 1, assignmentId: 2, baseURL: Truth.baseURL)

        // Assert
        #expect(url.absoluteString.hasSuffix("folder_submit_files.d2l?db=2&grpid=0&ou=1"))
    }
}
