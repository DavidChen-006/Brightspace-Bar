import AppKit
import Foundation
import Testing

import AssignmentPipeline
import BrightspaceBar
import CourseMenu
import CoursePipeline
import MenuAdapter
import QuizPipeline

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
//      come from (a fixture file instead of a socket — the same boundary the
//      live app crosses). EnrollmentParser, AssignmentParser, QuizParser,
//      CompositeAssignmentSource, AssignmentStore, AssignmentFetcher,
//      MenuTranslation, GraphTranslation, and MenuAssembler are all the real
//      objects, assembled the way `main.swift` assembles them.
//
//   2. THE INTERESTING DATES ARE REAL. `dropbox-folders-with-due-date.json`
//      and `quizzes-with-due-date.json` both carry `2026-03-01T04:59:00.000Z`
//      — which is Feb 28, 23:59 LOCAL in Indiana. One instant exercises the
//      11 PM boundary (a UTC-Sunday deadline bucketing to local Saturday) and,
//      because an assignment and a quiz share it, highest-tier-wins — end to
//      end, not as a unit rule.
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

/// An `AssignmentSource` whose network is a dictionary of captured payloads —
/// the byte-level seam. Parsing happens with the REAL parser on every fetch,
/// exactly where `BrightspaceAssignmentSource` would do it. A course with no
/// entry answers `[]`, like a course whose route has nothing.
private struct FixtureSource: AssignmentSource {
    let bytes: [Int: Data]
    let parse: @Sendable (Data, Int) throws -> [Assignment]

    func fetchAssignments(courseId: Int) async throws -> [Assignment] {
        guard let data = self.bytes[courseId] else { return [] }
        return try self.parse(data, courseId)
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

    private static let scholarly = 440_703
    private static let civics = 412_690

    /// The whole chain, shared by both tests: bytes → parsers → composite →
    /// store → translation. Returns the finished `MenuModel`.
    private func translatedModel() async throws -> MenuModel {
        // 1. Enrollment bytes → [Course], with the REAL parser.
        let courses = try EnrollmentParser().parse(try fixture("CoursePipeline", "myenrollments-200.json"))
        try #require(courses.count == 27)

        // 2. The same visibility filter the app's fetch fan-out uses. At the
        //    pinned date the capture's five Spring-2026 enrollments are current
        //    and the two undated administrative shells ride along — seven
        //    courses, the menu's real February shape. Only the two shells get
        //    payload bytes below; the other five prove that a course with
        //    nothing due still earns an (all-empty) strip.
        let visible = MenuTranslation.visibleCourses(courses, now: Self.now)
        try #require(Set(visible.map(\.id)) == [
            Self.scholarly, Self.civics,
            1_487_623, 1_488_325, 1_488_428, 1_495_427, 1_498_777,
        ])

        // 3. Captured payloads through the real composite → store → fetcher.
        //    Scholarly gets BOTH routes (its Feb 28 collides assignment vs quiz);
        //    Civics gets only the assignment route (its Feb 28 stays a plain
        //    assignment) — so both tiers are observable in one menu.
        let assignmentBytes = try fixture("AssignmentPipeline", "dropbox-folders-with-due-date.json")
        let quizBytes = try fixture("QuizPipeline", "quizzes-with-due-date.json")
        let store = AssignmentStore(clock: FixedClock(now: Self.now))
        let fetcher = AssignmentFetcher(
            source: CompositeAssignmentSource(sources: [
                FixtureSource(
                    bytes: [Self.scholarly: assignmentBytes, Self.civics: assignmentBytes],
                    parse: { try AssignmentParser.parse($0, courseId: $1) }
                ),
                FixtureSource(
                    bytes: [Self.scholarly: quizBytes],
                    parse: { try QuizParser.parse($0, courseId: $1) }
                ),
            ]),
            store: store
        )
        _ = await fetcher.refresh(courses: visible)

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
        let scholarly = try #require(model.courses.first { $0.id == Self.scholarly })
        try #require(scholarly.graph.count == 112)
        #expect(GraphTranslation.windowDays == 112)

        // Scholarly: assignment + quiz share Feb 28 local, so cell 6 carries the
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

        // Civics: same payload, no quiz route — the same day stays an assignment,
        // so both tiers are provably distinguishable end to end.
        let civics = try #require(model.courses.first { $0.id == Self.civics })
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
        // always-emit is now unconditional rather than a consequence of all seven
        // having been fetched. Five of them fetched to empty and still get a full
        // window, and a `neverFetched` course would too.
        let graphed = menu.items.count {
            (($0.view as? MenuItemHostingView)?.cells.isEmpty == false)
        }
        #expect(graphed == model.courses.count { !$0.graph.isEmpty })
        #expect(graphed == 7)
        // And the item count matches the model exactly — nothing extra anywhere.
        #expect(menu.items.count == model.rows.count)
    }
}
