import AppKit
import Foundation
import Testing

import BrightspaceBar
import CourseMenu

// ═════════════════════════════════════════════════════════════════════════════
// MenuAssembler — the course activity graph strip.
//
// PRIORITIES (the 1–2 carrying 80% of the value):
//
//   1. THE STRIP IS PURELY ADDITIVE. It is one extra menu item wedged in after a
//      course row, which is exactly the change that breaks everything around it:
//      every course now occupies TWO item slots, so an implementation that maps
//      clicks or structure by position sends the user to the wrong class, and a
//      course that gains a graph must not lose its title, its click, or its
//      submenu. A course with no graph must reproduce the pre-graph menu shape
//      byte for byte — 355 tests currently depend on that, and they build
//      `CourseRow`s that default to `graph == []`.
//
//   2. THE STRIP IS INERT AND CANNOT BE ACTIVATED. A view-bearing item is the
//      first item in this menu that is not a plain label, and it sits directly
//      under a course. If it carries an action it is wired to the course action
//      with no course behind it — it opens garbage — and if it is merely enabled
//      it looks like a clickable row that does nothing. `action == nil` is the
//      load-bearing half; `isEnabled == false` is the half that makes it look
//      inert, and it only survives because `MenuAssembler` sets
//      `autoenablesItems = false` (AppKit would otherwise re-enable it at display
//      time, which no headless test can observe).
//
// CULLED, deliberately: everything about how the strip LOOKS. Fill colour per
// `CellTier`, the today outline, palette-per-appearance, and the invariant that
// the outline must not obscure the fill are all verified VISUALLY under
// `BRIGHTSPACEBAR_STUB=1`, where the expected picture is known in advance
// (NewVertical-2.md, decisions §2 and §5). They are unassertable here: this
// process has no window, never displays a menu, and never calls `draw(_:)`.
// What IS testable headless — and therefore what is tested — is the geometry,
// because it lives in a pure layout enum with no drawing in it. Also culled:
// hover/highlight state (AppKit's), performance (~6 courses × 28 cells is
// nothing — see §5 on why the RepoBar raster engine is not ported), and the
// date→cell mapping (that is MenuAdapter's, tested there).
//
// SCOPE: all Google-small. In-process AppKit object graphs and pure arithmetic;
// no I/O, no network, no clock, no window, no display.
// ═════════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────
// PINNED STRUCTURE AND GEOMETRY — the builder implements exactly this.
//
// A `.course` row whose `graph` is NON-EMPTY produces TWO items at the same menu
// level, in this order:
//
//   [n]   the course item, entirely unchanged — same title, action,
//         representedObject, and submenu as it would have with no graph
//   [n+1] the strip item: title "", action nil, isEnabled false,
//         representedObject nil, `view` = GraphStripView(cells: course.graph)
//
// A `.course` row whose `graph` is EMPTY produces ONE item and nothing else.
// The strip never appears inside a submenu (§ "Graph Placement": the strip is a
// line of its own under the course name, at the course's level).
//
// Both types must be `public`: this target does a plain `import BrightspaceBar`,
// not `@testable import`, matching the rest of the suite.
//
//     public final class GraphStripView: NSView {
//         public let cells: [GraphCell]
//         public init(cells: [GraphCell])
//     }
//
//     public enum GraphStripLayout {
//         public static let cellSide: CGFloat = 8
//         public static let spacing: CGFloat = 2
//         public static let padding: CGFloat = 14   // menu item text inset
//         public static func rects(count: Int, in bounds: CGRect) -> [CGRect]
//         public static func size(count: Int) -> CGSize
//     }
//
// Cell `i` sits at x = padding + i × (cellSide + spacing), is cellSide square,
// and shares its y with every other cell — it is one strip, not a grid.
//
// ONE ADDITION to the handed-down policy, flagged as such: the strip view's
// `frame.size` must equal `GraphStripLayout.size(count:)`. An `NSMenuItem.view`
// is not laid out for you the way a subview of a window is; left at `.zero` the
// strip is simply invisible, which is a shipping bug that looks identical to
// "the graph is empty". Pinning the frame is the only headless way to catch it.
// ─────────────────────────────────────────────────────────────────────────────

