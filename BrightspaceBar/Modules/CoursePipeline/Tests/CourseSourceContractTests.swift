import Foundation
import Testing
import CoursePipeline
import BrightspaceSession

/// `true` only when the operator asks for a live run: `BS_LIVE=1 swift test`.
/// Read once at load so the gate cannot change mid-suite.
private let bsLiveEnabled = ProcessInfo.processInfo.environment["BS_LIVE"] != nil

/// Signals that Concern 3.5 has not landed yet. Only reachable when `BS_LIVE` is set
/// before the real adapter exists — a deliberately loud failure rather than a silent skip,
/// because a live run that quietly tests nothing is worse than one that fails.
private enum ContractWiring: Error {
    case realSourceNotBuiltYet
}

/// One implementation under test, named so failures say which one broke.
private struct SourceCase: Sendable, CustomStringConvertible {
    let name: String
    let make: @Sendable () async throws -> any CourseSource
    var description: String { self.name }

    /// The fake, scripted with the genuine tenant payload so it is held to exactly the
    /// same standard as the real thing.
    static let fake = SourceCase(name: "FakeCourseSource") {
        FakeCourseSource([.bytes(try Fixture.enrollments)])
    }

    /// The real adapter, over the standard session seam: `SESSION_JSON` when set,
    /// else `~/Library/Application Support/BrightspaceBar/session.json`. A missing
    /// or dead session fails the live run loudly — never silently green.
    static let live = SourceCase(name: "BrightspaceCourseSource") {
        BrightspaceCourseSource(provider: FileSessionProvider.standard)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// THE CONTRACT — written exactly once.
//
// A fake that drifts from reality yields a green suite and a broken app. So every
// behavioural claim about `CourseSource` lives in this one function, and both the fake
// and the real adapter are run through it. If the real tenant ever stops satisfying
// something the fake satisfies, this fails instead of production.
// ─────────────────────────────────────────────────────────────────────────────

private func assertCourseSourceContract(_ source: any CourseSource) async throws {
    let courses = try await source.fetchCourses()

    // A source backed by a real enrollment payload yields real rows. This is the
    // anti-drift canary: if the live adapter returns an empty list while the fake
    // returns 27, the drift surfaces here rather than as an empty menu.
    #expect(!courses.isEmpty, "a source must yield at least one course")

    for course in courses {
        #expect(course.id > 0, "course \(course.id) has a non-positive id")
        #expect(!course.name.isEmpty, "course \(course.id) has an empty name")
        #expect(!course.code.isEmpty, "course \(course.id) has an empty code")

        // Deliberately NOT asserted: `homeUrl`. An earlier draft of the SPEC wrongly
        // claimed it was always populated; measured against the live tenant it is null
        // in 25 of 27 items, so it is not a contract invariant and never will be. The
        // click action derives its URL from `id` instead. Corrected by the orchestrator.
        //
        // If `homeUrl` is empty *when present*, that is still wrong — nil means "D2L
        // sent null", but "" means we mangled it.
        if let homeUrl = course.homeUrl {
            #expect(!homeUrl.isEmpty, "course \(course.id) has a present-but-empty homeUrl")
        }
    }

    // Ids key the menu rows; duplicates would collapse or duplicate entries.
    let uniqueIds = Set(courses.map(\.id))
    #expect(uniqueIds.count == courses.count, "course ids must be unique")
}

@Suite("CourseSource — the contract every implementation must satisfy")
struct CourseSourceContractTests {

    /// Runs offline, always. Add further hermetic implementations to this array and they
    /// are held to the same contract automatically.
    private static let hermetic: [SourceCase] = [.fake]

    @Test("a hermetic source satisfies the contract", arguments: CourseSourceContractTests.hermetic)
    fileprivate func hermeticSourcesSatisfyTheContract(_ sourceCase: SourceCase) async throws {
        let source = try await sourceCase.make()
        try await assertCourseSourceContract(source)
    }

    /// The anti-drift run. Skipped by default so `swift test` stays hermetic and needs no
    /// network, no cookie, and no `session.json`.
    @Test(
        "the real Brightspace source satisfies the same contract",
        .enabled(if: bsLiveEnabled)
    )
    func theLiveSourceSatisfiesTheContract() async throws {
        let source = try await SourceCase.live.make()
        try await assertCourseSourceContract(source)
    }

    /// Hermetic-only, because a live tenant cannot be told to fail on cue: a source that
    /// fails must surface a typed `CourseSourceError`, never an opaque error the cache
    /// cannot classify into a `CacheOutcome`.
    @Test("a failing source throws a typed CourseSourceError")
    func failuresAreTyped() async throws {
        let source = FakeCourseSource([.failure(.sessionExpired)])

        await #expect(throws: CourseSourceError.sessionExpired) {
            _ = try await source.fetchCourses()
        }
    }
}
