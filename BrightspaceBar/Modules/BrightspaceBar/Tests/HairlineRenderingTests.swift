import AppKit
import Foundation
import Testing

import BrightspaceBar
import CourseMenu

// ═════════════════════════════════════════════════════════════════════════════
// MenuAssembler — rendering a `.hairline` row (NewVertical-3.md §3.1).
//
// §3.1's anatomy: "A 1pt line, inset ~14pt from both edges, centred inside its own
// short inert row (≈10pt tall) — the ChatGPT/RepoBar anatomy." The reason the row
// exists at all is in the tradeoff table: row height IS the padding, and because
// the row is disabled, HOVER SKIPS IT — an in-component line would sit inside the
// capsule and have to be hidden while highlighted.
//
// PRIORITIES (the 1–2 carrying 80% of the value):
//
//   1. THE BOUNDARY IS INERT. This is the property the whole design rests on. A
//      hairline that is enabled, or carries an action, becomes a hoverable row
//      between every pair of courses — a highlighted empty band the user can click
//      — and the "Hover: row is disabled; hover skips it" advantage evaporates.
//      Inertness here means all of: no action, `isEnabled == false`, no
//      represented object, no submenu, and no title to read out.
//
//   2. THE ROW IS ACTUALLY VISIBLE. An `NSMenuItem.view` is NOT laid out for you.
//      A view left at `.zero` renders an invisible row, which is a shipping bug
//      that looks exactly like "the boundary feature didn't land" — and it is the
//      same failure mode `MenuItemHostingView` already had to guard against.
//
// CULLED — deliberately, and this is the important cull: NO PIXEL COLOURS. §3.1's
// measured caveat is that `NSColor.separatorColor` renders near-white in dark
// menus, so the real port needs a DYNAMIC colour via
// `NSColor(name:dynamicProvider:)`. A test that sampled RGB components would have
// to pick an appearance to resolve under, would pin one of two arbitrary greys as
// "the" answer, and would fail on a legitimate palette tweak. This process has no
// window and never calls `draw(_:)`. These tests therefore touch only the
// observable STRUCTURE — class, frame, and the menu item's inertness — and the
// line's colour, thickness and inset are verified VISUALLY under
// `BRIGHTSPACEBAR_STUB=1`, in both appearances, which is also the only way to
// check the caveat the design actually cares about.
//
// SCOPE: all Google-small. In-process AppKit object graphs; no I/O, no window.
// ═════════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────
// PINNED RENDERING — the builder implements exactly this.
//
// In `Modules/BrightspaceBar/Sources`:
//
//     public final class HairlineRowView: NSView { }
//
// `public`, because this target does a plain `import BrightspaceBar`, matching the
// rest of the suite.
//
// `MenuAssembler.items(for:)` gains one case, producing exactly ONE item:
//
//     case .hairline:
//         title ""            — nothing to read, nothing for a lookup to collide with
//         action nil          — cannot be activated
//         isEnabled false     — looks and behaves inert; hover skips it
//         representedObject nil
//         submenu nil
//         view = HairlineRowView, frame.height == 10, frame.width > 0
//
// The view draws a 1pt line, inset 14 from each edge, vertically centred, in a
// DYNAMIC grey built with `NSColor(name:dynamicProvider:)` — darker in light mode,
// mid-grey in dark. NOT `NSColor.separatorColor` (§3.1's measured caveat).
// ─────────────────────────────────────────────────────────────────────────────

private enum Boundary {
    /// §3.1's "≈10pt tall" row, pinned to the exact number the builder implements.
    static let rowHeight: CGFloat = 10

    @MainActor
    static func assembler() -> MenuAssembler {
        MenuAssembler(opener: FakeURLOpener(), onCommand: { _ in })
    }

    static func course(id: Int) -> CourseRow {
        CourseRow(
            id: id, title: "Course \(id)", subtitle: "C \(id)",
            url: URL(string: "https://purdue.brightspace.com/d2l/home/\(id)")!
        )
    }
}

@MainActor
@Suite("MenuAssembler — the hairline row")
struct HairlineRenderingTests {

    // ── Priority 1: the boundary is inert ────────────────────────────────────

    @Test("a hairline row cannot be activated")
    func hairlineCarriesNoAction() throws {
        // Arrange
        let menu = Boundary.assembler().assemble(MenuModel(rows: [.hairline]))

        // Assert — `#require` before positional access: indexing NSMenu.items past
        // the end raises an ObjC exception that aborts the whole run.
        try #require(menu.items.count == 1)
        let item = menu.items[0]
        #expect(item.action == nil)
        #expect(item.representedObject == nil)
        #expect(item.submenu == nil)
    }

    @Test("a hairline row is disabled, so hover skips it")
    func hairlineIsDisabled() throws {
        // Arrange — `action == nil` alone is not enough: with autoenabling on,
        // AppKit recomputes `isEnabled` at display time, so the flag has to be set
        // explicitly for the row to stay inert in the real app.
        let menu = Boundary.assembler().assemble(MenuModel(rows: [.hairline]))

        // Assert
        try #require(menu.items.count == 1)
        #expect(menu.items[0].isEnabled == false)
    }