/// The expected geometry, written out as literals rather than read from
/// `GraphStripLayout`, so a wrong constant in the implementation cannot define
/// its own expected value. The first test asserts the two copies agree; the rest
/// derive from this one.
///
/// Every value here is a small integer, so the `CGFloat` arithmetic below is
/// exact in binary floating point and `==` is the right comparison.
private enum Pinned {
    static let cellSide: CGFloat = 8
    static let spacing: CGFloat = 2
    static let padding: CGFloat = 14

    /// Four weeks of upcoming days — the span the strip is sized for, and enough
    /// cells that an accumulated-offset bug diverges visibly from a multiplied one.
    static let cellCount = 28

    /// Where cell `index` starts, stated the way the spec states it.
    static func x(_ index: Int) -> CGFloat {
        self.padding + CGFloat(index) * (self.cellSide + self.spacing)
    }

    /// A menu-item-shaped canvas: wide enough for 28 cells, and the height of a
    /// real menu row rather than a snug fit, so vertical placement has somewhere
    /// to go wrong.
    static let bounds = CGRect(x: 0, y: 0, width: 400, height: 22)
}

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

    /// A course that never gets a strip. Its presence in every mixed model is what
    /// proves the extra item is attached to the graphed course specifically, and
    /// not simply appended after every course.
    static var plain: CourseRow {
        CourseRow(id: Self.plainID, title: Self.plainTitle, url: Self.courseURL(Self.plainID))
    }

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

    /// The full shape: a course that has BOTH a submenu and a graph. The strip
    /// belongs beside it at the top level; the submenu keeps its own contents.
    static var graphedWithSubmenu: CourseRow {
        CourseRow(
            id: Self.graphedID, title: Self.graphedTitle, url: Self.courseURL(Self.graphedID),
            submenu: Self.assignments.map { MenuRow.assignment($0) },
            graph: Self.strip
        )
    }

    /// The real model shape, with every course ungraphed — byte for byte the menu
    /// that shipped before this feature existed.
    static var interleavedUngraphed: MenuModel {
        MenuModel(rows: [
            .sectionHeader("Fall 2026"),
            .course(Graphed.ungraphedTwin),
            .course(Graphed.plain),
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

/// Every strip view in a menu, in item order. Deliberately reads `view` rather
/// than looking for an empty title or a disabled row: carrying the strip is the
/// item's whole purpose, so that is how a strip is identified.
@MainActor
private func strips(in menu: NSMenu) -> [GraphStripView] {
    menu.items.compactMap { $0.view as? GraphStripView }
}

// ═════════════════════════════════════════════════════════════════════════════
// PRIORITY 1 — The strip is additive: placement, ordering, and no collateral damage
// ═════════════════════════════════════════════════════════════════════════════

@MainActor
@Suite("MenuAssembler — graph strip placement")
struct MenuAssemblerGraphPlacementTests {

    @Test("a graphed course is followed by an item carrying its cells")
    func graphedCourseIsFollowedByItsStrip() throws {
        // Arrange
        let assembler = Graphed.assembler()
        let course = Graphed.graphed

        // Act
        let menu = assembler.assemble(MenuModel(rows: [.course(course)]))

        // Assert — `#require` before positional access: indexing NSMenu.items past
        // the end raises an NSException that aborts the whole run rather than
        // failing this one test.
        try #require(menu.items.count == 2)
        #expect(menu.items[0].title == Graphed.graphedTitle)
        let strip = try #require(
            menu.items[1].view as? GraphStripView,
            "the item after the course carries no GraphStripView, so the graph is invisible"
        )
        #expect(strip.cells == course.graph)
    }

    /// The strip renders the model's cells verbatim — it does not re-derive,
    /// re-order, or truncate them. Today's cell keeps its tier, which is the
    /// data-side half of "the today indicator must not obscure the activity state".
    @Test("the strip carries every cell, in model order, with tier and isToday intact")
    func stripCarriesCellsVerbatim() throws {
        // Arrange
        let assembler = Graphed.assembler()

        // Act
        let menu = assembler.assemble(MenuModel(rows: [.course(Graphed.graphed)]))

        // Assert — the literal strip, written independently of any mapping code.
        let strip = try #require(strips(in: menu).first)
        #expect(strip.cells.count == 5)
        #expect(strip.cells == [
            GraphCell(tier: .assignment, isToday: true),
            GraphCell(tier: nil),
            GraphCell(tier: .quiz),
            GraphCell(tier: nil),
            GraphCell(tier: .assignment),
        ])
    }

    /// The legacy guarantee. Every `CourseRow` built by hand — in the other 355
    /// tests, in the stub, in the translation layer's existing output — defaults to
    /// `graph == []`, so an implementation that appends a strip unconditionally
    /// would shift every one of those menus by one item per course.
    @Test("a course with an empty graph adds no item")
    func emptyGraphAddsNoItem() throws {
        // Arrange
        let assembler = Graphed.assembler()
        let model = Graphed.interleavedUngraphed

        // Act
        let menu = assembler.assemble(model)

        // Assert — the pre-graph shape: exactly one item per model row, and not a
        // single view-bearing item anywhere.
        #expect(menu.items.count == model.rows.count)
        #expect(strips(in: menu).isEmpty, "a strip was added to a course whose graph is empty")
    }

    /// The ordering hazard in one model: with a graphed course, an ungraphed one, a
    /// separator and a command, item index and row index diverge from item 1 onward.
    @Test("the strip lands directly after its own course and nowhere else")
    func stripLandsAfterItsOwnCourse() throws {
        // Arrange
        let assembler = Graphed.assembler()
        let model = MenuModel(rows: [
            .course(Graphed.graphed),
            .course(Graphed.plain),
            .separator,
            .command(.refresh),
        ])

        // Act
        let menu = assembler.assemble(model)

        // Assert — one extra item, in the one right place.
        try #require(menu.items.count == model.rows.count + 1)
        #expect(menu.items[0].title == Graphed.graphedTitle)
        #expect(menu.items[1].view is GraphStripView)
        #expect(menu.items[2].title == Graphed.plainTitle)
        #expect(menu.items[3].isSeparatorItem)
        #expect(menu.items[4].title == "Refresh")
        #expect(strips(in: menu).count == 1, "expected exactly one strip for one graphed course")
    }

    /// Two graphed courses: each gets its own strip carrying its OWN cells. An
    /// implementation that builds one strip per menu, or reuses the first course's
    /// cells, passes every single-course test above and fails here.
    @Test("each graphed course gets its own strip carrying its own cells")
    func eachGraphedCourseGetsItsOwnStrip() throws {
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
        let found = strips(in: menu)
        try #require(found.count == 2)
        #expect(found[0].cells == Graphed.strip)
        #expect(found[1].cells == second.graph)
    }

    /// The strip is a line of its own UNDER the course name, at the course's own
    /// level — never a row inside the hover submenu, where it would be unreachable
    /// without hovering and would collide with the assignment rows.
    @Test("the strip does not appear inside the course's submenu")
    func stripIsNotInsideTheSubmenu() throws {
        // Arrange
        let assembler = Graphed.assembler()
        let menu = assembler.assemble(MenuModel(rows: [.course(Graphed.graphedWithSubmenu)]))

        // Act
        let sub = try #require(
            menu.items.first?.submenu,
            "the graphed course lost its submenu, so its assignments are unreachable"
        )

        // Assert — the submenu holds exactly what it held before graphs existed:
        // course-home, separator, one item per assignment. No view-bearing row.
        #expect(strips(in: sub).isEmpty, "the strip was rendered inside the submenu")
        #expect(sub.items.count == 2 + Graphed.assignments.count)
        #expect(strips(in: menu).count == 1, "the strip is missing from the top level")
    }

    /// Assembling twice must not depend on hidden mutable state, and — because an
    /// `NSView` can have only one superview just as an `NSMenuItem` can belong to
    /// only one `NSMenu` — a reused strip view would silently detach from the
    /// previously built menu.
    @Test("a rebuilt menu does not share strip view instances with the previous one")
    func rebuildDoesNotShareStripViews() throws {
        // Arrange
        let assembler = Graphed.assembler()
        let model = MenuModel(rows: [.course(Graphed.graphed)])

        // Act
        let first = assembler.assemble(model)
        let second = assembler.assemble(model)

        // Assert — count guards first, else the comparison is satisfied trivially.
        let firstStrip = try #require(strips(in: first).first)
        let secondStrip = try #require(strips(in: second).first)
        #expect(firstStrip !== secondStrip, "the same GraphStripView instance is in both menus")
        #expect(firstStrip.cells == secondStrip.cells)
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// PRIORITY 1 — The course item itself survives having a graph
// ═════════════════════════════════════════════════════════════════════════════

@MainActor
@Suite("MenuAssembler — graphed courses stay themselves")
struct MenuAssemblerGraphedCourseTests {

    /// Checked against a CONTROL — the same course assembled without a graph —
    /// rather than against a re-stated expectation, so this cannot drift away from
    /// whatever the pre-graph behaviour actually is.
    @Test("the course item is byte-for-byte what it would be without a graph")
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
        #expect(item.view == nil, "the strip was attached to the course item instead of its own row")
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

    /// The strip sits between two courses, so a click resolved by item position
    /// rather than by the item's own `representedObject` opens the neighbour.
    @Test("a course after a strip still opens its own URL, not its neighbour's")
    func courseAfterAStripRoutesCorrectly() throws {
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

    /// The strip must not become a second, invisible submenu anchor. An item that
    /// owns a submenu is non-actionable and grows a hover arrow — on a blank row
    /// that reads as a rendering glitch.
    @Test("the strip item owns no submenu")
    func stripItemHasNoSubmenu() throws {
        // Arrange
        let assembler = Graphed.assembler()

        // Act
        let menu = assembler.assemble(MenuModel(rows: [.course(Graphed.graphedWithSubmenu)]))

        // Assert
        try #require(menu.items.count == 2)
        #expect(menu.items[1].submenu == nil)
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// PRIORITY 2 — The strip item is inert
// ═════════════════════════════════════════════════════════════════════════════

@MainActor
@Suite("MenuAssembler — the strip is inert")
struct MenuAssemblerGraphInertTests {

    /// `action == nil` is the load-bearing assertion: an item with no action can
    /// never be activated whatever `isEnabled` says. `isEnabled == false` is
    /// asserted too because it is what makes the row *look* inert, and it only
    /// holds in the real app because `MenuAssembler` turns `autoenablesItems` off —
    /// with autoenabling on, AppKit recomputes enablement at display time and this
    /// headless suite, which never displays a menu, would never notice.
    @Test("the strip item is neither enabled nor actionable")
    func stripItemIsNotSelectable() throws {
        // Arrange
        let assembler = Graphed.assembler()

        // Act
        let menu = assembler.assemble(MenuModel(rows: [.course(Graphed.graphed)]))

        // Assert
        try #require(menu.items.count == 2)
        let strip = menu.items[1]
        #expect(strip.action == nil, "the strip carries an action and can be activated")
        #expect(strip.isEnabled == false, "the strip is enabled and looks clickable")
    }

    /// An empty title, not a placeholder. Anything else prints text next to the
    /// cells; a reused course title prints the course name twice.
    @Test("the strip item has no title")
    func stripItemHasNoTitle() throws {
        // Arrange
        let assembler = Graphed.assembler()

        // Act
        let menu = assembler.assemble(MenuModel(rows: [.course(Graphed.graphed)]))

        // Assert
        try #require(menu.items.count == 2)
        #expect(menu.items[1].title.isEmpty, "the strip item renders the text '\(menu.items[1].title)'")
    }

    /// The specific disaster: a strip wired to the course action but carrying no
    /// course would open garbage. Carrying no `representedObject` at all is what
    /// makes that unreachable even if an action were added by mistake later.
    @Test("the strip item carries no represented object")
    func stripItemCarriesNoRepresentedObject() throws {
        // Arrange
        let assembler = Graphed.assembler()

        // Act
        let menu = assembler.assemble(MenuModel(rows: [.course(Graphed.graphed)]))

        // Assert
        try #require(menu.items.count == 2)
        #expect(menu.items[1].representedObject == nil)
    }

    /// The whole-menu form of priority 2, and the one that would catch a strip
    /// wired up by a future edit: in a realistic model, the only actionable rows
    /// are still the courses and the commands.
    @Test("adding graphs does not make anything new actionable")
    func graphsAddNoActionableRows() throws {
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
            .status("Updated just now"),
            .command(.refresh),
            .command(.quit),
        ]))

        // Assert
        let actuallyActionable = Set(menu.items.filter { $0.action != nil }.map(\.title))
        #expect(actuallyActionable == expectedActionable)
    }

    /// A strip left at `.zero` is invisible, and an invisible strip is
    /// indistinguishable from a course with no work due — the failure this whole
    /// feature exists to make visible. `NSMenuItem.view` is not laid out for you,
    /// so the size has to be set at construction.
    @Test("the strip view is sized to hold its cells")
    func stripViewIsSizedForItsCells() throws {
        // Arrange
        let assembler = Graphed.assembler()

        // Act
        let menu = assembler.assemble(MenuModel(rows: [.course(Graphed.graphed)]))

        // Assert
        let strip = try #require(strips(in: menu).first)
        #expect(strip.frame.size == GraphStripLayout.size(count: Graphed.strip.count))
        #expect(strip.frame.width > 0, "the strip view has zero width and cannot be seen")
        #expect(strip.frame.height > 0, "the strip view has zero height and cannot be seen")
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// GraphStripLayout — the pure geometry, which is the only drawing-adjacent thing
// this headless process can make a claim about
// ═════════════════════════════════════════════════════════════════════════════

@MainActor
@Suite("GraphStripLayout")
struct GraphStripLayoutTests {

    /// Pins the constants themselves. Every other test in this suite derives its
    /// expected values from `Pinned`, so without this one an implementation could
    /// satisfy them all with a self-consistent but wrong pitch. `padding` is 14
    /// because that is the menu item text inset — the strip has to line up with the
    /// course name above it.
    @Test("the layout constants are the pinned values")
    func layoutConstantsArePinned() {
        // Arrange / Act — the constants are the subject.
        // Assert
        #expect(GraphStripLayout.cellSide == Pinned.cellSide)
        #expect(GraphStripLayout.spacing == Pinned.spacing)
        #expect(GraphStripLayout.padding == Pinned.padding)
    }

    @Test("one rect per cell")
    func onePerCell() {
        // Arrange / Act
        let rects = GraphStripLayout.rects(count: Pinned.cellCount, in: Pinned.bounds)

        // Assert
        #expect(rects.count == Pinned.cellCount)
    }

    /// The arithmetic, stated independently: cell `i` starts one pitch further
    /// right than cell `i-1`, and the first starts at the text inset.
    @Test("cells run left to right at the pinned pitch, starting at the padding")
    func cellsRunLeftToRightAtThePinnedPitch() throws {
        // Arrange / Act
        let rects = GraphStripLayout.rects(count: Pinned.cellCount, in: Pinned.bounds)

        // Assert — count guard first, else the loop passes vacuously.
        try #require(rects.count == Pinned.cellCount)
        for (index, rect) in rects.enumerated() {
            #expect(rect.minX == Pinned.x(index), "cell \(index) starts at \(rect.minX)")
        }
        #expect(rects.first?.minX == Pinned.padding)
        #expect(rects.last?.minX == Pinned.padding + 27 * (Pinned.cellSide + Pinned.spacing))
    }

    @Test("every cell is a cellSide square")
    func everyCellIsASquare() throws {
        // Arrange / Act
        let rects = GraphStripLayout.rects(count: Pinned.cellCount, in: Pinned.bounds)

        // Assert
        try #require(rects.count == Pinned.cellCount)
        for (index, rect) in rects.enumerated() {
            #expect(rect.width == Pinned.cellSide, "cell \(index) is \(rect.width) wide")
            #expect(rect.height == Pinned.cellSide, "cell \(index) is \(rect.height) tall")
        }
    }

    /// Overlapping cells read as a solid bar with no day boundaries — the graph
    /// stops carrying information. The gap between neighbours is exactly `spacing`.
    @Test("neighbouring cells never overlap")
    func cellsNeverOverlap() throws {
        // Arrange / Act
        let rects = GraphStripLayout.rects(count: Pinned.cellCount, in: Pinned.bounds)

        // Assert
        try #require(rects.count == Pinned.cellCount)
        for index in 1..<rects.count {
            let gap = rects[index].minX - rects[index - 1].maxX
            #expect(gap == Pinned.spacing, "cells \(index - 1) and \(index) are \(gap) apart")
        }
    }

    /// A strip, not a grid: the whole point of the chosen orientation is one row,
    /// so a layout that wraps onto a second line is a different feature.
    @Test("every cell shares one baseline")
    func everyCellSharesOneBaseline() throws {
        // Arrange / Act
        let rects = GraphStripLayout.rects(count: Pinned.cellCount, in: Pinned.bounds)

        // Assert
        try #require(!rects.isEmpty)
        #expect(Set(rects.map(\.origin.y)).count == 1, "the cells are on more than one row")
    }

    @Test("every cell sits inside the bounds it was laid out in")
    func cellsStayInsideTheBounds() throws {
        // Arrange / Act
        let rects = GraphStripLayout.rects(count: Pinned.cellCount, in: Pinned.bounds)

        // Assert
        try #require(rects.count == Pinned.cellCount)
        for (index, rect) in rects.enumerated() {
            #expect(Pinned.bounds.contains(rect), "cell \(index) at \(rect) escapes \(Pinned.bounds)")
        }
    }

    /// `size(count:)` is what the view's frame is set from, so a size that does not
    /// reach the last cell clips the far end of the strip — the days furthest out,
    /// silently.
    @Test("the fitting size reaches past the last cell")
    func fittingSizeContainsTheLastCell() throws {
        // Arrange
        let size = GraphStripLayout.size(count: Pinned.cellCount)

        // Act
        let rects = GraphStripLayout.rects(count: Pinned.cellCount, in: CGRect(origin: .zero, size: size))

        // Assert
        let last = try #require(rects.last)
        #expect(size.width >= last.maxX, "the strip is \(size.width) wide but ends at \(last.maxX)")
        #expect(size.width >= Pinned.x(Pinned.cellCount - 1) + Pinned.cellSide)
        #expect(size.height >= Pinned.cellSide)
    }

    /// The degenerate input, and a real one: a course with no upcoming work has an
    /// empty graph, and `MenuAssembler` is free to ask for its layout anyway.
    /// Anything that divides by, or indexes with, the count must survive zero.
    @Test("zero cells produce no rects")
    func zeroCellsProduceNoRects() {
        // Arrange / Act
        let rects = GraphStripLayout.rects(count: 0, in: Pinned.bounds)

        // Assert
        #expect(rects.isEmpty)
    }

    /// One cell is the other end of the same edge: no neighbours means no pitch to
    /// apply, and an implementation that subtracts a trailing gap can land wrong.
    @Test("a single cell sits at the padding")
    func singleCellSitsAtThePadding() throws {
        // Arrange / Act
        let rects = GraphStripLayout.rects(count: 1, in: Pinned.bounds)

        // Assert
        try #require(rects.count == 1)
        #expect(rects[0].minX == Pinned.padding)
        #expect(rects[0].width == Pinned.cellSide)
    }
}
