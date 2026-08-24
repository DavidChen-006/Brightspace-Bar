import AppKit
import Foundation
import Testing

import AssignmentPipeline
import BrightspaceBar
import CourseMenu
import CoursePipeline
import MenuAdapter

// ═════════════════════════════════════════════════════════════════════════════
// THE FULL VERTICAL SLICE — fixture bytes in, a visible strip out.
//
// The four graph parts each carry their own suite: the contract
// (GraphCellTests), the stub seeds (StubGraphSeedTests), the mapping
// (GraphTranslationTests), and the rendering (MenuAssemblerGraphTests). What
// none of them proves is the WIRING: that real captured payloads flow through
// the real parser → composite source → store → translation chain and come out
// the other end as a strip item the menu actually shows. This suite is that
// proof, and it is the orchestrator's acceptance test for the slice.
//
// PRIORITIES:
//
//   1. NO TEST DOUBLES PAST THE BYTES. The only fake here is where the bytes
//      come from (files on disk instead of a socket — the same boundary the live
//      app crosses). EnrollmentParser, DaemonAssignmentSource, AssignmentStore,
//      AssignmentFetcher, MenuTranslation, GraphTranslation, and MenuAssembler
//      are all the real objects, assembled the way `main.swift` assembles them.
//
//      Phase 5 moved the assignment half of that boundary. The app no longer
//      parses D2L's own dropbox and quiz payloads — the Node daemon does, and
//      merges both kinds into ONE list per course in `cache/data.json`. So the
//      bytes this suite feeds in are a canned daemon cache rather than two
//      captured D2L payloads through `AssignmentParser`/`QuizParser`, and
//      `CompositeAssignmentSource` (which merged them in Swift) is gone.
//
//   2. THE INTERESTING DATES ARE REAL. Both an assignment and a quiz carry
//      `2026-03-01T04:59:00.000Z` — which is Feb 28, 23:59 LOCAL in Indiana, and
//      is the instant the retired captures carried, transcribed verbatim. One
//      instant exercises the 11 PM boundary (a UTC-Sunday deadline bucketing to
//      local Saturday) and, because an assignment and a quiz share it,
//      highest-tier-wins — end to end, not as a unit rule. The fractional
//      seconds are kept deliberately: they exercise the daemon decoder's
//      two-attempt date path on the way through.
//
// CULLED: pixels (colour, outline geometry — visual, verified in stub mode),
// polling, disk persistence, and the network itself (BS_LIVE covers the
// socket).
//
// SCOPE: medium — many real components, one process, no I/O beyond fixture
// reads.
// ═════════════════════════════════════════════════════════════════════════════

/// Fixture bytes from ANOTHER module's Tests/Fixtures directory, resolved via
/// `#filePath` exactly like each module's own `TestSupport.Fixture`. This suite
/// deliberately reads its neighbours' captures rather than keeping copies — a
/// copy would go stale the day a capture is re-recorded.
private func fixture(_ module: String, _ name: String) throws -> Data {
    let modules = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/
        .deletingLastPathComponent() // BrightspaceBar/
        .deletingLastPathComponent() // Modules/
    return try Data(contentsOf: modules.appending(path: "\(module)/Tests/Fixtures/\(name)"))
}

/// The one clock in this file. Injected everywhere a clock is asked for, so the
/// whole slice agrees on what "today" is.
private struct FixedClock: Clock {
    let now: Date
}

/// A temp `BSB_ROOT` holding one canned `cache/data.json` — the file the daemon
/// writes after a successful climb, and the only thing the app's assignment
/// source ever reads. Deletes itself when the test that built it goes away.
private final class CannedCache {
    let paths: DaemonPaths
    private let root: URL

    init(_ dataJSON: String) throws {
        self.root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "graph-e2e-\(UUID().uuidString)")
            .standardizedFileURL
        self.paths = DaemonPaths(root: self.root)
        try FileManager.default.createDirectory(
            at: self.paths.cacheDirectory, withIntermediateDirectories: true
        )
        try Data(dataJSON.utf8).write(to: self.paths.dataFile)
    }

    deinit {
        try? FileManager.default.removeItem(at: self.root)
    }
}

@Suite("The graph slice, end to end")
struct GraphEndToEndTests {

    // 2026-02-24T17:00:00Z — noon on Tuesday Feb 24 in America/Indianapolis.
    // Chosen so the fixtures' shared deadline (Feb 28 local) sits inside the
    // window and every dated Fall-2024 enrollment is long ended.
    //
    // The window is week-aligned (NewVertical-3 §4), so it opens on the SUNDAY of
    // this week — Feb 22 — and runs 112 days. Transcribed by hand from the
    // calendar, not computed the way the code computes it:
    //
    //   cell 0 → Sun Feb 22 (window start)   cell 2 → Tue Feb 24 (today)
    //   cell 6 → Sat Feb 28 (the shared deadline, 23:59 local)
    //
    // Note that today is cell 2, not cell 0. That is the alignment change, and
    // this suite is where it is observed end to end.
    private static let now = Date(timeIntervalSince1970: 1_771_952_400)

