import AppKit
import Foundation
import Testing

import BrightspaceBar
import CourseMenu

// ═════════════════════════════════════════════════════════════════════════════
// MenuAssembler — the course COMPONENT item (NewVertical-3.md §3.5, build step 1).
//
// This file used to pin "course item + a separate inert strip item beneath it".
// That shape is gone. A course now assembles to ONE view-backed item whose view
// — `MenuItemHostingView` — carries the title and the cells together, which is
// the entire point of the slice: AppKit can highlight one item, so title and
// graph must BE one item to highlight together (§1, the bottleneck).
//
// PRIORITIES (the 1–2 carrying 80% of the value):
//
//   1. THE COMPONENT IS THE ROW, AND IT IS COMPLETE. Every `.course` row — graphed
//      or not — becomes exactly one item carrying a hosting view with that
//      course's own title and own cells. Uniformity is the assertion, not an
//      aesthetic: a course whose component is missing looks identical to a course
//      with nothing due, and the two-items-per-course shape that this replaces is
//      what made positional bugs possible in the first place.
//
//   2. GOING VIEW-BACKED COSTS NOTHING ELSE. A view-backed item replaces native
//      rendering wholesale (§1, "all or nothing"), so everything AppKit used to do
//      for free is now something that can silently disappear: the click
//      (`representedObject` + action), the submenu, enablement, the title other
//      suites look rows up by, and — the failure with no visual tell — a frame
//      left at `.zero`, which renders an invisible row. Hover unity itself lands
//      here too, because the highlight signal is now ours to deliver:
//      `NSMenuDelegate.menu(_:willHighlight:)` → a flag on each view.
//
// CULLED, deliberately: everything about how the component LOOKS. The capsule
// metrics, the hand-drawn chevron's glyph, the highlighted palette swap, the
// cell fills, and the SwiftUI sandwich inside the hosting view (CourseCardView →
// CourseGraphView → GraphRasterView → GraphRasterNSView) are verified VISUALLY
// under `BRIGHTSPACEBAR_STUB=1`, and were MEASURED live in experiment 9. This
// process has no window, never displays a menu, and never calls `draw(_:)`.
// These tests therefore touch only the hosting view's observable surface —
// class, `cells`, `title`, `isHighlightedForMenu`, `showsChevron`, `frame` — and
// never reach into the SwiftUI layers, so the sandwich can be rearranged without
// rewriting this file. Also culled: the strip's pure geometry suite, which went
// with `GraphStripView`; grid geometry is slice 4's and will be pinned against
// whatever replaces it, not against a layout the design has retired.
//
// SCOPE: all Google-small. In-process AppKit object graphs; no I/O, no network,
// no clock, no window, no display.
// ═════════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────
// PINNED STRUCTURE — the builder implements exactly this.
//
// In `Modules/BrightspaceBar/Sources`, the §3.5 layering:
//
//     public final class MenuItemHostingView: NSView {
//         public let cells: [GraphCell]
//         public let title: String
//         public var isHighlightedForMenu: Bool   // didSet → needsDisplay
//         public var showsChevron: Bool
//     }
//
// `public`, because this target does a plain `import BrightspaceBar`, not a
// `@testable import`, matching the rest of the suite.
//
// EVERY `.course` row produces exactly ONE `NSMenuItem`:
//
//   • `view` is a `MenuItemHostingView` whose `cells == course.graph` (empty for
//     an ungraphed course — a title-only card, NOT a missing view) and whose
//     `title` is the course's display title.
//   • `title` — the item's own — stays the display title as well. The view draws
//     it, so AppKit never renders it, but it is how `MenuAssemblerTests` and
//     `MenuAssemblerSubmenuTests` find rows, and dropping it would break ~16
//     lookups in suites this slice is not allowed to touch.
//   • `representedObject`, `action`, `target`, `isEnabled` and `submenu` are
//     exactly what they were before the view existed.
//   • `showsChevron` is true iff the item owns a submenu — AppKit draws no
//     submenu arrow for a view-backed item, so the view must draw its own.
//   • `frame.size` is nonzero, and taller for a graphed course than an ungraphed
//     one. An `NSMenuItem.view` is not laid out for you; at `.zero` it is simply
//     invisible, which is a shipping bug that looks exactly like "nothing due".
//
// No item anywhere carries a `GraphStripView` — the class is deleted.
//
// HIGHLIGHT: the assembled `NSMenu` gets a delegate implementing
// `menu(_:willHighlight:)`, which sets `isHighlightedForMenu = (item === row)` on
// every hosting view in the menu. `NSMenu.delegate` is WEAK, so the assembler
// must retain the delegate object itself — otherwise it deallocates immediately
// and hover unity silently never happens in the real app. The method is plain and
// is called directly here, headless.
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// Builders. Local to this file: SPM test targets are separate modules, so the
// support types in the other suites' files are private and the ones in
// Tests/CourseMenuTests are unreachable.
// ─────────────────────────────────────────────────────────────────────────────

