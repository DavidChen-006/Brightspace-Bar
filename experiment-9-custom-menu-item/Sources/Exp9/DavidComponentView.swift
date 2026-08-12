import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// David's rendering playground — now the CLICK-TO-CYCLE input experiment.
//
// The question this row answers: can a menu-hosted grid take repeated clicks —
// hover a cell, click it to rotate nothing → assignment → quiz → test →
// nothing — while the menu STAYS OPEN and repaints live?
//
// What we already know (found by clicking around BrightspaceBar): AppKit gives
// view-backed items no click behavior at all, so when our mouseUp does not
// cancel tracking, nothing closes the menu. What this row must still prove:
//
//   1. REPEATED clicks on one spot all arrive (or does double-click coalescing
//      eat every second one? `event.clickCount` is printed per click to tell).
//   2. The view repaints live mid-tracking on every click.
//   3. Hit-testing partitions one surface: clicks INSIDE a cell rotate it and
//      keep the menu open; clicks anywhere else keep the old behavior
//      (forward to the item's action, which closes the menu).
//   4. mouseMoved arrives during menu tracking, so the hovered cell can wear
//      an aiming outline — an 8pt target wants one.
//
// The cells are MUTABLE LOCAL STATE, on purpose and only here: this is an
// input experiment, not the overlay store. The real app routes the same click
// through a callback to a store, translates index → date with the window
// math, and re-derives. None of that belongs in this probe.
//
// Scaffolding notes (unchanged from the learning phase):
//   frame     — set in init; NSMenuItem honors it verbatim
//   highlight — `isHighlightedForMenu` flipped by MenuController's
//               willHighlight; the one hover signal AppKit provides
// ─────────────────────────────────────────────────────────────────────────────
@MainActor
final class DavidComponentView: NSView {

    // Metrics — the same values CourseComponentView measured against native
    // rows, duplicated so this canvas stays self-contained.
    private static let textInset: CGFloat = 14
    private static let highlightInsetX: CGFloat = 6
    private static let highlightInsetY: CGFloat = 2
    private static let highlightRadius: CGFloat = 6
    private static let cellSide: CGFloat = 8
    private static let cellGap: CGFloat = 2
    private static let cornerRadius: CGFloat = 2
    private static let titleHeight: CGFloat = 17
    private static let rowGap: CGFloat = 5
    private static let verticalPad: CGFloat = 6
    private static let weekdayGutter: CGFloat = 18

    let title: String

    /// Mutable ON PURPOSE — rotating these on click IS the experiment.
    private var cells: [DayCell]

    /// Every accepted cell click, shown in the title so no click can be
    /// swallowed silently.
    private var clickCount = 0

    /// The cell under the mouse, worn as an outline — the aiming aid.
    private var hoveredIndex: Int?

    /// Flipped from outside by NSMenuDelegate.willHighlight (see MenuController
    /// in main.swift).
    var isHighlightedForMenu = false {
        didSet { if oldValue != self.isHighlightedForMenu { self.needsDisplay = true } }
    }

    init(title: String, cells: [DayCell]) {
        self.title = title
        self.cells = cells
        let gridHeight = 7 * Self.cellSide + 6 * Self.cellGap
        let height = Self.verticalPad + Self.titleHeight + Self.rowGap + gridHeight + Self.verticalPad
        super.init(frame: CGRect(x: 0, y: 0, width: 340, height: height))
        self.autoresizingMask = [.width]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("code-built only") }

    // MARK: - Geometry

    /// Column-major GitHub layout: index = column * 7 + row, row 0 at the top.
    /// The drawing math; `cellIndex(at:)` below must be its exact inverse.
    private func cellRects() -> [CGRect] {
        let top = self.bounds.height - Self.verticalPad - Self.titleHeight - Self.rowGap
        let x0 = Self.textInset + Self.weekdayGutter
        return (0..<self.cells.count).map { index in
            let column = index / 7
            let row = index % 7
            return CGRect(
                x: x0 + CGFloat(column) * (Self.cellSide + Self.cellGap),
                y: top - Self.cellSide - CGFloat(row) * (Self.cellSide + Self.cellGap),
                width: Self.cellSide, height: Self.cellSide
            )
        }
    }

