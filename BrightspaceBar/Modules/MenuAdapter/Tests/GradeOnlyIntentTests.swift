import Foundation
import Testing

import AssignmentPipeline
import CourseMenu
import CoursePipeline
import MenuAdapter

// ═════════════════════════════════════════════════════════════════════════════
// THE INTENT TEST — a hidden exam's grade column crosses the language seam.
//
// One story, told once, through the real components on both sides: a course's
// gradebook holds a student-scored column "Exam 1" linked to a quiz the
// `quizzes/` route does not return; the Node daemon diffs it against what it
// fetched and writes it into `data.json` as a `gradeOnly` item; the Swift app
// decodes that file, renders it under "Heads up", and draws it no square.
//
// PRIORITIES (the two carrying the value; everything else is culled):
//
//   1. THE TWO HALVES AGREE ON THE WIRE. `kind: "gradeOnly"`, `dueDate: null`
//      and the gradebook URL template are each written out twice — once in
//      `fetch-engine.mjs`, once in `DaemonAssignmentSource`/`GradebookLink` —
//      and NOTHING checks one against the other. Both unit suites stay green
//      through every drift: rename the wire string on the Node side and Swift
//      rejects the whole course; change one URL template and the row opens a
//      real Brightspace page that is the wrong one. Only a test that runs the
//      real writer and the real reader over one payload can see the gap.
//
//   2. THE ROW SURVIVES THE WHOLE PIPE, AND THE NOISE DOES NOT. Four gradebook
//      columns go in and exactly one row comes out the far end, titled,
//      subtitled and clickable. Each half proves that about ITSELF already; the
//      claim here is that the halves are actually connected — that the daemon's
//      surviving column and the row Swift renders are the same thing.
//
// CULLED, because the unit suites own them: the membership rule column by
// column (`gradebook-diff.test.mjs`), failure isolation when `grades/` dies
// (same), the near-miss wire strings (`GradeOnlyDecodeTests`), section ordering
// and the labelling rule across every shape (`GradeOnlySectionTests`), and the
// hostile DATED gradeOnly item the heatmap must still refuse
// (`GraphGradeOnlyTests`). This file re-proves none of it. Its subject is the
// wiring, and it is deliberately ONE test: a second one would mean a second
// process spawn to make the same point.
//
// SCOPE: large — two processes, two languages, a real temp `BSB_ROOT` on a real
// filesystem. Large tests are few and expensive by design, and this is the only
// claim nothing smaller can make.
//
// STUB MODE, and therefore UNGATED. Unlike the `BS_LIVE` cases in this package,
// the child here reaches no network and holds no credential: the driver fakes
// the HTTP seam and refuses to run without a `BSB_ROOT`. It costs one `node`
// spawn on the default `swift test`, which is the price of the only test that
// can catch the two halves drifting apart.
// ═════════════════════════════════════════════════════════════════════════════

/// The node half. Spawned exactly as `main.swift` spawns the daemon —
/// `/usr/bin/env node <path>`, `BSB_ROOT` in the environment, nothing on argv —
/// so the two sides meet at the same interface the app uses.
private enum Driver {

    /// `<repo root>/session-capture/tests/intent/build4-driver.mjs`, walked up
    /// from `#filePath` the way `CrossPackageFixture` walks to its fixtures. No
    /// `resources:` entry, and no dependence on where the checkout lives.
    static var url: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Modules/MenuAdapter/Tests
            .deletingLastPathComponent()   // Modules/MenuAdapter
            .deletingLastPathComponent()   // Modules
            .deletingLastPathComponent()   // BrightspaceBar
            .deletingLastPathComponent()   // <repo root>
            .appending(path: "session-capture")
            .appending(path: "tests")
            .appending(path: "intent")
            .appending(path: "build4-driver.mjs")
            .standardizedFileURL
    }
}

/// Every expected value, read off the contract in LADDER-PLAN and off the
/// driver's designed world — never recomputed the way either side computes it.
private enum Expected {

    static let courseID = 412_690

    /// The tenant the driver's fake session claims to be. Handed to the Swift
    /// translation as well, so the URL the daemon WROTE and the URL Swift BUILDS
    /// are two independent derivations of one string and can be compared.
    static let baseURL = URL(string: "https://test.brightspace.example")!

    /// The recorded dropbox folder, and the ordinary row it becomes.
    static let assignmentID = 648_911
    static let assignmentTitle = "Untitled"

    /// The released midterm's grade column, and the heads-up row it becomes.
    static let examColumnID = 812_311
    static let examTitle = "Exam 1"

    static let assignmentsHeader = "Assignments"
    static let headsUpHeader = "Heads up"

    /// Written out whole, so a builder cannot satisfy it with a prefix and a
    /// formatted date. Em dash, matching LADDER-PLAN.
    static let gradebookSubtitle = "In gradebook — no due date"

    /// `{base}/d2l/lms/grades/my_grades/main.d2l?ou={courseId}`, with no column
    /// id anywhere in it — D2L's gradebook is one page per course.
    static let gradebookURL =
        "https://test.brightspace.example/d2l/lms/grades/my_grades/main.d2l?ou=412690"

    // ── The instants ────────────────────────────────────────────────────────