    /// Today's cell — third day of a Sunday-first week, because Feb 24 is a
    /// Tuesday.
    private static let todayIndex = 2

    /// The cell both fixtures' `2026-03-01T04:59:00.000Z` lands on: Sat Feb 28
    /// local, six days after the window opened.
    private static let deadlineIndex = 6
    private static let zone = TimeZone(identifier: "America/Indianapolis")!
    private static let baseURL = URL(string: "https://purdue.brightspace.com")!

    // Two CURRENT Spring-2026 hosts for the interesting payloads. The undated
    // shells (Scholarly 440703, Civics 412690) that originally carried them are
    // hidden since the 2026-08-24 user decision — hidden everywhere, so the
    // fan-out never visits them and they can hold no strip.
    private static let hostWithQuiz = 1_488_325       // Spring 2026 CS 25200
    private static let hostAssignmentsOnly = 1_487_623

    /// One `cache/data.json` exactly as the daemon writes it (LADDER-PLAN, "File
    /// contracts"): every course the fan-out will visit is present, a course with
    /// no work carries `[]` — which is DATA — and each item is `id`/`title`/
    /// `dueDate`/`kind`, with both kinds in ONE list per course, assignments
    /// before quizzes.
    ///
    /// Written by hand rather than generated, so an expected value can never be
    /// derived the way the code derives it. The three shapes that matter:
    /// the SHARED deadline (an assignment and a quiz on the same instant, which is
    /// how tier precedence becomes observable), an out-of-window deadline, and an
    /// unparseable date — which must cost its own cell and nothing else.
    private static let daemonCache = """
        {
          "fetchedAt": "2026-02-24T17:00:00Z",
          "courses": [],
          "assignments": {
            "\(hostWithQuiz)": [
              { "id": 700001, "title": "Homework 3", "dueDate": "2026-03-01T04:59:00.000Z", "kind": "assignment" },
              { "id": 700002, "title": "Group Project Milestone", "dueDate": "2026-09-15T23:59:00Z", "kind": "assignment" },
              { "id": 700003, "title": "Assignment With A Broken Date", "dueDate": "not-a-date", "kind": "assignment" },
              { "id": 900101, "title": "Midterm Exam", "dueDate": "2026-03-01T04:59:00.000Z", "kind": "quiz" },
              { "id": 900102, "title": "Final Exam", "dueDate": "2026-09-15T23:59:00Z", "kind": "quiz" },
              { "id": 900103, "title": "Quiz With A Broken Date", "dueDate": "not-a-date", "kind": "quiz" }
            ],
            "\(hostAssignmentsOnly)": [
              { "id": 700001, "title": "Homework 3", "dueDate": "2026-03-01T04:59:00.000Z", "kind": "assignment" },
              { "id": 700002, "title": "Group Project Milestone", "dueDate": "2026-09-15T23:59:00Z", "kind": "assignment" },
              { "id": 700003, "title": "Assignment With A Broken Date", "dueDate": "not-a-date", "kind": "assignment" }
            ],
            "1488428": [], "1495427": [], "1498777": []
          }
        }
        """

