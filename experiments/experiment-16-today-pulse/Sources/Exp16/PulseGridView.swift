import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// The pulse probe: exp 14's strum row (hover outline, haptic detents, hover
// bubble) with ONE new ingredient — the today cell breathes.
//
//   30fps .common-mode timer → sine of systemUptime → today outline alpha +
//   width (+ optional halo) → setNeedsDisplay(today rect only)
//
// The hypothesis: a slow sinusoidal breath makes today findable in peripheral
// vision without demanding attention. Apple's own idiom — the sleeping-Mac
// LED, the Watch breathe app — is slow and sinusoidal for a reason: fast or
// linear-ramped blinking reads as ALARM, and an alarm that fires every day is
// an alarm you learn to stop seeing.
//
// Three constraints this code is shaped by, each paid for by an earlier
// experiment:
//
//   1. Timers in `.default` mode NEVER fire while a menu is open (measured in
//      exp 12 — menus spin the run loop in `.eventTracking`). The pulse timer
//      is therefore added to RunLoop.main with `forMode: .common`. Get this
//      wrong and the cell is simply frozen for the entire life of the menu,
//      which looks exactly like "the feature does nothing".
//   2. The phase clock is `ProcessInfo.processInfo.systemUptime` (exp 14's
//      timing precedent) and it is FREE-RUNNING — it is never reset when the
//      timer starts. So the breath the menu opens onto is wherever the wall
//      clock says it should be, mid-inhale as often as not. Resetting the
//      phase on menuWillOpen would give every open the same little "kick" from
//      the trough, which is the tell that turns a presence into an animation.
//   3. Only the today cell's rect is invalidated. draw(_:) still runs the full
//      row (AppKit just clips it), so the bubble and hover outline stay
//      correct — the narrow rect only saves the compositor work, and at 30fps
//      × one 8pt cell that saving is real but small. It is written this way
//      because the real BrightspaceBar port will have ~8 rows, not one.
//
// Everything else in this file is exp 14's, unchanged, so the ONLY difference
// between the two rows is the breath.
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
final class PulseGridView: NSView {

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

    // MARK: - Pulse tuning knobs (David retunes these; they are the experiment)

    /// One full breath, in seconds. 3.0s ≈ a resting human breath, and that is
    /// the point: the eye classifies it as something alive rather than
    /// something signalling. Anything under ~2s starts to read as a blink.
    private static let pulsePeriod: TimeInterval = 3.0

    /// 30fps. A 3-second sine has no high-frequency content worth 60fps — the
    /// per-frame alpha step at 30fps is under 0.02, far below the eye's
    /// threshold for banding on an 8pt square. Halving the frame rate halves
    /// the wakeups in a menu that is otherwise perfectly still.
    private static let pulseInterval: TimeInterval = 1.0 / 30.0

    /// Outline alpha, trough → peak. The floor is 0.55 rather than 0 because
    /// today must never DISAPPEAR: it is a location marker first and an
    /// animation second. Breathing between visible and more-visible keeps the
    /// static-outline behaviour of exp 9 as the floor case.
    private static let outlineAlphaMin: CGFloat = 0.55
    private static let outlineAlphaMax: CGFloat = 1.0

    /// Outline width, trough → peak, in phase with alpha. Thickening and
    /// brightening together is one gesture; out of phase they read as two
    /// competing animations. The stroke grows INWARD (inset by width/2) so the
    /// cell's 8pt footprint never changes and neighbours never shift.
    private static let outlineWidthMin: CGFloat = 1.0
    private static let outlineWidthMax: CGFloat = 1.8

    /// The optional soft halo: a second stroke outside the cell, same phase.
    /// Set `haloPeakAlpha` to 0 to remove it entirely — that is the knob, and
    /// it is a knob because a halo at 2.5pt overlaps the 2pt gutter and so
    /// touches the neighbouring cells. Kept at 0.22 so it reads as bloom
    /// rather than as a second ring.
    private static let haloPeakAlpha: CGFloat = 0.22
    private static let haloInflate: CGFloat = 2.5
    private static let haloWidth: CGFloat = 1.5

    let title: String
    private let cells: [DayCell]

    private var hoveredIndex: Int?
    private var strumCount = 0

    private var pulseTimer: Timer?
    private var pulseTicks = 0
    private var pulseFrames = 0

    /// The volume knob macOS doesn't provide. Haptic amplitude is not
    /// controllable (.alignment is already the subtlest pattern), so
    /// "quieter" = SPARSER: crossings within this interval of the last tick
    /// are felt visually but not haptically. Slow deliberate sweeps still
    /// tick every tooth; fast flicks thin out instead of buzzing.
    private static let minimumTickInterval: TimeInterval = 0.09
    private var lastTick: TimeInterval = 0

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

