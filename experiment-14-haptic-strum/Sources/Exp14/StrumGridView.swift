import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// The strum probe: exp 9's David grid (hover outline, named cells, bubble),
// plus ONE new ingredient — a haptic detent at every cell-boundary crossing.
//
//   mouseMoved → cellIndex changes → NSHapticFeedbackManager .alignment tick
//
// The hypothesis: this converts the sweep from visual-continuous to
// BODILY-continuous — the grid grows detents, like a comb under a thumbnail.
//
// What the experiment must reveal (each fire is logged, so feel can be
// compared against fact):
//   1. Do haptics fire AT ALL during menu tracking? (Menus run a special
//      event-tracking loop; haptics were designed for normal windows.)
//   2. Does per-crossing frequency feel like detents, or like buzzing noise
//      on a fast sweep? (The .now performanceTime is deliberate — deferred
//      times would smear fast crossings together.)
//   3. Hardware honesty: ticks exist only on Force Touch trackpads. On an
//      external mouse the strum silently degrades to the visual sweep.
//
// Everything else is copied from exp 9's DavidComponentView so the ONLY
// difference between the two rows across the two experiments is the haptic —
// a clean A/B for the hand.
// ─────────────────────────────────────────────────────────────────────────────

enum Tier: Int, Comparable {
    case assignment = 1
    case quiz = 2
    case test = 3
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct DayCell {
    let tier: Tier?
    let isToday: Bool
    let name: String?
    init(_ tier: Tier?, isToday: Bool = false, name: String? = nil) {
        self.tier = tier
        self.isToday = isToday
        self.name = name
    }
}

@MainActor
final class StrumGridView: NSView {

    // Metrics — the values CourseComponentView measured against native rows.
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
    private let cells: [DayCell]

    private var hoveredIndex: Int?
    private var strumCount = 0

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

    // MARK: - Geometry (same drawing math as exp 9; inverse below)

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

    private func cellIndex(at point: CGPoint) -> Int? {
        self.cellRects().firstIndex { $0.insetBy(dx: -1, dy: -1).contains(point) }
    }

    // MARK: - Hover + THE STRUM

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
        guard index != self.hoveredIndex else { return }
        self.hoveredIndex = index
        self.needsDisplay = true

        // THE experiment. One detent per boundary crossing — entering the
        // grid counts (nil → cell), leaving does not (cell → nil): a comb
        // ticks when a tooth is reached, not when the thumb lifts off.
        //
        // .alignment is the subtlest of the three feedback patterns, chosen
        // to read as texture rather than event. .now rather than
        // .drawCompleted: fast sweeps cross several cells per frame, and
        // deferred ticks would smear into one.
        if index != nil {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            self.strumCount += 1
            print("[exp14] detent #\(self.strumCount) at cell \(index!)")
        }
    }

    override func mouseExited(with event: NSEvent) {
        if self.hoveredIndex != nil {
            self.hoveredIndex = nil
            self.needsDisplay = true
        }
    }

    // Clicks: no cycling here — this probe is about FEEL, and the sweep must
    // stay consequence-free. Anywhere on the row forwards to the item action.
    override func mouseUp(with event: NSEvent) {
        guard let item = self.enclosingMenuItem, let menu = item.menu else { return }
        menu.cancelTracking()
        if let index = menu.items.firstIndex(of: item), index >= 0 {
            menu.performActionForItem(at: index)
        }
    }

    // MARK: - Drawing (exp 9's, unchanged: capsule, title, labels, cells, bubble)

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = self.isHighlightedForMenu

        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(
                roundedRect: self.bounds.insetBy(dx: Self.highlightInsetX, dy: Self.highlightInsetY),
                xRadius: Self.highlightRadius, yRadius: Self.highlightRadius
            ).fill()
        }

        let counted = self.strumCount > 0 ? "\(self.title) · \(self.strumCount) detents" : self.title
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor,
        ]
        NSAttributedString(string: counted, attributes: titleAttrs).draw(at: CGPoint(
            x: Self.textInset,
            y: self.bounds.height - Self.verticalPad - Self.titleHeight + 1
        ))

        let rects = self.cellRects()

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

        if let hovered = self.hoveredIndex, let name = self.cells[hovered].name {
            self.drawBubble(text: name, near: rects[hovered])
        }
    }

    private func drawBubble(text: String, near cell: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
        ]
        let label = NSAttributedString(string: text, attributes: attrs)
        let padding: CGFloat = 7
        let size = label.size()
        var bubble = CGRect(
            x: cell.midX - size.width / 2 - padding,
            y: cell.maxY + 5,
            width: size.width + padding * 2,
            height: size.height + 8
        )
        bubble.origin.x = max(
            Self.highlightInsetX + 2,
            min(bubble.origin.x, self.bounds.width - Self.highlightInsetX - 2 - bubble.width)
        )
        if bubble.maxY > self.bounds.height - Self.verticalPad - Self.titleHeight {
            bubble.origin.y = cell.minY - bubble.height - 5
        }

        let path = NSBezierPath(roundedRect: bubble, xRadius: 5, yRadius: 5)
        NSColor.windowBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        label.draw(at: CGPoint(x: bubble.minX + padding, y: bubble.minY + 4))
    }

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
