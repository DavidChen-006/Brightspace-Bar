import Foundation
import CoursePipeline
import AssignmentPipeline

// ─────────────────────────────────────────────────────────────────────────────
// Test support for the AssignmentPipeline spike.
//
// Mirrors `Modules/CoursePipeline/Tests/TestSupport.swift` deliberately: same
// `Fixture` shape (resolved via `#filePath`, never `Bundle.module`, so no
// `resources:` entry is needed) and the same hand-driven clock, so the two
// backend modules read the same way.
// ─────────────────────────────────────────────────────────────────────────────

/// A `Clock` you drive by hand. Nothing in the module may call `Date()`, and no
/// test may `sleep`.
public final class TestClock: CoursePipeline.Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    /// Fixed default epoch so failures are reproducible.
    public init(_ start: Date = Date(timeIntervalSince1970: 1_786_230_000)) {
        self.current = start
    }

    public var now: Date {
        self.lock.withLock { self.current }
    }

    public func advance(by seconds: TimeInterval) {
        self.lock.withLock { self.current += seconds }
    }
}

/// Loads the payloads in `Tests/Fixtures/`. See that directory's README for
/// which files are faithful captures and which are synthetic.
public enum Fixture {
    public static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures")
    }

    public static func data(_ name: String) throws -> Data {
        try Data(contentsOf: self.directory.appending(path: name))
    }

    /// The 3 genuine assignments in Scholarly Project Milestones (440703).
    public static var folders440703: Data { get throws { try self.data("dropbox-folders-440703.json") } }

    /// The 1 genuine assignment in Purdue Civics Knowledge Test (412690).
    public static var folders412690: Data { get throws { try self.data("dropbox-folders-412690.json") } }

    /// A course with no assignments at all — data, not an error.
    public static var foldersEmpty: Data { get throws { try self.data("dropbox-folders-empty.json") } }

    /// An error body served where an array was expected.
    public static var foldersMalformed: Data { get throws { try self.data("dropbox-folders-malformed.json") } }

    /// Synthetic. Real due dates do not exist in any reachable course, but the
    /// feature must work the day a semester course goes live.
    public static var foldersWithDueDate: Data { get throws { try self.data("dropbox-folders-with-due-date.json") } }

    /// Synthetic. Defends the `LinkAttachments` trap.
    public static var foldersWithLinkAttachment: Data {
        get throws { try self.data("dropbox-folders-with-link-attachment.json") }
    }
}

// MARK: - Ground truth, transcribed from experiment 7's live capture

/// Hand-transcribed from `experiments/experiment-7-assignment-deeplinks/artifacts/approach-a.json`
/// and its browser-verified deep links — never recomputed the way the code computes it.
public enum Truth {
    public static let baseURL = URL(string: "https://purdue.brightspace.com")!

    // Scholarly Project Milestones
    public static let scholarlyID = 440_703
    public static let citiID = 445_296
    public static let citiName = "Upload your CITI Certificate to Complete Module 2"
    public static let purcID = 445_297
    public static let purcName = "Report on your PURC Experience."
    public static let ideationID = 529_524
    public static let ideationName = "Getting Started on Scholarly Project Ideation"

    // Purdue Civics Knowledge Test
    public static let civicsID = 412_690
    public static let untitledID = 648_911
    public static let untitledName = "Untitled"

    /// The exact deep links experiment 7 navigated in a real browser, each of
    /// which rendered a page naming its own folder. Written out in full rather
    /// than interpolated, so a template change cannot silently rewrite the
    /// expectation along with the code.
    public static let citiURL =
        "https://purdue.brightspace.com/d2l/lms/dropbox/user/folder_submit_files.d2l?db=445296&grpid=0&ou=440703"
    public static let purcURL =
        "https://purdue.brightspace.com/d2l/lms/dropbox/user/folder_submit_files.d2l?db=445297&grpid=0&ou=440703"
    public static let ideationURL =
        "https://purdue.brightspace.com/d2l/lms/dropbox/user/folder_submit_files.d2l?db=529524&grpid=0&ou=440703"
    public static let untitledURL =
        "https://purdue.brightspace.com/d2l/lms/dropbox/user/folder_submit_files.d2l?db=648911&grpid=0&ou=412690"

