import AppKit
import Foundation
import Testing

import BrightspaceBar
import CourseMenu

// ═════════════════════════════════════════════════════════════════════════════
// THE GRID — a 1-D window read as columns (NewVertical-3.md §3.3, §5, slice 4).
//
// The contract hands the renderer a flat array and a promise: index is the day
// offset from the window start, the window opens on a week boundary, and N is a
// multiple of 7. That promise is everything a grid needs. Turning it into rects
// is pure arithmetic — `column = i / 7`, `row = i % 7`, row 0 at the TOP — and
// pure arithmetic is the half of the renderer that can be pinned headlessly.
//
// PRIORITIES (the 1–2 carrying 80% of the value):
//
//   1. THE CELLS MUST LAND WHERE THE CALENDAR SAYS. A grid whose columns are
//      off by one cell, or whose rows run bottom-up, is still a tidy rectangle
//      of squares — it just files every deadline under the wrong weekday, under
//      a month heading that now lies. Same silent-plausibility failure as the
//      bucketing: there is no crash, no gap, nothing to notice. So the layout is
//      pinned as rects: column-major, row 0 topmost, no overlaps, equal squares,
//      and the whole thing offset by the gutter it must leave for labels.
//
//   2. THE ROW MUST BE TALL ENOUGH TO HOLD IT. `NSMenuItem.view` is not laid out
//      for you — AppKit honours `frame` and computes nothing, so a component
//      still sized for a one-row strip draws a 7-row grid into 8 points and
//      clips six rows away. The failure looks exactly like "not much is due".
//      The strip's height was a single cell; the grid's is seven cells, six
//      gaps and a heading row, and the frame has to grow by all of it.
//
// CULLED, and verified visually in stub mode instead: every pixel colour (the
// tier palette, the white-alpha swap while highlighted), the today outline's
// stroke, the text drawing itself — where the month strings and the weekday
// letters actually paint, their font, their baselines. This file pins the
// numbers a screenshot cannot check, and the screenshot checks what numbers
// cannot.
//
// SCOPE: small. Pure geometry over value inputs, plus one `@MainActor` pass
// through the real assembler for the wiring claim.
// ═════════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────
// PINNED POLICY — the builder implements exactly this.
//
//     public enum ComponentMetrics {
//         public static let cellSide: CGFloat        // 8, unchanged
//         public static let cellGap: CGFloat         // 2, unchanged
//         public static let monthRowHeight: CGFloat  // 12  — new, above the grid
//         public static let weekdayGutter: CGFloat   // 18  — new, left of it
//         public static func gridRects(count: Int, origin: CGPoint) -> [CGRect]
//         public static func fittingSize(cells: Int) -> CGSize   // grows
//     }
//
//     public final class MenuItemHostingView: NSView {
//         public let monthLabels: [String?]   // new; init param last, default []
//     }
//
// `ComponentMetrics` becomes `public`: this target does a plain
// `import BrightspaceBar`, matching every other suite here.
//
// ── gridRects ───────────────────────────────────────────────────────────────
//   `count` cells, laid out COLUMN-MAJOR from `origin`, which is the grid's
//   TOP-LEFT corner. `column = i / 7`, `row = i % 7`. Cell i's rect:
//
//       x = origin.x + column * (cellSide + cellGap)
//       y = origin.y + row    * (cellSide + cellGap)
//       size = cellSide × cellSide
//
//   Rects are in a TOP-LEFT-ORIGIN, y-DOWNWARD space — row 0 has the SMALLEST
//   y. Row 0 is Sunday, at the top, always: §3.3's week-aligned window is what
//   makes that true of every window rather than of this one.
//
//   How the view reconciles that with `NSView`'s bottom-up y — `isFlipped`, or
//   subtracting from `bounds.height` (§5) — is the builder's call and is CULLED
//   from this file. Only the pure function is pinned, because only the pure
//   function can be wrong in a way a screenshot will not show.
//
//   `origin` exists so the caller can reserve the label gutters: the grid does
//   not start at the view's corner, it starts at
//   `(weekdayGutter, monthRowHeight)`.
//
// ── fittingSize, for a graphed course ───────────────────────────────────────
//   height = verticalPad × 2 + titleHeight + rowGap + monthRowHeight
//            + (7 × cellSide + 6 × cellGap)
//   width  = max(minimumWidth, textInset × 2 + weekdayGutter + grid width)
//
//   An UNGRAPHED course (`cells == 0`) is untouched: no heading row, no gutter,
//   no grid. Its height stays `verticalPad × 2 + titleHeight`.
// ─────────────────────────────────────────────────────────────────────────────

