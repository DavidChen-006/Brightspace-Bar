import AppKit
import Foundation
import Testing

import BrightspaceBar
import CourseMenu

// ═════════════════════════════════════════════════════════════════════════════
// THE POPUP'S ANCHOR — below and to the right of the hovered cell (Intent 2).
//
// The placement rule exists for one interaction: sliding the pointer ALONG a
// row of day cells. If the popup ever sits in that row's horizontal band, the
// pointer's next step lands on the popup instead of the next cell, and the
// hover fights its own affordance. So "below and to the right" is not a taste
// call — it is the invariant that the popup's frame intersects neither the
// hovered cell nor anything sharing its y-band. That is geometry, and geometry
// is the half a screenshot will not check, so it is pinned here headlessly.
//
// Frames are SCREEN coordinates — bottom-left origin, y upward — because that
// is what `NSWindow.setFrame` consumes. "Below" therefore means SMALLER y,
// which is exactly the sign error this suite exists to catch: a flipped-space
// implementation places the popup above the cell, over the rows the pointer
// came from, and looks fine in the one screenshot where the cell is low.
//
// CULLED: the panel itself (child-window plumbing, the grace timer, tracking
// areas) — side-effectful AppKit, hand-verified in stub mode; and the popup's
// content layout, which reflows and is not a promise.
// ═════════════════════════════════════════════════════════════════════════════

@Suite("Graph popup anchoring — directly below the cell, never over its row")
struct GraphPopupMetricsTests {

    /// An 8pt cell somewhere mid-screen, screen coordinates.
    private let cell = CGRect(x: 500, y: 640, width: 8, height: 8)
    private let size = CGSize(width: 220, height: 96)

    @Test("the popup's frame never intersects the hovered cell")
    func theFrameNeverIntersectsTheCell() {
        let frame = GraphPopupMetrics.frame(anchoredTo: cell, size: size)
        #expect(!frame.intersects(cell))
    }

    @Test("the popup clears the cell's whole horizontal band — the row slide")
    func theFrameClearsTheCellsRowBand() {
        // Stronger than non-intersection: nothing in the popup may share a y
        // with the cell, or a slide along the row of cells hits the popup. The
        // band is the full row's, so neighbours left AND right stay clear.
        let frame = GraphPopupMetrics.frame(anchoredTo: cell, size: size)
        #expect(frame.maxY < cell.minY)
    }

    @Test("below means smaller y in screen space, offset by the gap, left-aligned")
    func belowMeansSmallerYInScreenSpace() {
        let frame = GraphPopupMetrics.frame(anchoredTo: cell, size: size, offset: 4)
        #expect(frame.maxY == cell.minY - 4)
        // Left-aligned with the cell, NOT diagonal: straight-down is the
        // shortest pointer path, and the diagonal placement was measured
        // unreachable within the grace period live (user report, 2026-08-24).
        #expect(frame.minX == cell.minX)
        #expect(frame.size == size)
    }

    @Test("the offset is a few px — inside the grace period's travel budget")
    func theOffsetIsAFewPoints() {
        // The pointer must cross this gap straight down within the grace delay;
        // an offset that grew past the neighbouring cell's pitch would also
        // stop reading as attached to the cell at all.
        #expect(GraphPopupMetrics.anchorOffset > 0)
        #expect(GraphPopupMetrics.anchorOffset <= 8)
    }

    @Test("moving to the adjacent cell moves the frame by exactly the cell pitch")
    func anAdjacentCellShiftsTheFrameByThePitch() {
        // Re-anchoring is a pure translation of the same function — the popup
        // steps with the pointer instead of jumping to a recomputed layout.
        let next = cell.offsetBy(dx: 10, dy: 0)  // cellSide 8 + gap 2
        let a = GraphPopupMetrics.frame(anchoredTo: cell, size: size)
        let b = GraphPopupMetrics.frame(anchoredTo: next, size: size)
        #expect(b == a.offsetBy(dx: 10, dy: 0))
    }
}
