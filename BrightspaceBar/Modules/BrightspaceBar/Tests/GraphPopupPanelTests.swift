import AppKit
import Foundation
import Testing

@testable import BrightspaceBar
import CourseMenu

// ═════════════════════════════════════════════════════════════════════════════
// THE POPUP PANEL'S SIZE — the regression that shipped as "hover ring, no popup".
//
// `GraphPopupContentView` sizes itself at init, and `show()` places the panel
// from that size. The live bug: `panel.contentView = content` ran BEFORE the
// size was read, and installing a contentView resizes the view to the window's
// current content rect — `.zero` on a fresh panel — so every popup was a
// perfectly real, perfectly ordered, zero-size window. Nothing else in the
// pipeline noticed: the hover ring draws from `detail` alone, and the panel
// was "visible" by every flag AppKit exposes. So the invariant is pinned here:
// a shown panel's frame is the content's laid-out size at the metrics' anchor,
// and never empty.
// ═════════════════════════════════════════════════════════════════════════════

@Suite("Graph popup panel — a shown panel is never zero-size")
@MainActor
struct GraphPopupPanelTests {

    private let cell = CGRect(x: 500, y: 640, width: 8, height: 8)

    private func detail(rows: Int) -> GraphDayDetail {
        GraphDayDetail(
            caption: "Thu Aug 27 · ANTH 21000",
            items: (0..<rows).map {
                GraphDayItem(
                    title: "Short Paper \($0 + 1)", tier: .assignment,
                    url: URL(string: "https://purdue.brightspace.com/d2l/home/1")!
                )
            }
        )
    }

    @Test("show() gives the panel the content's own size, not the fresh panel's zero")
    func shownPanelHasTheContentSize() throws {
        let controller = GraphDayPopupController(opener: FakeURLOpener(), dismissMenu: {})
        controller.show(self.detail(rows: 2), anchoredTo: self.cell)

        let frame = try #require(controller.panelFrameForTesting)
        #expect(!frame.isEmpty, "a zero-size panel is the live 'ring but no popup' bug")
        // The height is pure arithmetic over the row count, so it pins that the
        // size used for placement is the content's and not a stale one.
        #expect(frame.height == GraphPopupMetrics.contentHeight(rows: 2))
        #expect(frame == GraphPopupMetrics.frame(anchoredTo: self.cell, size: frame.size))
    }

    @Test("re-showing with another day's detail keeps the panel non-empty")
    func reShowKeepsThePanelNonEmpty() throws {
        let controller = GraphDayPopupController(opener: FakeURLOpener(), dismissMenu: {})
        controller.show(self.detail(rows: 1), anchoredTo: self.cell)
        let moved = self.cell.offsetBy(dx: 30, dy: -20)
        controller.show(self.detail(rows: 3), anchoredTo: moved)

        let frame = try #require(controller.panelFrameForTesting)
        #expect(!frame.isEmpty)
        #expect(frame.height == GraphPopupMetrics.contentHeight(rows: 3))
        #expect(frame == GraphPopupMetrics.frame(anchoredTo: moved, size: frame.size))
    }
}
