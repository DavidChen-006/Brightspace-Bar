import AppKit
import Foundation
import Testing

import BrightspaceBar
import CourseMenu

// ═════════════════════════════════════════════════════════════════════════════
// MenuAssembler — GUI mechanics.
//
// PRIORITIES (the 1–2 carrying 80% of the value here):
//
//   1. CLICK ROUTING CORRECTNESS. Choosing the row for course N must act on
//      course N. This is the bug that ships and is *actively harmful*: the menu
//      looks perfect and sends you to the wrong class. It is also the bug this
//      design invites, because a menu interleaves non-course rows (header,
//      separator, status, commands) among the courses, so NSMenu item index is
//      NOT course index. Every off-by-one lives in that gap.
//
//   2. INERT ROWS STAY INERT. A section header, status line, or message that the
//      user can activate is either confusing (does nothing) or dangerous (shares
//      the course action but carries no course, so it opens garbage or crashes).
//
// CULLED, deliberately: visual appearance (font/colour/indent — not mechanics,
// and unverifiable without snapshot tests), performance (27 rows is nothing),
// menu highlighting and keyboard navigation (AppKit's, free, not ours — that is
// the entire reason we use plain NSMenuItem instead of NSHostingView),
// NSStatusItem behaviour (needs a UI session; the launch smoke test covers it),
// and accessibility (plain NSMenuItems inherit it; nothing custom to verify).
//
// SCOPE: all Google-small. AppKit object graphs are in-process and
// deterministic; no I/O, no network, no clock, no sleeping. Measured: NSMenu
// construction works with NSApp nil.
// ═════════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────
// PINNED DISPLAY FORMAT — the builder implements exactly this.
//
//   subtitle present │ "CS 17600 — Data Engineering"
//   subtitle nil     │ "Purdue Civics Knowledge Test"
//   .refresh         │ "Refresh"
//   .quit            │ "Quit"
//
// Separator is SPACE + EM DASH (U+2014) + SPACE.
//
// Why code first: students identify a class by its code ("I have CS 176 at
// 9am"), so leading with the code makes the dropdown scannable by the token you
// actually search for, and short codes form a rough left-aligned column. When
// there is no subtitle the row is the bare title — no dangling dash, and
// emphatically no interpolated "nil".
// ─────────────────────────────────────────────────────────────────────────────

private enum Format {
    static let separator = " — "