/// The metrics, restated as literals. Independent of the production table on
/// purpose: computing the expectation from `ComponentMetrics` the way the code
/// computes it would let a metric be changed and the grid re-blessed in one
/// edit, which is precisely the clipping bug priority 2 exists to catch.
private enum Metric {
    static let cellSide: CGFloat = 8
    static let cellGap: CGFloat = 2
    static let step: CGFloat = 10 // cellSide + cellGap, stated rather than summed

    static let monthRowHeight: CGFloat = 12
    static let weekdayGutter: CGFloat = 18

    static let titleHeight: CGFloat = 17
    static let rowGap: CGFloat = 5
    static let verticalPad: CGFloat = 6
    static let textInset: CGFloat = 14
    static let minimumWidth: CGFloat = 240

    /// Seven cells and the six gaps between them: 7 × 8 + 6 × 2.
    static let gridHeight: CGFloat = 68
    /// Sixteen columns and their fifteen gaps: 16 × 8 + 15 × 2.
    static let gridWidth: CGFloat = 158

    /// 6 × 2 + 17 + 5 + 12 + 68, summed once here and nowhere else.
    static let graphedHeight: CGFloat = 114
    /// 6 × 2 + 17 — a title and its padding, exactly as before this slice.
    static let ungraphedHeight: CGFloat = 29

    static let windowDays = 112
    static let columns = 16
    static let gridOrigin = CGPoint(x: weekdayGutter, y: monthRowHeight)
}

private func window(_ count: Int = Metric.windowDays) -> [GraphCell] {
    Array(repeating: GraphCell(tier: nil), count: count)
}

@Suite("The grid — a flat window read as columns of seven")
struct GraphGridGeometryTests {

    // MARK: - Shape

    @Test("a 112-cell window lays out as 112 rects")
    func everyCellGetsARect() {
        // Arrange / Act
        let rects = ComponentMetrics.gridRects(count: Metric.windowDays, origin: .zero)

        // Assert
        #expect(rects.count == Metric.windowDays)
    }

    @Test("every cell is the same square")
    func cellsAreUniform() {
        // Arrange / Act
        let rects = ComponentMetrics.gridRects(count: Metric.windowDays, origin: .zero)

        // Assert — one non-square or one oversized cell is a grid that reads as
        // emphasis where none was meant.
        #expect(rects.allSatisfy { $0.size == CGSize(width: Metric.cellSide, height: Metric.cellSide) })
    }

    @Test("112 cells occupy exactly sixteen columns")
    func sixteenColumns() {
        // Arrange / Act
        let rects = ComponentMetrics.gridRects(count: Metric.windowDays, origin: .zero)

        // Assert — distinct x positions, which is what a column IS to the eye.
        #expect(Set(rects.map(\.origin.x)).count == Metric.columns)
        #expect(Set(rects.map(\.origin.y)).count == 7)
    }

    /// The claim that catches an off-by-one in either direction at once: two
    /// cells sharing space, or the grid spilling past the width the row asked
    /// for, both show up here and nowhere else.
    @Test("no two cells overlap")
    func cellsDoNotOverlap() {
        // Arrange
        let rects = ComponentMetrics.gridRects(count: Metric.windowDays, origin: .zero)

        // Act
        var overlapping: [String] = []
        for i in rects.indices {
            for j in rects.indices where j > i && rects[j].intersects(rects[i]) {
                overlapping.append("\(i)/\(j)")
            }
        }

        // Assert
        #expect(overlapping.isEmpty, "cells \(overlapping.prefix(3)) overlap")
    }

    // MARK: - Column-major, row 0 at the top

    /// The orientation claim, and the one a bottom-up implementation fails while
    /// still drawing a perfectly tidy 16 × 7 rectangle. Row 0 is Sunday; it must
    /// be the topmost row, which in this top-left space is the smallest y.
    @Test("cell 0 sits at the grid's top-left corner")
    func cellZeroIsTopLeft() {
        // Arrange / Act
        let rects = ComponentMetrics.gridRects(count: Metric.windowDays, origin: .zero)

        // Assert
        #expect(rects[0].origin == .zero)
        #expect(rects[0].origin.y == rects.map(\.origin.y).min())
    }

    /// Column-major: the first SEVEN cells run down, not across. An implementation
    /// that filled rows first would put a week's worth of days side by side and
    /// every weekday label would be wrong from the second cell onwards.
    @Test("the first seven cells run down a single column")
    func theFirstWeekIsAColumn() {
        // Arrange / Act
        let rects = ComponentMetrics.gridRects(count: Metric.windowDays, origin: .zero)

        // Assert
        let firstWeek = rects.prefix(7)
        #expect(Set(firstWeek.map(\.origin.x)).count == 1)
        #expect(firstWeek.map(\.origin.y) == (0..<7).map { CGFloat($0) * Metric.step })
    }