    /// The inverse mapping: a point → the cell it lands on. Each rect is
    /// inflated by 1pt per side, so the 2pt gaps between cells are split
    /// between their neighbors instead of being dead zones — a forgiving
    /// target without ever being ambiguous.
    private func cellIndex(at point: CGPoint) -> Int? {
        self.cellRects().firstIndex { $0.insetBy(dx: -1, dy: -1).contains(point) }
    }

    // MARK: - The rotation

    private static func nextTier(after tier: Tier?) -> Tier? {
        switch tier {
        case .none: .assignment
        case .assignment: .quiz
        case .quiz: .test
        case .test: nil
        }
    }

    // MARK: - Input

    override func mouseUp(with event: NSEvent) {
        let point = self.convert(event.locationInWindow, from: nil)

        // Inside a cell: rotate it, repaint, and DO NOT close the menu.
        if let index = self.cellIndex(at: point) {
            let old = self.cells[index]
            self.cells[index] = DayCell(Self.nextTier(after: old.tier), isToday: old.isToday)
            self.clickCount += 1
            // event.clickCount reveals double-click coalescing: if rapid
            // clicks arrive as clickCount 1,2,3… they all reached us.
            print("[exp9] cell \(index): \(old.tier.map(String.init(describing:)) ?? "empty")"
                + " → \(self.cells[index].tier.map(String.init(describing:)) ?? "empty")"
                + " (accepted #\(self.clickCount), event.clickCount=\(event.clickCount))")
            self.needsDisplay = true
            return
        }

        // Anywhere else on the component: the pre-existing contract — forward
        // to the item's action, which closes the menu. The partition question,
        // answered by rect membership.
        guard let item = self.enclosingMenuItem, let menu = item.menu else { return }
        menu.cancelTracking()
        if let index = menu.items.firstIndex(of: item), index >= 0 {
            menu.performActionForItem(at: index)
        }
    }

    // MARK: - Hover (mouseMoved during menu tracking)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in self.trackingAreas { self.removeTrackingArea(area) }
        self.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        let index = self.cellIndex(at: self.convert(event.locationInWindow, from: nil))
        if index != self.hoveredIndex {
            self.hoveredIndex = index
            self.needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if self.hoveredIndex != nil {
            self.hoveredIndex = nil
            self.needsDisplay = true
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = self.isHighlightedForMenu

        // The system hover capsule — native metrics, drawn first.
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(
                roundedRect: self.bounds.insetBy(dx: Self.highlightInsetX, dy: Self.highlightInsetY),
                xRadius: Self.highlightRadius, yRadius: Self.highlightRadius
            ).fill()
        }

        // Title, with the click counter — the unambiguous readout that every
        // click was received.
        let counted = self.clickCount > 0 ? "\(self.title) · \(self.clickCount) clicks" : self.title
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor,
        ]
        NSAttributedString(string: counted, attributes: titleAttrs).draw(at: CGPoint(
            x: Self.textInset,
            y: self.bounds.height - Self.verticalPad - Self.titleHeight + 1
        ))

        let rects = self.cellRects()

        // M/W/F gutter labels — kept so edge cells sit next to real neighbors,
        // which is where off-by-one hit-testing errors would live.
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: highlighted
                ? NSColor.selectedMenuItemTextColor.withAlphaComponent(0.75)
                : NSColor.secondaryLabelColor,
        ]
        for (letter, row) in [("M", 1), ("W", 3), ("F", 5)] where row < rects.count {
            let label = NSAttributedString(string: letter, attributes: labelAttrs)
            label.draw(at: CGPoint(
                x: Self.textInset + (Self.weekdayGutter - 6 - label.size().width),
                y: rects[row].minY - 1
            ))
        }

        // Cells: fill, then today's outline, then the hover outline on top.
        for (index, (cell, rect)) in zip(self.cells, rects).enumerated() {
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

            if index == self.hoveredIndex {
                let outline = NSBezierPath(
                    roundedRect: rect.insetBy(dx: -1, dy: -1),
                    xRadius: Self.cornerRadius, yRadius: Self.cornerRadius
                )
                outline.lineWidth = 1.5
                (highlighted ? NSColor.selectedMenuItemTextColor : .controlAccentColor).setStroke()
                outline.stroke()
            }
        }
    }

    /// Same palette as CourseComponentView, so the A/B against SCLA holds.
    private func fillColor(for tier: Tier?, highlighted: Bool) -> NSColor {
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
}
