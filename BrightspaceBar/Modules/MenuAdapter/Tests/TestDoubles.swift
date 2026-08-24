import Foundation
import CourseMenu
import CoursePipeline

// ─────────────────────────────────────────────────────────────────────────────
// Local test doubles.
//
// Experiment 4's `TestClock`, `Fixture`, `TempDir`, and `FakeCourseSource` all
// live in ITS test target, and SPM test targets are separate modules that cannot
// import one another. These are the minimum replacements.
// ─────────────────────────────────────────────────────────────────────────────

/// A `Clock` driven by hand. Named differently from experiment 4's `TestClock`
/// only to keep the two unambiguous when reading failures across packages.
final class ManualClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    /// Fixed epoch so failures reproduce.
    init(_ start: Date = Date(timeIntervalSince1970: 1_786_230_000)) {
        self.current = start
    }

    var now: Date { self.lock.withLock { self.current } }

    func advance(by seconds: TimeInterval) {
        self.lock.withLock { self.current += seconds }
    }
}

/// Production clock sanity — the one place in the whole codebase allowed to call
/// `Date()`, so there is nowhere else to catch it returning nonsense.
struct SystemClockProbe {
    static let tolerance: TimeInterval = 5
}

/// A `CourseSource` you script, that counts calls.
///
/// Call counts are the whole point: "the menu opens instantly" and "polling
/// coalesces" are both claims about how many times the network was touched, never
/// about elapsed time. A timing assertion would be flaky and would not actually
/// test the property.
actor CountingSource: CourseSource {
    enum Step: Sendable {
        case courses([Course])
        case bytes(Data)
        case failure(CourseSourceError)
    }

    private var steps: [Step]
    private let repeatLast: Bool
    private(set) var calls = 0

    /// - Parameter repeatLast: when the script runs out, replay the final step
    ///   forever rather than trapping. Lets a test drive many ticks without
    ///   enumerating every one.
    init(_ steps: [Step], repeatLast: Bool = true) {
        self.steps = steps
        self.repeatLast = repeatLast
    }

    func fetchCourses() async throws -> [Course] {
        self.calls += 1

        let step: Step
        if self.steps.count > 1 {
            step = self.steps.removeFirst()
        } else if let only = self.steps.first {
            step = self.repeatLast ? only : self.steps.removeFirst()
        } else {
            throw CourseSourceError.transport("CountingSource script exhausted")
        }

        switch step {
        case .courses(let courses): return courses
        case .bytes(let data): return try EnrollmentParser().parse(data)
        case .failure(let error): throw error
        }
    }

    func callCount() -> Int { self.calls }
}

/// The real 27-course payload, reached across the module boundary.
///
/// It belongs to `CoursePipeline` and is not a resource of this test target, so
/// it is located by walking up from `#filePath` — the same technique that module's
/// own `Fixture` helper uses, and one that needs no `resources:` entry in
/// `Package.swift`.
enum CrossPackageFixture {
    /// `<package root>/Modules/CoursePipeline/Tests/Fixtures/`
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Modules/MenuAdapter/Tests
            .deletingLastPathComponent()   // Modules/MenuAdapter
            .deletingLastPathComponent()   // Modules
            .appending(path: "CoursePipeline")
            .appending(path: "Tests")
            .appending(path: "Fixtures")
            .standardizedFileURL
    }

    /// The genuine 14,938-byte success body, 27 courses.
    static var enrollmentBytes: Data {
        get throws { try Data(contentsOf: self.directory.appending(path: "myenrollments-200.json")) }
    }

    /// Parsed with the REAL parser, so the end-to-end chain is genuinely
    /// bytes → parser → translation and not hand-built data wearing a costume.
    static var realCourses: [Course] {
        get throws { try EnrollmentParser().parse(self.enrollmentBytes) }
    }
}

/// Self-deleting scratch directory, so cache-backed tests never share state.
final class ScratchDir {
    let url: URL

    init() throws {
        self.url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "menuadapter-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: self.url, withIntermediateDirectories: true)
    }

    func file(_ name: String = "courses.json") -> URL {
        self.url.appending(path: name)
    }