private enum Graphed {
    static func courseURL(_ id: Int) -> URL {
        URL(string: "https://purdue.brightspace.com/d2l/home/\(id)")!
    }

    static func assignmentURL(folder: Int, course: Int) -> URL {
        URL(string:
            "https://purdue.brightspace.com/d2l/lms/dropbox/user/folder_submit_files.d2l"
            + "?db=\(folder)&grpid=0&ou=\(course)"
        )!
    }

    /// A five-day strip, written as a literal rather than generated from a date
    /// mapping, so the renderer's expected input is independent of the layer that
    /// will eventually produce it. Cell 0 is today AND carries work — the case
    /// where the today outline must not replace the fill, which is why `isToday`
    /// is a separate field from `tier` in the first place.
    static let strip: [GraphCell] = [
        GraphCell(tier: .assignment, isToday: true),
        GraphCell(tier: nil),
        GraphCell(tier: .quiz),
        GraphCell(tier: nil),
        GraphCell(tier: .assignment),
    ]

    static let graphedID = 440_703
    static let graphedTitle = "Scholarly Project Milestones"

    /// The same course twice, with and without a graph, so "having a graph
    /// changed nothing about the course item" can be checked against a control
    /// rather than against a re-stated expectation.
    static var graphed: CourseRow {
        CourseRow(
            id: Self.graphedID, title: Self.graphedTitle,
            url: Self.courseURL(Self.graphedID), graph: Self.strip
        )
    }

    static var ungraphedTwin: CourseRow {
        CourseRow(id: Self.graphedID, title: Self.graphedTitle, url: Self.courseURL(Self.graphedID))
    }

    static let plainID = 412_690
    static let plainTitle = "Purdue Civics Knowledge Test"

    /// A course that never gets cells. Its presence in every mixed model is what
    /// proves the cells are attached to the graphed course specifically, and not
    /// simply handed to every component.
    static var plain: CourseRow {
        CourseRow(id: Self.plainID, title: Self.plainTitle, url: Self.courseURL(Self.plainID))
    }

    /// A course with a subtitle, so "the view's title is the DISPLAY title" is
    /// distinguishable from "the view's title is `CourseRow.title`" — for every
    /// course above they are the same string.
    static let codedID = 176_001
    static var coded: CourseRow {
        CourseRow(
            id: Self.codedID, title: "Data Engineering", subtitle: "CS 17600",
            url: Self.courseURL(Self.codedID), graph: Self.strip
        )
    }

    static let codedDisplayTitle = "CS 17600 — Data Engineering"

    static let assignments: [AssignmentRow] = [
        AssignmentRow(
            id: 445_296, title: "Upload your CITI Certificate to Complete Module 2",
            url: Graphed.assignmentURL(folder: 445_296, course: Graphed.graphedID)
        ),
        AssignmentRow(
            id: 445_297, title: "Report on your PURC Experience.",
            url: Graphed.assignmentURL(folder: 445_297, course: Graphed.graphedID)
        ),
    ]

