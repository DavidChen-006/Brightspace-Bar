import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// The probe: one NSView that renders a whole course component — title, graph,
// hairlines — inside a single NSMenuItem, with hover unity.
//
// Plain NSView on purpose (seam S2): RepoBar reaches for NSHostingController +
// a SwiftUI container; this experiment asks whether AppKit alone is enough.
// Everything AppKit refuses to do for a view-backed item is done by hand here,
// and each hand-made piece is a finding:
//
//   highlight background  — hand-drawn   (AppKit draws none for view items)
//   highlight *signal*    — hand-wired   (NSMenuDelegate.willHighlight; the
//                            item's own isHighlighted flips, but nothing tells
//                            the view to redraw)
//   click                 — hand-forwarded (mouseUp → performActionForItem)
//   submenu arrow         — hand-drawn   (RepoBar draws its own chevron too —
//                            that is evidence, not style)
// ─────────────────────────────────────────────────────────────────────────────

/// Local copy of the contract's cell vocabulary, so the experiment stays
/// dependency-free. Same shape as CourseMenu.GraphCell / CellTier.
enum Tier: Int, Comparable {
    case assignment = 1
    case quiz = 2
    /// Added for the click-to-cycle experiment: David's fourth state.
    case test = 3
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct DayCell {
    let tier: Tier?
    let isToday: Bool
    init(_ tier: Tier?, isToday: Bool = false) {
        self.tier = tier
        self.isToday = isToday
    }
}

/// Strip vs GitHub-grid — S5 needs both on screen.
enum GraphShape {
    /// One row, index = day offset.
    case strip
    /// Column-major weeks, 7 rows: index = column * 7 + row, read like GitHub.
    case grid(columns: Int)
}

@MainActor
final class CourseComponentView: NSView {

    // MARK: - Metrics (menu-native values, measured against real menu rows)

    /// Native menu rows lead their text by ~14pt inside the highlight capsule.
    private static let textInset: CGFloat = 14
    /// The highlight capsule's own inset from the item edge (RepoBar: 6/2/6;
    /// verified visually against native rows in this same menu).
    private static let highlightInsetX: CGFloat = 6
    private static let highlightInsetY: CGFloat = 2
    private static let highlightRadius: CGFloat = 6
    private static let cellSide: CGFloat = 8
    private static let cellGap: CGFloat = 2
    private static let cornerRadius: CGFloat = 2
    private static let titleHeight: CGFloat = 17
    private static let rowGap: CGFloat = 5
    private static let verticalPad: CGFloat = 6
    /// Space reserved for M/W/F labels left of a grid.
    private static let weekdayGutter: CGFloat = 18
    private static let monthRow: CGFloat = 12

    private let title: String
    private let cells: [DayCell]
    private let shape: GraphShape
    private let showsChevron: Bool
    private let hairlines: Bool

    /// Flipped by the menu delegate (`willHighlight`) — the ONE signal AppKit
    /// gives us, and it arrives on the delegate, not the view.
    var isHighlightedForMenu = false {
        didSet { if oldValue != self.isHighlightedForMenu { self.needsDisplay = true } }
    }

    init(title: String, cells: [DayCell], shape: GraphShape, showsChevron: Bool, hairlines: Bool = true) {
        self.title = title
        self.cells = cells
        self.shape = shape
        self.showsChevron = showsChevron
        self.hairlines = hairlines
        super.init(frame: CGRect(origin: .zero, size: Self.fittingSize(cells: cells.count, shape: shape)))
        // Stretch to the menu's final width so the highlight capsule spans the
        // row like a native item's does, instead of stopping at our content.
        self.autoresizingMask = [.width]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("code-built only") }

    // MARK: - Geometry (pure, static — house style survives the port)

    static func fittingSize(cells: Int, shape: GraphShape) -> CGSize {
        switch shape {
        case .strip:
            let width = self.textInset * 2 + CGFloat(cells) * self.cellSide
                + CGFloat(max(cells - 1, 0)) * self.cellGap
            let height = self.verticalPad + self.titleHeight + self.rowGap
                + self.cellSide + self.verticalPad
            return CGSize(width: max(width, 240), height: height)
        case .grid(let columns):
            let gridWidth = CGFloat(columns) * self.cellSide + CGFloat(columns - 1) * self.cellGap
            let width = self.textInset + self.weekdayGutter + gridWidth + self.textInset
            let gridHeight = 7 * self.cellSide + 6 * self.cellGap
            let height = self.verticalPad + self.titleHeight + self.rowGap
                + self.monthRow + gridHeight + self.verticalPad
            return CGSize(width: max(width, 240), height: height)
        }
    }