    @Test("a hairline row has no title")
    func hairlineHasNoTitle() throws {
        // Arrange — the view draws the line; there is nothing to say. An empty
        // title also keeps boundaries out of the title-based lookups that the rest
        // of the suite finds rows by.
        let menu = Boundary.assembler().assemble(MenuModel(rows: [.hairline]))

        // Assert
        try #require(menu.items.count == 1)
        #expect(menu.items[0].title.isEmpty)
    }

    @Test("a hairline is not rendered as a native separator")
    func hairlineIsNotASeparatorItem() throws {
        // Arrange — the distinction the whole slice rests on. A native separator
        // is the footer's boundary and reads near-white in dark menus (§3.1's
        // measured caveat); this row exists precisely because that is not wanted
        // between courses.
        let menu = Boundary.assembler().assemble(MenuModel(rows: [.hairline, .separator]))

        // Assert
        try #require(menu.items.count == 2)
        #expect(menu.items[0].isSeparatorItem == false)
        #expect(menu.items[1].isSeparatorItem, "the footer separator stopped being native")
    }

    // ── Priority 2: the row is actually visible ──────────────────────────────

    @Test("a hairline row is view-backed by a HairlineRowView")
    func hairlineIsBackedByItsOwnView() throws {
        // Arrange — an ordinary disabled item would draw nothing at all; the line
        // is the view's, so the view has to be there.
        let menu = Boundary.assembler().assemble(MenuModel(rows: [.hairline]))

        // Act
        try #require(menu.items.count == 1)
        let view = try #require(menu.items[0].view, "the hairline row has no view")

        // Assert
        #expect(view is HairlineRowView)
    }

    @Test("the hairline view has the pinned height and a nonzero width")
    func hairlineViewHasARealFrame() throws {
        // Arrange — `.zero` renders an invisible row, and §3.1 pins the height as
        // the padding itself: "Row height *is* the padding".
        let menu = Boundary.assembler().assemble(MenuModel(rows: [.hairline]))
        try #require(menu.items.count == 1)

        // Act
        let view = try #require(menu.items[0].view as? HairlineRowView)

        // Assert
        #expect(view.frame.height == Boundary.rowHeight)
        #expect(view.frame.width > 0, "a zero-width row draws no line")
    }

    // ── Shape: the assembler's one-item-per-row invariant survives ───────────

    @Test("each hairline row produces exactly one item, in order")
    func oneItemPerHairlineRow() throws {
        // Arrange — boundaries interleaved as the translation layer places them.
        let model = MenuModel(rows: [
            .sectionHeader("202610"),
            .hairline, .course(Boundary.course(id: 1)),
            .hairline, .course(Boundary.course(id: 2)),
            .separator,
            .status("Updated just now"),
            .command(.refresh),
            .command(.quit),
        ])

        // Act
        let menu = Boundary.assembler().assemble(model)

        // Assert — the 1:1 mapping every other assembler suite depends on, and the
        // boundaries landing exactly where the model put them.
        try #require(menu.items.count == model.rows.count, "an extra item was added somewhere")
        let hairlineIndices = menu.items.indices.filter { menu.items[$0].view is HairlineRowView }
        #expect(hairlineIndices == [1, 3])
    }

    @Test("hairlines change nothing about which rows are actionable")
    func boundariesAddNothingClickable() throws {
        // Arrange — the risk in whole-menu form: every boundary is a new row
        // between two courses, and a clickable one would sit exactly where a
        // mis-aimed click lands.
        let model = MenuModel(rows: [
            .sectionHeader("202610"),
            .hairline, .course(Boundary.course(id: 1)),
            .hairline, .course(Boundary.course(id: 2)),
            .separator,
            .status("Updated just now"),
            .command(.refresh),
            .command(.quit),
        ])

        // Act
        let menu = Boundary.assembler().assemble(model)
        let actionable = menu.items.filter { $0.action != nil }.map(\.title)

        // Assert
        #expect(actionable == ["C 1 — Course 1", "C 2 — Course 2", "Refresh", "Quit"])
    }

    @Test("no hairline view leaks into a submenu")
    func submenusCarryNoBoundaryViews() throws {
        // Arrange — the model never puts one there; this pins that the assembler
        // does not invent one while building the submenu's leading rows.
        let course = CourseRow(
            id: 1, title: "Data Engineering", subtitle: "CS 17600",
            url: URL(string: "https://purdue.brightspace.com/d2l/home/1")!,
            submenu: [
                .assignment(AssignmentRow(
                    id: 2_001, title: "Project 1",
                    url: URL(string: "https://purdue.brightspace.com/d2l/x?db=2001&ou=1")!
                ))
            ]
        )

        // Act
        let menu = Boundary.assembler().assemble(MenuModel(rows: [.hairline, .course(course)]))
        let sub = try #require(menu.items.last?.submenu, "the course lost its submenu")

        // Assert
        #expect(!sub.items.contains { $0.view is HairlineRowView })
    }
}