    /// And the wrap: cell 7 is the next Sunday — a new column, back at the top.
    @Test("cell seven starts a new column at the same height as cell zero")
    func theEighthCellWraps() {
        // Arrange / Act
        let rects = ComponentMetrics.gridRects(count: Metric.windowDays, origin: .zero)

        // Assert
        #expect(rects[7].origin.y == rects[0].origin.y)
        #expect(rects[7].origin.x == rects[0].origin.x + Metric.step)
    }

    /// The far corner, stated as a literal: cell 111 is the last day of the
    /// sixteenth column, Saturday. If the arithmetic drifts anywhere across 112
    /// cells, it has drifted by here.
    @Test("the last cell closes the sixteenth column")
    func theLastCellIsTheBottomRight() {
        // Arrange / Act
        let rects = ComponentMetrics.gridRects(count: Metric.windowDays, origin: .zero)

        // Assert — column 15, row 6.
        #expect(rects[111].origin == CGPoint(x: 15 * Metric.step, y: 6 * Metric.step))
        #expect(rects[111].maxX == Metric.gridWidth)
        #expect(rects[111].maxY == Metric.gridHeight)
    }

    // MARK: - The origin is the label gutter

    /// The labels are not decoration around the grid — they push it. A renderer
    /// that drew the grid at the view's corner and the labels over it would look
    /// broken in one specific way: the weekday letters sitting on top of Sunday.
    @Test("the grid is offset whole by its origin, leaving the label gutters")
    func theGridStartsAfterTheGutters() {
        // Arrange
        let atZero = ComponentMetrics.gridRects(count: Metric.windowDays, origin: .zero)

        // Act
        let offset = ComponentMetrics.gridRects(count: Metric.windowDays, origin: Metric.gridOrigin)

        // Assert — every cell moved by the gutter, and by exactly the gutter.
        #expect(offset[0].origin == Metric.gridOrigin)
        #expect(offset.count == atZero.count)
        let shifted: [CGRect] = atZero.map {
            $0.offsetBy(dx: Metric.weekdayGutter, dy: Metric.monthRowHeight)
        }
        #expect(offset == shifted)
    }

    // MARK: - Edges

    @Test("no cells lay out no rects")
    func emptyCountIsEmpty() {
        // Arrange / Act — an ungraphed course reaches the metrics too.
        let rects = ComponentMetrics.gridRects(count: 0, origin: Metric.gridOrigin)

        // Assert
        #expect(rects.isEmpty)
    }

    /// A partial column. The backend cannot emit one — N is a multiple of 7 by
    /// contract — but the layout is a pure function and a total one, and a crash
    /// here would be a crash in the drawing path.
    @Test("a partial final column lays out without spilling into the next one")
    func aPartialColumnStaysInItsColumn() {
        // Arrange / Act — five cells: one column, five deep.
        let rects = ComponentMetrics.gridRects(count: 5, origin: .zero)

        // Assert
        #expect(rects.count == 5)
        #expect(Set(rects.map(\.origin.x)).count == 1)
        #expect(rects[4].origin.y == 4 * Metric.step)
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// PRIORITY 2 — the row is tall enough to hold the grid
// ═════════════════════════════════════════════════════════════════════════════

@Suite("The component grows for the grid")
struct GridFittingSizeTests {

    /// The number, stated. Seven rows and a heading row is not a tweak to the
    /// strip's height, it is roughly four times it, and a component still sized
    /// for one row of cells clips six rows silently.
    @Test("a graphed course asks for the height of seven rows plus a heading row")
    func graphedHeightHoldsTheWholeGrid() {
        // Arrange / Act
        let size = ComponentMetrics.fittingSize(cells: Metric.windowDays)

        // Assert
        #expect(size.height == Metric.graphedHeight)
    }

    /// Stated relatively as well, so the claim survives a deliberate metric
    /// change while still failing on a grid drawn into a strip's height.
    @Test("the extra height is exactly the grid and its heading row")
    func theGrowthIsTheGrid() {
        // Arrange
        let ungraphed = ComponentMetrics.fittingSize(cells: 0)

        // Act
        let graphed = ComponentMetrics.fittingSize(cells: Metric.windowDays)

        // Assert
        #expect(graphed.height - ungraphed.height
            == Metric.rowGap + Metric.monthRowHeight + Metric.gridHeight)
    }

    /// An ungraphed course is untouched by the slice — no heading row, no gutter.
    /// Under always-emit this row barely occurs in production, but the GUI's own
    /// fixtures are full of them and a slice that silently retuned every plain
    /// row would be a slice that changed more than it claimed.
    @Test("an ungraphed course keeps the height it always had")
    func ungraphedHeightIsUnchanged() {
        // Arrange / Act
        let size = ComponentMetrics.fittingSize(cells: 0)

        // Assert
        #expect(size.height == Metric.ungraphedHeight)
    }

    /// The height does not depend on how many cells there are beyond zero: the
    /// grid is always seven rows deep, and a 112-cell window and a 14-cell one
    /// are the same height at different widths. A height that scaled with the
    /// count is the strip's arithmetic left in place.
    @Test("the height is the same for every non-empty window")
    func heightDoesNotScaleWithCellCount() {
        // Arrange / Act / Assert
        for count in [7, 14, 70, Metric.windowDays] {
            #expect(
                ComponentMetrics.fittingSize(cells: count).height == Metric.graphedHeight,
                "\(count) cells asked for a different height"
            )
        }
    }