    deinit {
        try? FileManager.default.removeItem(at: self.url)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Ground truth from the real fixture, transcribed by hand.
//
// Written out as literals rather than computed from the payload: an expected
// value derived the same way the code derives it cannot catch the code being
// wrong. These came from reading the JSON directly.
// ─────────────────────────────────────────────────────────────────────────────

enum RealData {
    static let baseURL = URL(string: "https://purdue.brightspace.com")!

    static let totalCourses = 27

    /// Term codes present, newest first. Four courses carry no term at all.
    static let termsDescending = ["202620", "202610", "202530", "202520", "202510"]

    static let countsByTerm: [String: Int] = [
        "202620": 5,
        "202610": 6,
        "202530": 1,
        "202520": 6,
        "202510": 5,
    ]

    /// Codes carrying no term component in the FULL payload — a payload fact,
    /// not a visibility claim: since 2026-08-24 the two fully undated shells
    /// among these are hidden, so at most the dated untermed ones can render.
    static let untermedCount = 4

    /// The only two items whose `OrgUnit.HomeUrl` is non-null. Both are
    /// non-semester shells. Their presence must not make URL derivation
    /// inconsistent with the other 25.
    static let idsWithHomeUrl = [412_690, 440_703]

    /// A spread of real (id, raw code, exact name) triples for spot checks.
    /// Deliberately spans first, last, mid-list, and both untermed shapes.
    static let firstID = 412_690
    static let lastID = 1_498_777

    static let dataStructuresID = 1_360_027
    static let dataStructuresCode = "wl.202610.CS.25100.LE1"
    static let dataStructuresName = "Fall 2025 CS 25100-LEC - Merge"
    static let dataStructuresShortCode = "CS 25100"

    static let compilersID = 1_488_325
    static let compilersCode = "wl.202620.CS.25200.LE1"
    static let compilersName = "Spring 2026 CS 25200-LE1 LEC"
    static let compilersShortCode = "CS 25200"

    static let starsID = 1_415_558
    static let starsCode = "stars_2025"
    static let starsName = "STARS 2025"

    static let civicsID = 412_690
    static let civicsCode = "wl.nc.civics.test"
    static let civicsName = "Purdue Civics Knowledge Test"

    // ── Currentness policy truth (user decision 2026-08-24, superseding
    //    2026-08-09) ─────────────────────────────────────────────────────────
    //
    // The menu now filters to CURRENT ONLY. At a probe instant of
    // 2025-10-01T00:00:00Z (mid Fall 2025), the JSON says: six termed Fall 2025
    // courses are inside their Access window, and STARS 2025 has a nil start and
    // an end of 2026-01-12 — current, and its untermed code still files it under
    // "Other". The two fully undated shells (Civics 412690, Scholarly Project
    // 440703) are HIDDEN everywhere: real classes exist, so "Other" earns no
    // menu space and no network calls for them.

    /// 2025-10-01T00:00:00Z — mid Fall 2025 semester.
    static let midFall2025 = Date(timeIntervalSince1970: 1_759_276_800)

    /// Every id visible at that instant, transcribed from the JSON by hand.
    static let visibleIDsAtMidFall2025: Set<Int> = [
        1_360_020,  // Fall 2025 CS 25000 - Merge
        1_360_027,  // Fall 2025 CS 25100-LEC - Merge
        1_360_055,  // Fall 2025 CS 25100-P06 PSO
        1_361_997,  // Fall 2025 ECON 57600-004 LEC
        1_372_751,  // Fall 2025 STAT 35000-018 DIS
        1_413_404,  // Fall 2025 PHIL 30400-001 LEC
        1_415_558,  // STARS 2025 — nil start, ends 2026-01-12: CURRENT, untermed
    ]

    /// "Other" survives only because STARS 2025 is current-but-untermed — the
    /// nil-bucket machinery still renders, undated courses just never reach it.
    static let headersAtMidFall2025 = ["202610", "Other"]
    static let countsAtMidFall2025: [String: Int] = ["202610": 6, "Other": 1]
}