    /// Independent source of truth for the expected title. Deliberately written
    /// as plain concatenation rather than by calling anything in the production
    /// code, so a bug in the implementation's formatter cannot define its own
    /// expected value.
    static func courseTitle(subtitle: String?, title: String) -> String {
        guard let subtitle else { return title }
        return subtitle + self.separator + title
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Local builders.
//
// NOTE FOR THE ORCHESTRATOR: `Sample` / `ScriptedDataSource` in
// Tests/CourseMenuTests/TestSupport.swift are NOT reachable from this target —
// SPM test targets are separate modules and cannot import one another. These
// builders are the minimum replacement. If shared support is wanted across both
// suites it needs to live in a real (non-test) target.
// ─────────────────────────────────────────────────────────────────────────────

private enum Make {
    static func url(_ id: Int) -> URL {
        URL(string: "https://purdue.brightspace.com/d2l/home/\(id)")!
    }

    static func course(id: Int, title: String, subtitle: String?) -> CourseRow {
        CourseRow(id: id, title: title, subtitle: subtitle, url: self.url(id))
    }

    /// Three courses with distinct ids, titles, subtitles, and URLs. Three is the
    /// minimum that makes an off-by-one detectable: with two, "first" and "last"
    /// are adjacent and a neighbour bug can pass by luck.
    static let three: [CourseRow] = [
        Make.course(id: 101, title: "Data Engineering", subtitle: "CS 17600"),
        Make.course(id: 202, title: "Multivariate Calculus", subtitle: "MA 26100"),
        Make.course(id: 303, title: "Transformative Texts", subtitle: "SCLA 10100"),
    ]

    /// The hazard case: courses buried among non-course rows, exactly as the real
    /// stub model looks. Item index and course index diverge here.
    static var interleaved: MenuModel {
        MenuModel(rows: [
            .sectionHeader("Fall 2026"),
            .course(Make.three[0]),
            .course(Make.three[1]),
            .separator,
            .sectionHeader("Spring 2026"),
            .course(Make.three[2]),
            .separator,
            .status("Updated just now"),
            .command(.refresh),
            .command(.quit),
        ])
    }

    /// `@MainActor` because `MenuAssembler`'s initializer is main-actor isolated.
    @MainActor
    static func assembler(
        opener: FakeURLOpener = FakeURLOpener(),
        recorder: CommandRecorder = CommandRecorder()
    ) -> MenuAssembler {
        MenuAssembler(opener: opener) { command in recorder.record(command) }
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// PRIORITY 1 — Click routing correctness
// ═════════════════════════════════════════════════════════════════════════════

@MainActor
@Suite("MenuAssembler — click routing")
struct MenuAssemblerClickRoutingTests {

    @Test("clicking a course opens that course's URL")
    func clickingACourseOpensItsURL() throws {
        // Arrange
        let opener = FakeURLOpener()
        let assembler = Make.assembler(opener: opener)
        let model = MenuModel(rows: Make.three.map { MenuRow.course($0) })
        let menu = assembler.assemble(model)
        let target = Make.three[1]
        let row = try item(titled: Format.courseTitle(subtitle: target.subtitle, title: target.title), in: menu)

        // Act
        try click(row)

        // Assert
        #expect(opener.opened == [Make.url(202)])
    }

    @Test("clicking a course opens exactly one URL")
    func clickingACourseOpensExactlyOneURL() throws {
        // Arrange
        let opener = FakeURLOpener()
        let assembler = Make.assembler(opener: opener)
        let menu = assembler.assemble(MenuModel(rows: Make.three.map { MenuRow.course($0) }))
        let first = Make.three[0]
        let row = try item(titled: Format.courseTitle(subtitle: first.subtitle, title: first.title), in: menu)

        // Act
        try click(row)

        // Assert — not zero (silently dropped) and not two (double dispatch)
        #expect(opener.openedCount == 1)
    }

    /// The off-by-one killer. Each course is clicked in a *fresh* menu so a stale
    /// recorder cannot mask a misroute, and every course is checked — not just one.
    @Test("each course opens its own URL, never a neighbour", arguments: [0, 1, 2])
    func eachCourseOpensItsOwnURL(_ index: Int) throws {
        // Arrange
        let opener = FakeURLOpener()
        let assembler = Make.assembler(opener: opener)
        let menu = assembler.assemble(MenuModel(rows: Make.three.map { MenuRow.course($0) }))
        let expected = Make.three[index]
        let row = try item(titled: Format.courseTitle(subtitle: expected.subtitle, title: expected.title), in: menu)

        // Act
        try click(row)

        // Assert
        #expect(opener.opened == [expected.url])
    }

    /// The real hazard: with headers, separators, a status line and commands mixed
    /// in, NSMenu item index no longer equals course index. An implementation that
    /// maps clicks by item index will fail here and pass every test above.
    @Test("courses route correctly when interleaved with non-course rows", arguments: [0, 1, 2])
    func routingSurvivesInterleavedRows(_ index: Int) throws {
        // Arrange
        let opener = FakeURLOpener()
        let assembler = Make.assembler(opener: opener)
        let menu = assembler.assemble(Make.interleaved)
        let expected = Make.three[index]
        let row = try item(titled: Format.courseTitle(subtitle: expected.subtitle, title: expected.title), in: menu)

        // Act
        try click(row)

        // Assert
        #expect(opener.opened == [expected.url])
    }

    @Test("clicking a course does not fire a command")
    func clickingACourseDoesNotFireACommand() throws {
        // Arrange
        let recorder = CommandRecorder()
        let assembler = Make.assembler(recorder: recorder)
        let menu = assembler.assemble(Make.interleaved)
        let first = Make.three[0]
        let row = try item(titled: Format.courseTitle(subtitle: first.subtitle, title: first.title), in: menu)

        // Act
        try click(row)

        // Assert
        #expect(recorder.received.isEmpty)
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// PRIORITY 1 — Commands
// ═════════════════════════════════════════════════════════════════════════════

@MainActor
@Suite("MenuAssembler — commands")
struct MenuAssemblerCommandTests {

    @Test("each command invokes onCommand with its own case", arguments: MenuCommand.allCases)
    func commandInvokesOnCommand(_ command: MenuCommand) throws {
        // Arrange
        let recorder = CommandRecorder()
        let assembler = Make.assembler(recorder: recorder)
        let menu = assembler.assemble(MenuModel(rows: [.command(command)]))
        let row = try #require(menu.items.first)

        // Act
        try click(row)

        // Assert
        #expect(recorder.received == [command])
    }

    @Test("a command fires exactly once per click")
    func commandFiresOnce() throws {
        // Arrange
        let recorder = CommandRecorder()
        let assembler = Make.assembler(recorder: recorder)
        let menu = assembler.assemble(MenuModel(rows: [.command(.refresh)]))
        let row = try #require(menu.items.first)

        // Act
        try click(row)

        // Assert
        #expect(recorder.count == 1)
    }

    @Test("clicking a command does not open a URL")
    func clickingACommandOpensNoURL() throws {
        // Arrange
        let opener = FakeURLOpener()
        let assembler = Make.assembler(opener: opener)
        let menu = assembler.assemble(MenuModel(rows: [.command(.refresh), .command(.quit)]))

        // Guard: without this the test passes vacuously against an empty menu,
        // because the Act loop would have nothing to click. Verified — it does.
        try #require(menu.items.count == 2)

        // Act
        for row in menu.items { try click(row) }

        // Assert
        #expect(opener.opened.isEmpty)
    }

    @Test("command rows are enabled and carry an action")
    func commandRowsAreActionable() throws {
        // Arrange
        let assembler = Make.assembler()

        // Act
        let menu = assembler.assemble(MenuModel(rows: MenuCommand.allCases.map { MenuRow.command($0) }))

        // Assert — the count guard is what stops an empty menu from satisfying a
        // for-loop of expectations that never executes.
        try #require(menu.items.count == MenuCommand.allCases.count)
        for row in menu.items {
            #expect(row.action != nil, "command row '\(row.title)' has no action")
            #expect(row.isEnabled, "command row '\(row.title)' is disabled")
        }
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// PRIORITY 2 — Inert rows stay inert
// ═════════════════════════════════════════════════════════════════════════════

@MainActor
@Suite("MenuAssembler — non-selectable rows")
struct MenuAssemblerInertRowTests {

    /// `action == nil` is the load-bearing assertion: an item with no action can
    /// never be activated regardless of what `isEnabled` says. `isEnabled == false`
    /// is asserted too because it is what makes the row *look* inert — and because
    /// NSMenu's `autoenablesItems` (true by default) recomputes enablement at
    /// display time, so an implementation relying on `isEnabled` alone would light
    /// these rows back up in the real app.
    @Test(
        "header, status, and message rows are neither enabled nor actionable",
        arguments: [
            MenuRow.sectionHeader("Fall 2026"),
            MenuRow.status("Updated just now"),
            MenuRow.message("No courses yet"),
        ]
    )
    func inertRowsAreNotSelectable(_ row: MenuRow) throws {
        // Arrange
        let assembler = Make.assembler()

        // Act
        let menu = assembler.assemble(MenuModel(rows: [row]))

        // Assert
        let item = try #require(menu.items.first)
        #expect(item.action == nil, "'\(item.title)' carries an action and can be activated")
        #expect(item.isEnabled == false, "'\(item.title)' is enabled and looks clickable")
    }

    /// Guards the specific disaster: an inert row wired to the course action but
    /// carrying no course. If any non-course, non-command row is actionable, this
    /// fails before it can open a garbage URL in front of a user.
    @Test("only course and command rows are actionable in a full menu")
    func onlyCoursesAndCommandsAreActionable() throws {
        // Arrange
        let assembler = Make.assembler()
        let expectedActionable = Set(
            Make.three.map { Format.courseTitle(subtitle: $0.subtitle, title: $0.title) }
                + ["Refresh", "Quit"]
        )

        // Act
        let menu = assembler.assemble(Make.interleaved)

        // Assert
        let actuallyActionable = Set(menu.items.filter { $0.action != nil }.map(\.title))
        #expect(actuallyActionable == expectedActionable)
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// Rendering — structure and titles
// ═════════════════════════════════════════════════════════════════════════════

@MainActor
@Suite("MenuAssembler — rendering")
struct MenuAssemblerRenderingTests {

    @Test("one menu item per model row, in order")
    func oneItemPerRowInOrder() throws {
        // Arrange
        let assembler = Make.assembler()
        let model = Make.interleaved

        // Act
        let menu = assembler.assemble(model)

        // Assert — `#require`, not `#expect`: indexing `NSMenu.items` past the end
        // raises an NSException from the bridged NSArray rather than trapping in
        // Swift, and an uncaught ObjC exception aborts the whole test run instead of
        // failing this one case. Verified against a stub returning an empty menu.
        try #require(menu.items.count == model.rows.count)
        #expect(menu.items[0].title == "Fall 2026")
        #expect(menu.items[1].title == Format.courseTitle(subtitle: "CS 17600", title: "Data Engineering"))
        #expect(menu.items[3].isSeparatorItem)
        #expect(menu.items[4].title == "Spring 2026")
    }

    @Test("a course with a subtitle renders code then title")
    func courseWithSubtitleRendersCodeThenTitle() throws {
        // Arrange
        let assembler = Make.assembler()
        let course = Make.course(id: 1, title: "Data Engineering", subtitle: "CS 17600")

        // Act
        let menu = assembler.assemble(MenuModel(rows: [.course(course)]))

        // Assert — expected value written independently, not via production code
        #expect(menu.items.first?.title == "CS 17600 — Data Engineering")
    }

    /// The classic Swift interpolation bug: `"\(subtitle) — \(title)"` on a nil
    /// optional renders the literal text "nil" and ships it to the user.
    @Test("a course without a subtitle renders the bare title")
    func courseWithoutSubtitleRendersBareTitle() throws {
        // Arrange
        let assembler = Make.assembler()
        let course = Make.course(id: 412_690, title: "Purdue Civics Knowledge Test", subtitle: nil)

        // Act
        let menu = assembler.assemble(MenuModel(rows: [.course(course)]))

        // Assert
        let title = try #require(menu.items.first?.title)
        #expect(title == "Purdue Civics Knowledge Test")
        #expect(!title.contains("nil"), "interpolated a nil optional into the row title")
        #expect(!title.contains(Format.separator), "left a dangling separator with no subtitle")
    }

    @Test("a course without a subtitle is still clickable")
    func courseWithoutSubtitleIsStillClickable() throws {
        // Arrange
        let opener = FakeURLOpener()
        let assembler = Make.assembler(opener: opener)
        let course = Make.course(id: 412_690, title: "Purdue Civics Knowledge Test", subtitle: nil)
        let menu = assembler.assemble(MenuModel(rows: [.course(course)]))
        let row = try #require(menu.items.first)

        // Act
        try click(row)

        // Assert
        #expect(opener.opened == [Make.url(412_690)])
    }

    @Test("command rows use their pinned titles")
    func commandTitles() throws {
        // Arrange
        let assembler = Make.assembler()

        // Act
        let menu = assembler.assemble(MenuModel(rows: [.command(.refresh), .command(.quit)]))

        // Assert
        #expect(menu.items.map(\.title) == ["Refresh", "Quit"])
    }

    @Test("header, status, and message rows render their own text verbatim")
    func proseRowsRenderVerbatim() throws {
        // Arrange
        let assembler = Make.assembler()

        // Act
        let menu = assembler.assemble(MenuModel(rows: [
            .sectionHeader("Fall 2026"),
            .status("Updated 3 minutes ago"),
            .message("No courses yet"),
        ]))

        // Assert
        #expect(menu.items.map(\.title) == ["Fall 2026", "Updated 3 minutes ago", "No courses yet"])
    }

    @Test("a separator row produces an actual separator item")
    func separatorRowProducesSeparator() throws {
        // Arrange
        let assembler = Make.assembler()

        // Act
        let menu = assembler.assemble(MenuModel(rows: [.message("above"), .separator, .message("below")]))

        // Assert — `#require` before positional access; see the note in
        // `oneItemPerRowInOrder` on NSException from out-of-range NSMenu indexing.
        try #require(menu.items.count == 3)
        #expect(menu.items[1].isSeparatorItem)
        #expect(menu.items[0].isSeparatorItem == false)
        #expect(menu.items[2].isSeparatorItem == false)
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// Invariants — the menu is never broken-looking, never truncated
// ═════════════════════════════════════════════════════════════════════════════

@MainActor
@Suite("MenuAssembler — invariants")
struct MenuAssemblerInvariantTests {

    /// The contract promises `placeholder` is never empty because a zero-row
    /// dropdown reads as a crashed app. Assert the assembler honours that rather
    /// than trusting the comment.
    @Test("the placeholder model yields a non-empty menu")
    func placeholderIsNeverEmpty() throws {
        // Arrange
        let assembler = Make.assembler()

        // Act
        let menu = assembler.assemble(.placeholder)

        // Assert
        #expect(!menu.items.isEmpty)
        #expect(menu.items.contains { $0.title == "No courses yet" })
        #expect(menu.items.contains { $0.action != nil }, "placeholder offers the user no way out")
    }

    /// A genuinely empty model is legal input even though `placeholder` is not
    /// empty. The assembler must not crash or invent rows.
    @Test("an empty model assembles to an empty menu without crashing")
    func emptyModelAssemblesCleanly() throws {
        // Arrange
        let assembler = Make.assembler()

        // Act
        let menu = assembler.assemble(MenuModel(rows: []))

        // Assert
        #expect(menu.items.isEmpty)
    }

    /// 27 is the real tenant count. NSMenu has no practical item limit, but an
    /// implementation that paginates or caps would break here.
    @Test("twenty-seven courses assemble without truncation")
    func twentySevenCoursesAssembleFully() throws {
        // Arrange
        let assembler = Make.assembler()
        let courses = (1...27).map { Make.course(id: $0, title: "Course \($0)", subtitle: "C \($0)") }

        // Act
        let menu = assembler.assemble(MenuModel(rows: courses.map { MenuRow.course($0) }))

        // Assert
        #expect(menu.items.count == 27)
        #expect(menu.items.first?.title == "C 1 — Course 1")
        #expect(menu.items.last?.title == "C 27 — Course 27")
    }

    @Test("every one of twenty-seven courses routes to its own URL")
    func allTwentySevenRouteCorrectly() throws {
        // Arrange
        let opener = FakeURLOpener()
        let assembler = Make.assembler(opener: opener)
        let courses = (1...27).map { Make.course(id: $0, title: "Course \($0)", subtitle: "C \($0)") }
        let menu = assembler.assemble(MenuModel(rows: courses.map { MenuRow.course($0) }))

        // Act
        for row in menu.items { try click(row) }

        // Assert — order preserved, one open per row, each to its own id
        #expect(opener.opened == courses.map(\.url))
    }

    /// Assembling twice must not depend on hidden mutable state. Compares the
    /// observable shape of both menus rather than object identity.
    @Test("assembling the same model twice yields structurally equal menus")
    func assemblyIsDeterministic() throws {
        // Arrange
        let assembler = Make.assembler()
        let model = Make.interleaved

        // Act
        let first = assembler.assemble(model)
        let second = assembler.assemble(model)

        // Assert — the guard matters: two *empty* menus are also "structurally equal",
        // so without it this test cannot tell a correct assembler from one that always
        // returns nothing.
        try #require(first.items.count == model.rows.count)

        let shape = { (menu: NSMenu) in
            menu.items.map { [$0.title, "\($0.isSeparatorItem)", "\($0.isEnabled)", "\($0.action != nil)"] }
        }
        #expect(shape(first) == shape(second))
    }

    /// Two menus from one assembler must not share NSMenuItem instances: an
    /// NSMenuItem can belong to only one NSMenu, so reuse would silently detach
    /// rows from the previously built menu.
    @Test("a rebuilt menu does not share item instances with the previous one")
    func rebuildDoesNotShareItems() throws {
        // Arrange
        let assembler = Make.assembler()
        let model = MenuModel(rows: Make.three.map { MenuRow.course($0) })

        // Act
        let first = assembler.assemble(model)
        let second = assembler.assemble(model)

        // Assert — count guard first, else an empty menu satisfies the loop trivially.
        try #require(first.items.count == 3)
        try #require(second.items.count == 3)
        for item in first.items {
            #expect(!second.items.contains { $0 === item }, "item '\(item.title)' is shared between menus")
        }
    }
}
