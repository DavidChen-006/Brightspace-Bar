import AppKit
import CourseMenu

// ─────────────────────────────────────────────────────────────────────────────
// The course activity graph: one row of day cells hosted in an NSMenuItem.
//
// Geometry is a pure enum and drawing is a thin `draw(_:)` over it, so the
// arithmetic is testable in a process with no window. There is no raster engine
// here on purpose (NewVertical-2.md §5): RepoBar caches CGImages because it
// redraws 371-cell year grids for many repos, and ~6 courses × 28 cells is
// nothing.
// ─────────────────────────────────────────────────────────────────────────────

/// Where the cells go. Pure arithmetic — no drawing, no AppKit state.
public enum GraphStripLayout {
    public static let cellSide: CGFloat = 8
    public static let spacing: CGFloat = 2
    /// The menu item text inset, so the strip's left edge lines up with the
    /// course name above it rather than floating a few points off it.
    public static let padding: CGFloat = 14

    /// Vertical breathing room above and below the cells. Not the menu row
    /// height: an `NSMenuItem.view` gets exactly the height its frame asks for.
    private static let verticalPadding: CGFloat = 3

    /// One rect per cell, left to right at a fixed pitch, all sharing one
    /// baseline — a strip, not a grid.
    public static func rects(count: Int, in bounds: CGRect) -> [CGRect] {
        let y = bounds.midY - self.cellSide / 2
        return (0..<max(count, 0)).map { index in
            CGRect(
                x: self.padding + CGFloat(index) * (self.cellSide + self.spacing),
                y: y,
                width: self.cellSide,
                height: self.cellSide
            )
        }
    }

    /// What the hosting view's frame must be. `NSMenuItem.view` is not laid out
    /// for you the way a window's subview is: a frame too narrow clips the days
    /// furthest out, and a zero frame renders nothing at all.
    public static func size(count: Int) -> CGSize {
        let cells = CGFloat(max(count, 0))
        let gaps = max(cells - 1, 0)
        return CGSize(
            width: self.padding * 2 + cells * self.cellSide + gaps * self.spacing,
            height: self.cellSide + self.verticalPadding * 2
        )
    }
}

/// Draws one course's strip. Inert: it carries no target, no action, and no
/// hit testing — the item hosting it is disabled.
public final class GraphStripView: NSView {
    public let cells: [GraphCell]

    /// Corner rounding on the fills. Small enough to stay square-ish at 8pt,
    /// large enough that the cells don't read as a barcode.
    private static let cornerRadius: CGFloat = 2

    public init(cells: [GraphCell]) {
        self.cells = cells
        super.init(frame: CGRect(origin: .zero, size: GraphStripLayout.size(count: cells.count)))
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("GraphStripView is built in code, never from a nib")
    }

    /// Dynamic system colours only — they resolve against the current
    /// appearance at draw time, so light mode, dark mode, and the menu's
    /// highlight state all come out right with no palette table to maintain.
    public override func draw(_ dirtyRect: NSRect) {
        for (cell, rect) in zip(self.cells, GraphStripLayout.rects(count: self.cells.count, in: self.bounds)) {
            let fill = NSBezierPath(
                roundedRect: rect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius
            )
            Self.fillColor(for: cell.tier).setFill()
            fill.fill()

            guard cell.isToday else { continue }
            // Stroked after the fill and inset by half a line width, so today's
            // marker sits on the cell's own edge instead of covering the tier
            // colour that says what is actually due.
            let outline = NSBezierPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                xRadius: Self.cornerRadius, yRadius: Self.cornerRadius
            )
            outline.lineWidth = 1
            NSColor.labelColor.setStroke()
            outline.stroke()
        }
    }

    /// Darker means more important: a quiz is the full accent, an assignment a
    /// muted one, an empty day the same grey the menu uses for disabled text.
    private static func fillColor(for tier: CellTier?) -> NSColor {
        switch tier {
        case .none: .quaternaryLabelColor
        case .assignment: NSColor.controlAccentColor.withAlphaComponent(0.45)
        case .quiz: .controlAccentColor
        }
    }
}