    /// Indiana rather than UTC, matching `GraphGradeOnlyTests`: in UTC a local
    /// day and its instant's day always agree, so a bucketing bug would pass.
    static let zone = TimeZone(identifier: "America/Indianapolis")!

    /// `2026-02-10T15:00:00Z` — 10:00 on **Tuesday Feb 10** in Indiana, the
    /// instant the sibling graph suite probes at. The strip therefore opens on
    /// Sunday Feb 8, which is cell 0.
    static let now = Date(timeIntervalSince1970: 1_770_735_600)

    /// The folder's `DueDate` is `2026-03-04T04:59:00Z` = 23:59 on **Tue Mar 3**
    /// in Indiana (still EST; DST begins Mar 8). Counting from Sunday Feb 8:
    /// Feb 28 is cell 20, so Mar 1 is 21, Mar 2 is 22, **Mar 3 is 23**.
    static let assignmentCell = 23
}

private func headers(_ rows: [MenuRow]) -> [String] {
    rows.compactMap { if case .sectionHeader(let text) = $0 { text } else { nil } }
}

/// The wire items for one course, straight out of `data.json` — untouched by
/// any Swift model, because the two facts outcome 1 is about (`kind` as a
/// string, the precomputed `url`) are exactly the two the decoder erases.
private func wireItems(at paths: DaemonPaths, courseID: Int) throws -> [[String: Any]] {
    let bytes = try Data(contentsOf: paths.dataFile)
    let envelope = try #require(
        try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
    )
    let byCourse = try #require(envelope["assignments"] as? [String: Any])
    return try #require(byCourse[String(courseID)] as? [[String: Any]])
}

@Suite("BUILD 4 intent — the gradebook diff crosses the seam")
struct GradeOnlyIntentTests {

    @Test("a hidden exam's column reaches Heads up, and marks no day")
    func theHiddenExamCrossesTheSeam() async throws {
        // ── Arrange ──────────────────────────────────────────────────────────
        // An empty temp root, and the real daemon path into it. The driver
        // writes its own session file; nothing is seeded here, so every byte the
        // assertions read was produced by the Node side during this test.
        let scratch = try ScratchDir()
        let paths = DaemonPaths(root: scratch.url)

        // ── Act ──────────────────────────────────────────────────────────────
        let outcome = await DaemonRunner(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["node", Driver.url.path],
            paths: paths,
            timeout: 60
        ).run()

        // The daemon's own exit contract, classified by the app's own runner.
        // Required rather than expected: with no cache written, everything below
        // would fail for a reason that has nothing to do with the seam.
        try #require(outcome == .ranOk, "the driver wrote no cache: \(outcome)")

        // ── Assert 1: the wire — data.json holds exactly one gradeOnly item ──
        let items = try wireItems(at: paths, courseID: Expected.courseID)

        // The ordinary work is still there and still first: the gradebook route
        // is additive, and a diff that swallowed the assignments would be a
        // regression this is the only test positioned to see.
        #expect(
            items.map { $0["kind"] as? String } == ["assignment", "gradeOnly"],
            "the daemon wrote \(items.map { $0["kind"] as? String ?? "?" })"
        )

        let column = try #require(items.last)
        #expect(column["id"] as? Int == Expected.examColumnID)
        #expect(column["title"] as? String == Expected.examTitle)
        // Null by contract in v1 — and null on the WIRE, not merely nil after
        // decoding, because an omitted key would also decode to nil.
        #expect(column["dueDate"] is NSNull)
        #expect(column["url"] as? String == Expected.gradebookURL)

        // ── Assert 2: the menu — both sections, and the row a student reads ──
        // The real production reader, over the file the real production writer
        // just produced.
        let assignments = try await DaemonAssignmentSource(paths: paths)
            .fetchAssignments(courseId: Expected.courseID)
        let rows = AssignmentTranslation.submenu(
            state: .loaded(assignments),
            courseId: Expected.courseID,
            now: Expected.now,
            baseURL: Expected.baseURL,
            timeZone: Expected.zone
        )

        // Two populated sections, so the labelling rule (headers only when more
        // than one) puts both headers on screen, Heads up last.
        #expect(headers(rows) == [Expected.assignmentsHeader, Expected.headsUpHeader])
        #expect(rows.assignments.map(\.title) == [Expected.assignmentTitle, Expected.examTitle])

        let headsUp = try #require(rows.assignments.last)
        #expect(headsUp.id == Expected.examColumnID)
        #expect(headsUp.title == Expected.examTitle)
        #expect(headsUp.subtitle == Expected.gradebookSubtitle)
        #expect(headsUp.dueDate == nil)
        // The seam's sharpest edge: Swift derived this from `GradebookLink` and
        // the course id, the daemon derived it from its own template, and the
        // two strings must be one string.
        #expect(headsUp.url.absoluteString == Expected.gradebookURL)
        #expect(headsUp.url.absoluteString == column["url"] as? String)

        // ── Assert 3: the heatmap — the column marks nothing ─────────────────
        let cells = GraphTranslation.strip(
            state: .loaded(assignments), now: Expected.now, timeZone: Expected.zone
        )
        let marked = cells.enumerated().compactMap { $0.element.tier == nil ? nil : $0.offset }

        // The dated assignment is the control. Without it "no cell for the
        // column" is also what a strip that drew nothing at all reports.
        #expect(marked == [Expected.assignmentCell])
    }
}
