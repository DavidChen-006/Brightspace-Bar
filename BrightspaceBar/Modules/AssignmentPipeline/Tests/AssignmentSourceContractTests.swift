import Foundation
import Testing
import BrightspaceSession
import CoursePipeline
import AssignmentPipeline

// ═════════════════════════════════════════════════════════════════════════════
// THE CONTRACT — written exactly once, run against both implementations.
//
// A fake that drifts from reality yields a green suite and a broken app. So every
// behavioural claim about `AssignmentSource` lives in one function, and both the
// scripted fake and the real network adapter are put through it.
//
// The live case matters more here than it did for courses, and it has a deadline.
// Experiment 6 proved that a course returns 403 on every content route the moment
// its `Access` window closes, so this data is CAPTURE-ONLY-WHILE-LIVE. The two
// reachable courses are administrative shells that run until graduation; if the
// tenant ever changes the dropbox payload shape, this live run is the only thing
// that will notice, and only while those two courses remain accessible.
//
// SCOPE: the hermetic case is small. The live case is large — network, real
// credentials, a real tenant — and is therefore gated so `swift test` stays
// offline by default.
// ═════════════════════════════════════════════════════════════════════════════

/// `true` only when the operator asks for a live run: `BS_LIVE=1 swift test`.
/// Read once at load so the gate cannot change mid-suite.
private let bsLiveEnabled = ProcessInfo.processInfo.environment["BS_LIVE"] != nil

/// One implementation under test, named so a failure says which one broke.
private struct SourceCase: Sendable, CustomStringConvertible {
    let name: String
    let make: @Sendable () async throws -> any AssignmentSource
    var description: String { self.name }

    /// The fake, scripted with the genuine captured payload so it is held to
    /// exactly the same standard as the real thing.
    static let fake = SourceCase(name: "FakeAssignmentSource") {
        FakeAssignmentSource([Truth.scholarlyID: [.bytes(try Fixture.folders440703)]])
    }

    /// The daemon source, reading a canned `cache/data.json` out of a temp
    /// `BSB_ROOT` — the file the daemon writes after a successful climb. Hermetic:
    /// no node, no network, no credentials, and no spawn at all, because an
    /// assignment fetch is a file read by design.
    /// (Added by the phase-3 test-writer; the assertions below are untouched.)
    static let daemon = SourceCase(name: "DaemonAssignmentSource") {
        let world = DaemonWorld()
        world.seedCache(data: DaemonJSON.cache, status: DaemonJSON.freshStatus)
        // The world owns the temp root and deletes it when the source goes away.
        return RootedAssignmentSource(world: world, inner: world.assignmentSource())
    }

    /// The real adapter over the standard session seam: `SESSION_JSON` when set,
    /// else `~/Library/Application Support/BrightspaceBar/session.json`. A missing
    /// or dead session fails the live run loudly — never silently green.
    static let live = SourceCase(name: "BrightspaceAssignmentSource") {
        BrightspaceAssignmentSource(provider: FileSessionProvider.standard)
    }
}

/// Every behavioural claim about an `AssignmentSource`, in one place.
private func assertAssignmentSourceContract(
    _ source: any AssignmentSource,
    courseId: Int
) async throws {
    let assignments = try await source.fetchAssignments(courseId: courseId)

    // The anti-drift canary: if the live tenant starts returning nothing while
    // the fake returns three, the drift surfaces here rather than as an empty
    // submenu in front of the user.
    #expect(!assignments.isEmpty, "a source backed by real data must yield assignments")

    for assignment in assignments {
        #expect(assignment.id > 0, "assignment \(assignment.id) has a non-positive id")
        #expect(!assignment.name.isEmpty, "assignment \(assignment.id) has an empty name")

        // The `ou` half of every deep link. A source that forgets to stamp this
        // produces correct-looking rows that open the wrong course.
        #expect(
            assignment.courseId == courseId,
            "assignment \(assignment.id) claims course \(assignment.courseId), asked for \(courseId)"
        )

        // The link must be derivable and well-formed for every assignment — this
        // is the property the entire feature rests on.
        let url = AssignmentLink.url(
            courseId: assignment.courseId, assignmentId: assignment.id, baseURL: Truth.baseURL
        )
        #expect(url.absoluteString.contains("db=\(assignment.id)"))
        #expect(url.absoluteString.contains("ou=\(courseId)"))
    }

    // Ids key the submenu rows; duplicates would collapse or duplicate entries.
    let uniqueIDs = Set(assignments.map(\.id))
    #expect(uniqueIDs.count == assignments.count, "assignment ids must be unique within a course")
}

@Suite("AssignmentSource — the contract every implementation must satisfy")
struct AssignmentSourceContractTests {

    /// Runs offline, always. Add further hermetic implementations here and they
    /// are held to the same contract automatically.
    private static let hermetic: [SourceCase] = [.fake, .daemon]

    @Test(
        "a hermetic source satisfies the contract",
        arguments: AssignmentSourceContractTests.hermetic
    )
    fileprivate func hermeticSourcesSatisfyTheContract(_ sourceCase: SourceCase) async throws {
        let source = try await sourceCase.make()
        try await assertAssignmentSourceContract(source, courseId: Truth.scholarlyID)
    }

    /// The anti-drift run. Skipped by default so `swift test` needs no network, no
    /// cookie, and no session file.
    @Test("the real Brightspace source satisfies the same contract", .enabled(if: bsLiveEnabled))
    func theLiveSourceSatisfiesTheContract() async throws {
        let source = try await SourceCase.live.make()
        try await assertAssignmentSourceContract(source, courseId: Truth.scholarlyID)
    }

    /// Pins the exact live payload against the fixture, so a fixture that silently
    /// stops matching reality is caught while these courses are still reachable.
    @Test("the live tenant still returns exactly the three captured assignments", .enabled(if: bsLiveEnabled))
    func liveDataStillMatchesTheFixture() async throws {
        // Arrange
        let source = BrightspaceAssignmentSource(provider: FileSessionProvider.standard)

        // Act
        let assignments = try await source.fetchAssignments(courseId: Truth.scholarlyID)

        // Assert — the same ids and names the fixture was built from.
        #expect(assignments.map(\.id) == [Truth.citiID, Truth.purcID, Truth.ideationID])
        #expect(assignments.map(\.name) == [Truth.citiName, Truth.purcName, Truth.ideationName])

        // And the measured fact that shapes the GUI: no assignment here has a
        // due date. When this starts failing, a real deadline has appeared and the
        // due-date rendering path is finally exercisable against live data.
        #expect(assignments.allSatisfy { $0.dueDate == nil })
    }

    /// Hermetic-only: a live tenant cannot be told to fail on cue. A failing source
    /// must surface a typed `CourseSourceError` so the store can fold it into
    /// `.preservedStale` rather than mistaking it for an empty course.
    @Test("a failing source throws a typed CourseSourceError")
    func failuresAreTyped() async throws {
        // Arrange
        let source = FakeAssignmentSource([Truth.scholarlyID: [.failure(.httpStatus(403))]])

        // Act / Assert
        await #expect(throws: CourseSourceError.httpStatus(403)) {
            _ = try await source.fetchAssignments(courseId: Truth.scholarlyID)
        }
    }
}