    /// `2026-03-01T04:59:00.000Z` — the synthetic due date, computed
    /// independently with python3.
    public static let homework3Due = Date(timeIntervalSince1970: 1_772_341_140)
    /// `2026-09-15T23:59:00Z` — same instant, written WITHOUT fractional
    /// seconds, because D2L is not consistent about them and this codebase has
    /// already been bitten by a strict ISO-8601 parser once.
    public static let groupProjectDue = Date(timeIntervalSince1970: 1_789_516_740)
}

// MARK: - Doubles

/// A scriptable `AssignmentSource`.
///
/// Two things make it useful beyond canned data:
///
/// 1. **It can be scripted with raw bytes**, run through the real
///    `AssignmentParser` exactly as the network adapter does. That stops the
///    fake from drifting by skipping decoding.
/// 2. **It counts calls per course.** "Fan-out happened" is a claim about how
///    many times each course was fetched — never about elapsed time.
public actor FakeAssignmentSource: AssignmentSource {

    public enum Response: Sendable {
        /// Hand back these assignments directly.
        case assignments([Assignment])
        /// Hand back a raw payload; parsed with the real `AssignmentParser`.
        case bytes(Data)
        /// Throw this error.
        case failure(CourseSourceError)
    }

    /// Per-course script. A course with no entry gets `.assignments([])`.
    private var scripted: [Int: [Response]]
    private var lastServed: [Int: Response] = [:]
    private let yieldsPerFetch: Int

    public private(set) var callCounts: [Int: Int] = [:]
    /// High-water mark of simultaneously in-flight fetches across all courses.
    /// Fan-out is supposed to be parallel, so this should exceed 1 — the
    /// deterministic way to assert parallelism without measuring time.
    public private(set) var maxConcurrentFetches = 0
    private var inFlight = 0

    public init(_ scripted: [Int: [Response]] = [:], yieldsPerFetch: Int = 4) {
        self.scripted = scripted
        self.yieldsPerFetch = yieldsPerFetch
    }

    public func callCount(for courseId: Int) -> Int {
        self.callCounts[courseId] ?? 0
    }

    public var totalCallCount: Int {
        self.callCounts.values.reduce(0, +)
    }

    public func script(_ courseId: Int, _ response: Response) {
        self.scripted[courseId, default: []].append(response)
    }

    public func fetchAssignments(courseId: Int) async throws -> [Assignment] {
        self.callCounts[courseId, default: 0] += 1
        self.inFlight += 1
        self.maxConcurrentFetches = max(self.maxConcurrentFetches, self.inFlight)
        defer { self.inFlight -= 1 }

        // Real suspension points, so genuinely parallel fan-out overlaps here
        // while the test stays wall-clock free.
        for _ in 0 ..< self.yieldsPerFetch {
            await Task.yield()
        }
        self.maxConcurrentFetches = max(self.maxConcurrentFetches, self.inFlight)

        let response: Response
        if var queue = self.scripted[courseId], !queue.isEmpty {
            response = queue.removeFirst()
            self.scripted[courseId] = queue
        } else {
            response = self.lastServed[courseId] ?? .assignments([])
        }
        self.lastServed[courseId] = response

        switch response {
        case .assignments(let assignments):
            return assignments
        case .failure(let error):
            throw error
        case .bytes(let data):
            return try AssignmentParser.parse(data, courseId: courseId)
        }
    }
}

/// Builds a `Course` with only the fields the assignment pipeline reads.
/// Everything else is filler — the pipeline must not depend on it.
public func makeCourse(id: Int, name: String = "A Course") -> Course {
    Course(
        id: id,
        name: name,
        code: "wl.202610.TEST.\(id).LE1",
        role: "Learner",
        isActive: true
    )
}

/// A convenience for reading a state's list in assertions.
public func assignmentIDs(_ assignments: [Assignment]) -> [Int] {
    assignments.map(\.id)
}