    /// The whole chain, shared by both tests: bytes → daemon cache → source →
    /// store → translation. Returns the finished `MenuModel`.
    private func translatedModel() async throws -> MenuModel {
        // 1. Enrollment bytes → [Course], with the REAL parser.
        let courses = try EnrollmentParser().parse(try fixture("CoursePipeline", "myenrollments-200.json"))
        try #require(courses.count == 27)

        // 2. The same visibility filter the app's fetch fan-out uses. At the
        //    pinned date the capture's five Spring-2026 enrollments are current
        //    — and nothing else: since the 2026-08-24 user decision the two
        //    undated administrative shells are hidden and never fetched. Only
        //    two of the five get payload bytes below; the other three prove
        //    that a course with nothing due still earns an (all-empty) strip.
        let visible = MenuTranslation.visibleCourses(courses, now: Self.now)
        try #require(Set(visible.map(\.id)) == [
            1_487_623, 1_488_325, 1_488_428, 1_495_427, 1_498_777,
        ])

        // 3. A canned daemon cache through the real source → fetcher → store.
        //    One host holds BOTH kinds (its Feb 28 collides assignment vs quiz);
        //    the other holds assignments only (its Feb 28 stays a plain
        //    assignment) — so both tiers are observable in one menu. The other
        //    three courses are present with empty lists, as the daemon writes them.
        let cache = try CannedCache(Self.daemonCache)
        let store = AssignmentStore(clock: FixedClock(now: Self.now))
        let fetcher = AssignmentFetcher(
            source: DaemonAssignmentSource(paths: cache.paths),
            store: store
        )
        _ = await fetcher.refresh(courses: visible)
        // The temp root must outlive every read of it, and the last mention of
        // `cache` above is the source's construction.
        withExtendedLifetime(cache) {}

        var states: [Int: AssignmentsState] = [:]
        for course in visible {
            states[course.id] = await store.state(for: course.id)
        }

        // 4. The one crossing into frontend vocabulary, as `MenuAdapter.snapshot`
        //    performs it.
        return MenuTranslation.menu(
            courses: courses,
            lastFetch: Self.now,
            now: Self.now,
            baseURL: Self.baseURL,
            assignments: states,
            timeZone: Self.zone
        )
    }

    @Test("captured payloads become correctly placed, correctly tiered cells")
    func bytesBecomeCells() async throws {
        // Arrange / Act — the full chain.
        let model = try await self.translatedModel()

        // Assert — the window is 16 whole weeks, stated as a literal so the
        // production constant cannot be resized and re-blessed in one edit.
        let scholarly = try #require(model.courses.first { $0.id == Self.hostWithQuiz })
        try #require(scholarly.graph.count == 112)
        #expect(GraphTranslation.windowDays == 112)

        // The quiz host: assignment + quiz share Feb 28 local, so cell 6 carries the
        // higher tier. Cell 2 is today: outlined, honestly empty — and it is cell
        // 2 rather than cell 0 only because the window opens on Sunday.
        #expect(scholarly.graph[Self.todayIndex] == GraphCell(tier: nil, isToday: true))
        #expect(scholarly.graph[Self.deadlineIndex].tier == .quiz)

        // The hidden Sep-15 item, the broken-date items, and the out-of-window
        // deadline left every other cell empty — nothing leaked, and nothing
        // else claims to be today.
        for (index, cell) in scholarly.graph.enumerated()
        where index != Self.todayIndex && index != Self.deadlineIndex {
            #expect(cell == GraphCell(tier: nil, isToday: false), "cell \(index) should be empty")
        }

        // The assignments-only host: same payload, no quiz route — the same day stays an assignment,
        // so both tiers are provably distinguishable end to end.
        let civics = try #require(model.courses.first { $0.id == Self.hostAssignmentsOnly })
        #expect(civics.graph.count == 112)
        #expect(civics.graph[Self.deadlineIndex].tier == .assignment)
    }

    @Test("the translated model assembles into course components carrying their cells")
    @MainActor
    func cellsBecomeComponents() async throws {
        // Arrange — the same finished model.
        let model = try await self.translatedModel()

        // Act — the real assembler, as `StatusBarController` drives it.
        let menu = MenuAssembler(opener: FakeURLOpener(), onCommand: { _ in }).assemble(model)

        // Assert — each course is ONE item whose hosted component carries
        // EXACTLY that course's cells (the slice-1 shape: no strip items).
        for expected in model.courses {
            let item = try #require(
                menu.items.first { ($0.representedObject as? URL) == expected.url },
                "no menu item for course \(expected.id)"
            )
            let component = try #require(
                item.view as? MenuItemHostingView, "course \(expected.id) has no component view"
            )
            #expect(component.cells == expected.graph)
        }

        // One component per course, and EVERY course carries cells — which under
        // always-emit is now unconditional rather than a consequence of all five
        // having been fetched. Three of them fetched to empty and still get a full
        // window, and a `neverFetched` course would too.
        let graphed = menu.items.count {
            (($0.view as? MenuItemHostingView)?.cells.isEmpty == false)
        }
        #expect(graphed == model.courses.count { !$0.graph.isEmpty })
        #expect(graphed == 5)
        // And the item count matches the model exactly — nothing extra anywhere.
        #expect(menu.items.count == model.rows.count)
    }

    @Test("the finished component: labels, boundaries, and a uniform submenu")
    @MainActor
    func theWholeComponentAssembles() async throws {
        // Arrange / Act — the campaign's closing assertion set: everything the
        // five slices added, observed together through one real menu.
        let model = try await self.translatedModel()
        let menu = MenuAssembler(opener: FakeURLOpener(), onCommand: { _ in }).assemble(model)

        // Month labels flowed backend → contract → component, and the window's
        // opening month is February at column 0 (now is Feb 24; window opens
        // Sun Feb 22).
        for expected in model.courses {
            let item = try #require(menu.items.first { ($0.representedObject as? URL) == expected.url })
            let component = try #require(item.view as? MenuItemHostingView)
            #expect(component.monthLabels == expected.graphMonths)
            #expect(component.monthLabels.count == 16)
            #expect(component.monthLabels.first == "Feb")

            // Submenu uniformity: EVERY course — including the five that
            // fetched to empty — opens onto Open Course Home above its rows.
            let submenu = try #require(item.submenu, "course \(expected.id) has no submenu")
            #expect(submenu.items.first?.title == "Open Course Home")
        }

        // Boundaries: exactly one hairline row per course, all inert.
        let hairlines = menu.items.filter { $0.view is HairlineRowView }
        #expect(hairlines.count == model.courses.count)
        #expect(hairlines.allSatisfy { !$0.isEnabled && $0.title.isEmpty })
    }
}