    private func cellRects() -> [CGRect] {
        // Flipped-feeling manual layout: y grows downward from the top edge.
        let top = self.bounds.height - Self.verticalPad - Self.titleHeight - Self.rowGap
        switch self.shape {
        case .strip:
            let y = top - Self.cellSide
            return (0..<self.cells.count).map { index in
                CGRect(
                    x: Self.textInset + CGFloat(index) * (Self.cellSide + Self.cellGap),
                    y: y, width: Self.cellSide, height: Self.cellSide
                )
            }
        case .grid(let columns):
            let gridTop = top - Self.monthRow
            let x0 = Self.textInset + Self.weekdayGutter
            return (0..<self.cells.count).map { index in
                let column = index / 7
                let row = index % 7
                _ = columns
                return CGRect(
                    x: x0 + CGFloat(column) * (Self.cellSide + Self.cellGap),
                    y: gridTop - Self.cellSide - CGFloat(row) * (Self.cellSide + Self.cellGap),
                    width: Self.cellSide, height: Self.cellSide
                )
            }
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = self.isHighlightedForMenu

        // 1. The highlight capsule — the entire point of the experiment. One
        //    rounded rect behind title AND graph makes them one component.
        if highlighted {
            let capsule = self.bounds.insetBy(dx: Self.highlightInsetX, dy: Self.highlightInsetY)
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: capsule, xRadius: Self.highlightRadius, yRadius: Self.highlightRadius).fill()
        }

        // 2. One hairline at the TOP edge only — each component owns the line
        //    above itself, so stacked components never double their lines.
        //    Drawn even while highlighted: the capsule is inset 2pt vertically,
        //    so the topmost pixel row is outside it and the two never overlap.
        if self.hairlines {
            NSColor.separatorColor.setFill()
            self.bounds.divided(atDistance: 1, from: .maxYEdge).slice.fill()
        }

        // 3. Title, menu-native font and colors.
        let titleColor: NSColor = highlighted ? .selectedMenuItemTextColor : .labelColor
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: titleColor,
        ]
        let titleOrigin = CGPoint(
            x: Self.textInset,
            y: self.bounds.height - Self.verticalPad - Self.titleHeight + 1
        )
        NSAttributedString(string: self.title, attributes: titleAttrs).draw(at: titleOrigin)

        // 4. Submenu chevron — AppKit will not draw one for a view item.
        if self.showsChevron {
            let chevron = NSAttributedString(string: "❯", attributes: [
                .font: NSFont.menuFont(ofSize: 11),
                .foregroundColor: highlighted ? titleColor : NSColor.tertiaryLabelColor,
            ])
            chevron.draw(at: CGPoint(
                x: self.bounds.width - Self.textInset - chevron.size().width,
                y: titleOrigin.y + 1
            ))
        }

        // 5. Labels for the grid shape (S5): M/W/F rows, month columns.
        if case .grid = self.shape {
            self.drawGridLabels(highlighted: highlighted)
        }

        // 6. The cells, tier-colored, today outlined after the fill.
        for (cell, rect) in zip(self.cells, self.cellRects()) {
            self.fillColor(for: cell.tier, highlighted: highlighted).setFill()
            NSBezierPath(roundedRect: rect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()
            if cell.isToday {
                let outline = NSBezierPath(
                    roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                    xRadius: Self.cornerRadius, yRadius: Self.cornerRadius
                )
                outline.lineWidth = 1
                (highlighted ? NSColor.selectedMenuItemTextColor : .labelColor).setStroke()
                outline.stroke()
            }
        }
    }

    private func drawGridLabels(highlighted: Bool) {
        let color: NSColor = highlighted
            ? NSColor.selectedMenuItemTextColor.withAlphaComponent(0.75)
            : .secondaryLabelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9), .foregroundColor: color,
        ]
        let rects = self.cellRects()
        guard !rects.isEmpty else { return }

        // Weekday labels on rows 1, 3, 5 — GitHub's Mon/Wed/Fri, abbreviated
        // to single letters to conserve width (David's call).
        for (letter, row) in [("M", 1), ("W", 3), ("F", 5)] {
            let label = NSAttributedString(string: letter, attributes: attrs)
            let anchor = rects[row]
            label.draw(at: CGPoint(
                x: Self.textInset + (Self.weekdayGutter - 6 - label.size().width),
                y: anchor.minY - 1
            ))
        }

        // Month labels over the columns — static mock spacing (a semester's
        // months land roughly every 4-5 week columns).
        let gridTopY = rects[0].maxY + 2
        for (month, column) in [("Sep", 0), ("Oct", 4), ("Nov", 8), ("Dec", 13)] {
            let index = column * 7
            guard index < rects.count else { continue }
            NSAttributedString(string: month, attributes: attrs)
                .draw(at: CGPoint(x: rects[index].minX, y: gridTopY))
        }
    }

    private func fillColor(for tier: Tier?, highlighted: Bool) -> NSColor {
        // Over the accent-colored capsule, accent-colored cells vanish — the
        // same problem RepoBar solves with a white-alpha palette when
        // highlighted. Same trick here.
        if highlighted {
            let base = NSColor.selectedMenuItemTextColor
            switch tier {
            case .none: return base.withAlphaComponent(0.25)
            case .assignment: return base.withAlphaComponent(0.6)
            case .quiz: return base.withAlphaComponent(0.95)
            case .test: return base
            }
        }
        switch tier {
        case .none: return .quaternaryLabelColor
        case .assignment: return NSColor.controlAccentColor.withAlphaComponent(0.45)
        case .quiz: return .controlAccentColor
        case .test: return .systemRed
        }
    }

    // MARK: - Click forwarding (AppKit delivers events to the view, not the item)

    override func mouseUp(with event: NSEvent) {
        guard let item = self.enclosingMenuItem, let menu = item.menu else { return }
        menu.cancelTracking()
        if let index = menu.items.firstIndex(of: item), index >= 0 {
            menu.performActionForItem(at: index)
        }
    }
}