    /// §5's measurement, as a claim: sixteen weeks plus labels fits a menu of
    /// ordinary width. `14 × 2 + 18 + 158 = 204`, comfortably inside the 240pt
    /// floor — which is why the grid is a width-neutral change and the strip's
    /// 112 cells would have been a 1,132pt monster.
    @Test("a labelled sixteen-week grid fits inside the menu's minimum width")
    func theGridFitsTheMenuWidth() {
        // Arrange
        let contentWidth = Metric.textInset * 2 + Metric.weekdayGutter + Metric.gridWidth

        // Act
        let size = ComponentMetrics.fittingSize(cells: Metric.windowDays)

        // Assert
        #expect(contentWidth <= Metric.minimumWidth)
        #expect(size.width == Metric.minimumWidth)
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// The headings reach the view that draws them
//
// The calendar half of the labels is settled in `MenuAdapter`; this is the last
// hop. A component that received cells but not headings would draw an unlabelled
// grid, which is exactly what the slice exists to stop.
// ═════════════════════════════════════════════════════════════════════════════

private enum Headed {
    static let id = 440_703
    static let title = "Scholarly Project Milestones"
    static let months: [String?] = [
        "Feb", "Mar", nil, nil, nil, "Apr", nil, nil, nil, "May", nil, nil, nil, nil, "Jun", nil,
    ]

    static var course: CourseRow {
        CourseRow(
            id: Self.id, title: Self.title,
            url: URL(string: "https://purdue.brightspace.com/d2l/home/\(Self.id)")!,
            graph: window(), graphMonths: Self.months
        )
    }
}

@MainActor
@Suite("Course headings reach the component")
struct GridLabelWiringTests {

    /// The hosting view exposes them for the same reason it exposes `cells`:
    /// it is the seam the suite can see, and the layers below it are drawing.
    @Test("a component built with headings carries them")
    func theComponentCarriesItsHeadings() {
        // Arrange / Act
        let view = MenuItemHostingView(
            title: Headed.title, cells: window(), showsChevron: false, monthLabels: Headed.months
        )

        // Assert
        #expect(view.monthLabels == Headed.months)
    }

    /// Defaulted, so the slice-1 call sites and fixtures compile untouched — the
    /// same courtesy `graph` and `graphMonths` extend.
    @Test("a component built the old way has no headings rather than failing to build")
    func headingsAreOptionalAtTheCallSite() {
        // Arrange / Act
        let view = MenuItemHostingView(title: Headed.title, cells: window(), showsChevron: false)

        // Assert
        #expect(view.monthLabels == [])
    }

    /// The assembler threads the row's headings onto its component. This is the
    /// join that, if missed, produces a grid drawn perfectly with no scale over
    /// it — and every other test in the suite still passes.
    @Test("the assembler hands each course's headings to its component")
    func theAssemblerThreadsHeadings() throws {
        // Arrange
        let assembler = MenuAssembler(opener: FakeURLOpener(), onCommand: { _ in })

        // Act
        let menu = assembler.assemble(MenuModel(rows: [.course(Headed.course)]))

        // Assert
        let item = try #require(menu.items.first)
        let component = try #require(item.view as? MenuItemHostingView)
        #expect(component.monthLabels == Headed.months)
        #expect(component.cells.count == Metric.windowDays)
    }

    /// And the row that has none stays the plain row it was.
    @Test("an ungraphed course assembles to a component with no headings")
    func ungraphedCoursesGetNoHeadings() throws {
        // Arrange
        let plain = CourseRow(
            id: 1, title: "Purdue Civics",
            url: URL(string: "https://purdue.brightspace.com/d2l/home/1")!
        )
        let assembler = MenuAssembler(opener: FakeURLOpener(), onCommand: { _ in })

        // Act
        let menu = assembler.assemble(MenuModel(rows: [.course(plain)]))

        // Assert
        let component = try #require(menu.items.first?.view as? MenuItemHostingView)
        #expect(component.monthLabels == [])
    }
}