    /// The full shape: a course that has BOTH a submenu and a graph.
    static var graphedWithSubmenu: CourseRow {
        CourseRow(
            id: Self.graphedID, title: Self.graphedTitle, url: Self.courseURL(Self.graphedID),
            submenu: Self.assignments.map { MenuRow.assignment($0) },
            graph: Self.strip
        )
    }

    /// The real model shape, with every course ungraphed. Every `CourseRow` built
    /// by hand in the other suites defaults to `graph == []`, so this is also the
    /// shape those ~384 tests assemble.
    static var interleavedUngraphed: MenuModel {
        MenuModel(rows: [
            .sectionHeader("Fall 2026"),
            .course(Graphed.ungraphedTwin),
            .course(Graphed.plain),
            .separator,
            .status(.nextRefresh(.distantFuture)),
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

/// Every component view in a menu, in item order.
@MainActor
private func components(in menu: NSMenu) -> [MenuItemHostingView] {
    menu.items.compactMap { $0.view as? MenuItemHostingView }
}

/// The component belonging to the row a user would read as `title`.
@MainActor
private func component(
    titled title: String, in menu: NSMenu, _ sourceLocation: SourceLocation = #_sourceLocation
) throws -> MenuItemHostingView {
    let row = try item(titled: title, in: menu, sourceLocation)
    return try #require(
        row.view as? MenuItemHostingView,
        "the row '\(title)' carries no MenuItemHostingView, so it renders as an empty menu row",
        sourceLocation: sourceLocation
    )
}

/// Delivers the highlight signal the way AppKit does — through the delegate the
/// assembler installed, not through a delegate the test supplies — so a menu
/// assembled with no delegate, or with one that was not retained, fails here.
@MainActor
private func highlight(
    _ item: NSMenuItem?, in menu: NSMenu, _ sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let delegate = try #require(
        menu.delegate,
        "the assembled menu has no delegate, so nothing ever tells a component it is hovered (NSMenu.delegate is weak — the assembler must retain it)",
        sourceLocation: sourceLocation
    )
    delegate.menu?(menu, willHighlight: item)
}

// ═════════════════════════════════════════════════════════════════════════════
// PRIORITY 1 — One component per course, carrying that course's own content
// ═════════════════════════════════════════════════════════════════════════════

@MainActor
@Suite("MenuAssembler — the course component item")
struct MenuAssemblerComponentTests {

    /// The relocated core of the old "course item + strip item" assertion: the
    /// cells are still there, but they are now ON the course's own item, and there
    /// is no second item at all.
    @Test("a graphed course is ONE item whose view carries its cells")
    func graphedCourseIsOneItemCarryingItsCells() throws {
        // Arrange
        let assembler = Graphed.assembler()
        let course = Graphed.graphed

        // Act
        let menu = assembler.assemble(MenuModel(rows: [.course(course)]))

        // Assert — `#require` before positional access: indexing NSMenu.items past
        // the end raises an NSException that aborts the whole run rather than
        // failing this one test.
        try #require(menu.items.count == 1, "a graphed course still produces a second, separate item")
        let view = try #require(
            menu.items[0].view as? MenuItemHostingView,
            "the course item carries no MenuItemHostingView, so its graph is nowhere"
        )
        #expect(view.cells == course.graph)
    }

    /// The cells travel verbatim — not re-derived, re-ordered, or truncated.
    /// Today's cell keeps its tier, which is the data-side half of "the today
    /// indicator must not obscure the activity state".
    @Test("the component carries every cell, in model order, with tier and isToday intact")
    func componentCarriesCellsVerbatim() throws {
        // Arrange
        let assembler = Graphed.assembler()

        // Act
        let menu = assembler.assemble(MenuModel(rows: [.course(Graphed.graphed)]))

        // Assert — the literal strip, written independently of any mapping code.
        let view = try #require(components(in: menu).first)
        #expect(view.cells == [
            GraphCell(tier: .assignment, isToday: true),
            GraphCell(tier: nil),
            GraphCell(tier: .quiz),
            GraphCell(tier: nil),
            GraphCell(tier: .assignment),
        ])
    }

    /// The uniformity rule, and the inversion of the assertion this file used to
    /// make. An ungraphed course is not a native row any more: it is the same
    /// component with an empty graph. Anything else means two rendering paths for
    /// rows that must look identical.
    @Test("an ungraphed course also gets a component, carrying no cells")
    func ungraphedCourseAlsoGetsAComponent() throws {
        // Arrange
        let assembler = Graphed.assembler()

        // Act
        let menu = assembler.assemble(MenuModel(rows: [.course(Graphed.plain)]))

        // Assert
        try #require(menu.items.count == 1)
        let view = try #require(
            menu.items[0].view as? MenuItemHostingView,
            "an ungraphed course is still a plain native row, so it renders unlike its neighbours"
        )
        #expect(view.cells.isEmpty, "a course with no graph was given cells from somewhere")
    }

    /// The display title, not `CourseRow.title`: the component draws its own text,
    /// so a component that took the raw field would silently drop every course code.
    @Test("the component's title is the course's display title, subtitle included")
    func componentTitleIsTheDisplayTitle() throws {
        // Arrange
        let assembler = Graphed.assembler()

        // Act
        let menu = assembler.assemble(MenuModel(rows: [.course(Graphed.coded)]))

        // Assert
        let view = try #require(components(in: menu).first)
        #expect(view.title == Graphed.codedDisplayTitle)
    }

    /// Two graphed courses: each component carries its OWN cells and OWN title. An
    /// implementation that builds one component per menu, or reuses the first
    /// course's content, passes every single-course test above and fails here.
    @Test("each course's component carries its own title and its own cells")
    func eachCourseGetsItsOwnComponent() throws {
        // Arrange
        let assembler = Graphed.assembler()
        let second = CourseRow(
            id: 999_001, title: "Multivariate Calculus", subtitle: "MA 26100",
            url: Graphed.courseURL(999_001),
            graph: [GraphCell(tier: .quiz), GraphCell(tier: nil)]
        )

        // Act
        let menu = assembler.assemble(MenuModel(rows: [.course(Graphed.graphed), .course(second)]))

        // Assert
        let found = components(in: menu)
        try #require(found.count == 2)
        #expect(found[0].title == Graphed.graphedTitle)
        #expect(found[0].cells == Graphed.strip)
        #expect(found[1].title == "MA 26100 — Multivariate Calculus")
        #expect(found[1].cells == second.graph)
    }

    /// The component belongs to the course row itself, at the course's own level —
    /// never inside the hover submenu, where the graph would be unreachable without
    /// hovering and would collide with the assignment rows.
    @Test("no component is rendered inside the course's submenu")
    func componentIsNotInsideTheSubmenu() throws {
        // Arrange
        let assembler = Graphed.assembler()

        // Act
        let menu = assembler.assemble(MenuModel(rows: [.course(Graphed.graphedWithSubmenu)]))

        // Assert
        let sub = try #require(
            menu.items.first?.submenu,
            "the graphed course lost its submenu, so its assignments are unreachable"
        )
        #expect(components(in: sub).isEmpty, "a component was rendered inside the submenu")
        #expect(components(in: menu).count == 1)
    }

    /// Assembling twice must not depend on hidden mutable state, and — because an
    /// `NSView` can have only one superview just as an `NSMenuItem` can belong to
    /// only one `NSMenu` — a reused component view would silently detach from the
    /// previously built menu.
    @Test("a rebuilt menu does not share component view instances with the previous one")
    func rebuildDoesNotShareComponentViews() throws {
        // Arrange
        let assembler = Graphed.assembler()
        let model = MenuModel(rows: [.course(Graphed.graphed)])

        // Act
        let first = assembler.assemble(model)
        let second = assembler.assemble(model)

        // Assert — count guards first, else the comparison is satisfied trivially.
        let firstView = try #require(components(in: first).first)
        let secondView = try #require(components(in: second).first)
        #expect(firstView !== secondView, "the same MenuItemHostingView instance is in both menus")
        #expect(firstView.cells == secondView.cells)
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// PRIORITY 2 — Going view-backed costs nothing else: item semantics and counts
// ═════════════════════════════════════════════════════════════════════════════

@MainActor
@Suite("MenuAssembler — the component item stays a course row")
struct MenuAssemblerComponentSemanticsTests {

    /// Checked against a CONTROL — the same course assembled without a graph —
    /// rather than against a re-stated expectation, so this cannot drift away from
    /// whatever the course-row behaviour actually is. `view` is deliberately NOT
    /// compared: having one is now the point.
    @Test("a graphed course item matches its ungraphed twin in every menu-item field")
    func courseItemIsUnchangedByItsGraph() throws {
        // Arrange
        let assembler = Graphed.assembler()
        let control = assembler.assemble(MenuModel(rows: [.course(Graphed.ungraphedTwin)]))
        let controlItem = try #require(control.items.first)

        // Act
        let menu = assembler.assemble(MenuModel(rows: [.course(Graphed.graphed)]))

        // Assert
        let item = try #require(menu.items.first)
        #expect(item.title == controlItem.title)
        #expect(item.action == controlItem.action)
        #expect(item.isEnabled == controlItem.isEnabled)
        #expect(item.representedObject as? URL == controlItem.representedObject as? URL)
    }

    /// The item keeps a real title even though the view draws the text. Two suites
    /// this slice must not touch look their rows up by title, and a view-backed
    /// item with an empty title is invisible to them.
    @Test("the component item keeps its display title on the menu item itself")
    func componentItemKeepsItsTitle() throws {
        // Arrange
        let assembler = Graphed.assembler()

        // Act
        let menu = assembler.assemble(MenuModel(rows: [.course(Graphed.coded)]))

        // Assert
        let item = try #require(menu.items.first)
        #expect(item.title == Graphed.codedDisplayTitle)
    }

    @Test("the component item carries its course URL and is enabled")
    func componentItemCarriesItsURLAndIsEnabled() throws {
        // Arrange
        let assembler = Graphed.assembler()

        // Act
        let menu = assembler.assemble(MenuModel(rows: [.course(Graphed.graphed)]))

        // Assert
        let item = try #require(menu.items.first)
        #expect(item.representedObject as? URL == Graphed.courseURL(Graphed.graphedID))
        #expect(item.isEnabled, "the component row is disabled, so it cannot be hovered or clicked")
    }

    @Test("a graphed course still opens its own URL when clicked")
    func graphedCourseStillOpensItsURL() throws {
        // Arrange
        let opener = FakeURLOpener()
        let assembler = Graphed.assembler(opener: opener)
        let menu = assembler.assemble(MenuModel(rows: [.course(Graphed.graphed)]))
        let row = try item(titled: Graphed.graphedTitle, in: menu)

        // Act
        try click(row)

        // Assert
        #expect(opener.opened == [Graphed.courseURL(Graphed.graphedID)])
    }

    /// Click identity must still travel with the item, not with a position: the
    /// component rows are the only rows now, so a positional resolver opens the
    /// neighbouring class.
    @Test("a course after a graphed course still opens its own URL, not its neighbour's")
    func courseAfterAComponentRoutesCorrectly() throws {
        // Arrange
        let opener = FakeURLOpener()
        let assembler = Graphed.assembler(opener: opener)
        let menu = assembler.assemble(MenuModel(rows: [.course(Graphed.graphed), .course(Graphed.plain)]))
        let row = try item(titled: Graphed.plainTitle, in: menu)

        // Act
        try click(row)

        // Assert
        #expect(opener.opened == [Graphed.courseURL(Graphed.plainID)])
    }

    @Test("a graphed course with assignments keeps its submenu intact")
    func graphedCourseKeepsItsSubmenu() throws {
        // Arrange
        let assembler = Graphed.assembler()

        // Act
        let menu = assembler.assemble(MenuModel(rows: [.course(Graphed.graphedWithSubmenu)]))

        // Assert
        let sub = try #require(menu.items.first?.submenu, "the graphed course lost its submenu")
        try #require(sub.items.count == 2 + Graphed.assignments.count)
        #expect(sub.items[0].title == "Open Course Home")
        #expect(sub.items[1].isSeparatorItem)
        #expect(sub.items.dropFirst(2).map(\.title) == Graphed.assignments.map(\.title))
    }

    /// AppKit draws no submenu arrow for a view-backed item, so a row that owns a
    /// submenu now has to say so itself — otherwise the hover submenu exists with
    /// nothing on screen suggesting it does.
    @Test("the component shows a chevron exactly when its item owns a submenu")
    func chevronTracksSubmenuOwnership() throws {
        // Arrange
        let assembler = Graphed.assembler()

        // Act
        let menu = assembler.assemble(MenuModel(rows: [
            .course(Graphed.graphedWithSubmenu),
            .course(Graphed.plain),
        ]))

        // Assert
        try #require(menu.items.count == 2)
        try #require(menu.items[0].submenu != nil)
        try #require(menu.items[1].submenu == nil)
        #expect(try component(titled: Graphed.graphedTitle, in: menu).showsChevron == true)
        #expect(try component(titled: Graphed.plainTitle, in: menu).showsChevron == false)
    }

    /// The count invariant, in the model shape that used to grow an extra item per
    /// graphed course: one item per row, no matter which courses have cells.
    @Test("a mixed model assembles to exactly one item per row")
    func mixedModelAssemblesOneItemPerRow() throws {
        // Arrange
        let assembler = Graphed.assembler()
        let model = MenuModel(rows: [
            .sectionHeader("Fall 2026"),
            .course(Graphed.graphed),
            .course(Graphed.plain),
            .separator,
            .status(.nextRefresh(.distantFuture)),
            .command(.refresh),
            .command(.quit),
        ])

        // Act
        let menu = assembler.assemble(model)

        // Assert — the row-for-row shape, and the components only where courses are.
        try #require(menu.items.count == model.rows.count, "an extra item was added somewhere")
        #expect(menu.items[0].title == "Fall 2026")
        #expect(menu.items[1].title == Graphed.graphedTitle)
        #expect(menu.items[2].title == Graphed.plainTitle)
        #expect(menu.items[3].isSeparatorItem)
        #expect(menu.items[5].title == "Refresh")
        #expect(components(in: menu).count == 2, "components appeared on rows that are not courses")
    }

    /// The all-ungraphed model is what the other ~384 tests assemble. Item count
    /// must be untouched by this slice — and every course must still be a component.
    @Test("an all-ungraphed model keeps one item per row and still components its courses")
    func ungraphedModelKeepsItsShape() throws {
        // Arrange
        let assembler = Graphed.assembler()
        let model = Graphed.interleavedUngraphed

        // Act
        let menu = assembler.assemble(model)

        // Assert
        #expect(menu.items.count == model.rows.count)
        #expect(components(in: menu).count == 2)
    }

    /// The whole-menu form of priority 2: the actionable rows are still exactly the
    /// courses and the commands. Nothing new became clickable, and — the risk that
    /// replaces the old inert strip — no course quietly stopped being clickable.
    @Test("the component rows do not change which rows are actionable")
    func componentsChangeNothingActionable() throws {
        // Arrange
        let assembler = Graphed.assembler()
        let expectedActionable: Set<String> = [
            Graphed.graphedTitle, Graphed.plainTitle, "Refresh", "Quit",
        ]

        // Act
        let menu = assembler.assemble(MenuModel(rows: [
            .sectionHeader("Fall 2026"),
            .course(Graphed.graphed),
            .course(Graphed.plain),
            .separator,
            .status(.nextRefresh(.distantFuture)),
            .command(.refresh),
            .command(.quit),
        ]))

        // Assert
        let actuallyActionable = Set(menu.items.filter { $0.action != nil }.map(\.title))
        #expect(actuallyActionable == expectedActionable)
    }

    /// The retired shape, asserted as absent rather than merely unmentioned: the
    /// separate strip item and the class behind it are gone, so a half-done port
    /// that adds the component AND keeps the strip fails here instead of shipping
    /// a duplicated graph.
    @Test("no menu item carries a stray view that is not a component")
    func noStrayViewBearingItems() throws {
        // Arrange
        let assembler = Graphed.assembler()

        // Act
        let menu = assembler.assemble(MenuModel(rows: [
            .course(Graphed.graphed), .course(Graphed.plain), .command(.quit),
        ]))

        // Assert
        let viewBearing = menu.items.filter { $0.view != nil }
        #expect(viewBearing.count == 2, "a view-backed item exists that is not one of the two courses")
        #expect(viewBearing.allSatisfy { $0.view is MenuItemHostingView })
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// PRIORITY 2 — Hover unity: the highlight signal the assembler now owns
// ═════════════════════════════════════════════════════════════════════════════

@MainActor
@Suite("MenuAssembler — highlight plumbing")
struct MenuAssemblerHighlightTests {

    /// `NSMenu.delegate` is a WEAK reference. If the assembler builds a delegate
    /// and lets it go, this is nil by the time anyone hovers — and the app shows a
    /// menu whose rows never highlight, with nothing in any log to say why.
    @Test("the assembled menu keeps a delegate alive")
    func assembledMenuRetainsItsDelegate() throws {
        // Arrange
        let assembler = Graphed.assembler()

        // Act
        let menu = assembler.assemble(MenuModel(rows: [.course(Graphed.graphed)]))

        // Assert
        #expect(menu.delegate != nil, "NSMenu.delegate is weak — the assembler must retain the delegate")
    }

    /// Hover unity itself, headless: the hovered row's component knows it is
    /// highlighted, so title and cells draw their highlighted selves together.
    @Test("highlighting a course tells that course's component it is highlighted")
    func highlightingACourseFlagsItsComponent() throws {
        // Arrange
        let assembler = Graphed.assembler()
        let menu = assembler.assemble(MenuModel(rows: [.course(Graphed.graphed), .course(Graphed.plain)]))
        let hovered = try item(titled: Graphed.graphedTitle, in: menu)

        // Act
        try highlight(hovered, in: menu)

        // Assert
        #expect(try component(titled: Graphed.graphedTitle, in: menu).isHighlightedForMenu == true)
    }

    /// The other half, and the one that produces the visible bug when it is missed:
    /// `willHighlight` fires once per CHANGE, so a delegate that only ever sets the
    /// new row true leaves every previously hovered row lit as the pointer travels.
    @Test("highlighting one course clears the highlight on every other component")
    func highlightingOneCourseClearsTheRest() throws {
        // Arrange
        let assembler = Graphed.assembler()
        let menu = assembler.assemble(MenuModel(rows: [.course(Graphed.graphed), .course(Graphed.plain)]))
        try highlight(try item(titled: Graphed.graphedTitle, in: menu), in: menu)

        // Act — the pointer moves on to the next course.
        try highlight(try item(titled: Graphed.plainTitle, in: menu), in: menu)

        // Assert
        #expect(try component(titled: Graphed.plainTitle, in: menu).isHighlightedForMenu == true)
        #expect(
            try component(titled: Graphed.graphedTitle, in: menu).isHighlightedForMenu == false,
            "the previously hovered course is still lit, so two rows look selected at once"
        )
    }

    /// The pointer leaves the menu's rows entirely. AppKit signals that with a nil
    /// item, and a delegate that force-unwraps or early-returns leaves the last row
    /// stuck highlighted.
    @Test("highlighting nothing clears every component")
    func highlightingNilClearsEveryComponent() throws {
        // Arrange
        let assembler = Graphed.assembler()
        let menu = assembler.assemble(MenuModel(rows: [.course(Graphed.graphed), .course(Graphed.plain)]))
        try highlight(try item(titled: Graphed.graphedTitle, in: menu), in: menu)

        // Act
        try highlight(nil, in: menu)

        // Assert
        #expect(components(in: menu).allSatisfy { !$0.isHighlightedForMenu })
    }

    /// Hovering a native row — a command — must also clear the components. The
    /// native row highlights itself; nobody tells the components to stand down
    /// unless the delegate handles every item, not just the ones with views.
    @Test("highlighting a native row clears every component")
    func highlightingANativeRowClearsComponents() throws {
        // Arrange
        let assembler = Graphed.assembler()
        let menu = assembler.assemble(MenuModel(rows: [.course(Graphed.graphed), .command(.quit)]))
        try highlight(try item(titled: Graphed.graphedTitle, in: menu), in: menu)

        // Act
        try highlight(try item(titled: "Quit", in: menu), in: menu)

        // Assert
        #expect(components(in: menu).allSatisfy { !$0.isHighlightedForMenu })
    }

    /// Components start unhighlighted. A component built already lit renders a menu
    /// that opens with a row selected under no pointer.
    @Test("a freshly assembled menu has no highlighted component")
    func freshMenuHasNoHighlight() throws {
        // Arrange / Act
        let assembler = Graphed.assembler()
        let menu = assembler.assemble(MenuModel(rows: [.course(Graphed.graphed), .course(Graphed.plain)]))

        // Assert
        try #require(components(in: menu).count == 2)
        #expect(components(in: menu).allSatisfy { !$0.isHighlightedForMenu })
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// PRIORITY 2 — The row is actually visible: frame, the failure with no tell
// ═════════════════════════════════════════════════════════════════════════════

@MainActor
@Suite("MenuAssembler — the component is visible")
struct MenuAssemblerComponentFrameTests {

    /// A component left at `.zero` is an invisible row: the course silently
    /// vanishes from the menu, which is indistinguishable from "that course was
    /// never fetched". `NSMenuItem.view` is not laid out for you, so the size has
    /// to be set at construction.
    @Test("every component has a nonzero frame")
    func everyComponentHasANonzeroFrame() throws {
        // Arrange
        let assembler = Graphed.assembler()

        // Act
        let menu = assembler.assemble(MenuModel(rows: [
            .course(Graphed.graphed), .course(Graphed.plain), .course(Graphed.coded),
        ]))

        // Assert
        let found = components(in: menu)
        try #require(found.count == 3)
        for view in found {
            #expect(view.frame.width > 0, "'\(view.title)' has zero width and cannot be seen")
            #expect(view.frame.height > 0, "'\(view.title)' has zero height and cannot be seen")
        }
    }

    /// The component GROWS for its cells rather than overlaying them on the title
    /// row. Compared against the same course without a graph, so this holds
    /// whatever the chosen metrics are.
    @Test("a graphed component is taller than its ungraphed twin")
    func graphedComponentIsTallerThanUngraphed() throws {
        // Arrange
        let assembler = Graphed.assembler()
        let control = assembler.assemble(MenuModel(rows: [.course(Graphed.ungraphedTwin)]))
        let controlView = try #require(components(in: control).first)

        // Act
        let menu = assembler.assemble(MenuModel(rows: [.course(Graphed.graphed)]))

        // Assert
        let view = try #require(components(in: menu).first)
        #expect(
            view.frame.height > controlView.frame.height,
            "the graphed component is \(view.frame.height)pt, the same as a title-only row — the cells have nowhere to draw"
        )
    }
}