    // MARK: - THE PULSE

    /// 0 at the trough, 1 at the peak, pure cosine — no linear segments, so
    /// the turnarounds are smooth. A triangle wave of the same period feels
    /// mechanical precisely because velocity jumps at the ends.
    private var breath: CGFloat {
        let t = ProcessInfo.processInfo.systemUptime
        let phase = 2 * Double.pi * t / Self.pulsePeriod
        return CGFloat((1 - cos(phase)) / 2)
    }

    /// Gated by the menu (see MenuController): the menu is closed 99% of the
    /// time and an invisible 30fps redraw is pure battery.
    func startPulsing() {
        guard self.pulseTimer == nil, self.cells.contains(where: { $0.isToday }) else { return }
        // Target/action rather than a block: the block form is @Sendable and
        // this view is MainActor-isolated, so the closure would have to launder
        // `self` across isolation for no benefit.
        let timer = Timer(
            timeInterval: Self.pulseInterval,
            target: self,
            selector: #selector(self.pulseTick(_:)),
            userInfo: nil,
            repeats: true
        )
        // The whole experiment hinges on this line. `.common` includes
        // `.eventTracking`, which is the mode a tracking menu spins in.
        RunLoop.main.add(timer, forMode: .common)
        self.pulseTimer = timer
        print("[exp16] pulse started — \(Self.pulsePeriod)s period at \(1 / Self.pulseInterval)fps, .common mode")
    }

    func stopPulsing() {
        self.pulseTimer?.invalidate()
        self.pulseTimer = nil
        print("[exp16] pulse stopped after \(self.pulseTicks) ticks / \(self.pulseFrames) frames")
        self.pulseTicks = 0
        self.pulseFrames = 0
    }

    @objc private func pulseTick(_ timer: Timer) {
        self.pulseTicks += 1
        // One line per second, not per frame: enough to prove from the log
        // that the timer really fires while the menu is tracking, cheap enough
        // to leave on. `frames` is incremented in draw(_:), so ticks ≫ frames
        // would mean invalidation is being coalesced away during tracking.
        if self.pulseTicks % 30 == 0 {
            print(String(
                format: "[exp16] pulse tick %d — breath %.2f, frames drawn %d",
                self.pulseTicks, self.breath, self.pulseFrames
            ))
        }
        guard let index = self.cells.firstIndex(where: { $0.isToday }) else { return }
        // Inflate past the halo and the fattest stroke so no edge is left stale.
        self.setNeedsDisplay(self.cellRects()[index].insetBy(dx: -6, dy: -6))
    }

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

        // One detent per boundary crossing — entering the grid counts
        // (nil → cell), leaving does not (cell → nil): a comb ticks when a
        // tooth is reached, not when the thumb lifts off.
        if index != nil {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastTick >= Self.minimumTickInterval else { return }
            self.lastTick = now
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            self.strumCount += 1
            print("[exp16] detent #\(self.strumCount) at cell \(index!)")
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

    // MARK: - Drawing (exp 14's, plus the breathing today cell)

    override func draw(_ dirtyRect: NSRect) {
        self.pulseFrames += 1
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

        // Sampled ONCE per frame: every stroke of the breath must share a
        // phase, or the halo and the outline drift apart into two animations.
        let breath = self.breath

        for (index, (cell, rect)) in zip(self.cells, rects).enumerated() {
            self.fillColor(for: cell.tier, highlighted: highlighted).setFill()
            NSBezierPath(roundedRect: rect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()

            if cell.isToday {
                let ink = highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor

                if Self.haloPeakAlpha > 0 {
                    let halo = NSBezierPath(
                        roundedRect: rect.insetBy(dx: -Self.haloInflate, dy: -Self.haloInflate),
                        xRadius: Self.cornerRadius + Self.haloInflate,
                        yRadius: Self.cornerRadius + Self.haloInflate
                    )
                    halo.lineWidth = Self.haloWidth
                    ink.withAlphaComponent(Self.haloPeakAlpha * breath).setStroke()
                    halo.stroke()
                }

                let width = Self.outlineWidthMin + (Self.outlineWidthMax - Self.outlineWidthMin) * breath
                let alpha = Self.outlineAlphaMin + (Self.outlineAlphaMax - Self.outlineAlphaMin) * breath
                let outline = NSBezierPath(
                    roundedRect: rect.insetBy(dx: width / 2, dy: width / 2),
                    xRadius: Self.cornerRadius, yRadius: Self.cornerRadius
                )
                outline.lineWidth = width
                ink.withAlphaComponent(alpha).setStroke()
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
