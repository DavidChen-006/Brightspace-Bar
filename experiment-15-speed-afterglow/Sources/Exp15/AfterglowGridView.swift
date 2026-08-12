import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// The afterglow probe: exp 14's strum row (hover outline, named cells, bubble,
// haptic detent per crossing) plus ONE new ingredient — a comet tail that only
// blooms when you sweep FAST.
//
//   mouseMoved → cell crossing → is it within 90ms of the last one?
//                                 ├─ yes ×2 → gate opens → departed cells glow
//                                 └─ no     → gate closes → nothing at all
//
// The hypothesis: a reward you always get is decoration; a reward you have to
// earn is an EXECUTION. Gating the trail on speed gives the sweep a skill
// ceiling — the fast, clean flick feels better than the hesitant drag, so the
// hand starts producing crisp little sweeps on its own. That is muscle memory
// forming in real time, and it costs nothing but a threshold.
//
// What the experiment must reveal:
//   1. Is the gate legible? A gate you cannot feel yourself crossing is just
//      an intermittent bug. You should know, without being told, why the tail
//      appeared — and be able to make it appear again on purpose.
//   2. Is 90ms (≈11 cells/sec) the right bar? Too low and every drag paints;
//      too high and only a slam does, which teaches flailing, not fluency.
//   3. Does it stay CALM? The governing aesthetic rule of the whole app is
//      calm-until-touched. Every trail entry must be fully dead 250ms after
//      the mouse stops, and the repaint timer must stop dead with it.
//
// Everything below the MARK dividers is exp 14's, unchanged, so the ONLY
// difference between the two rows across the two experiments is the trail —
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
final class AfterglowGridView: NSView {

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

    /// The volume knob macOS doesn't provide. Haptic amplitude is not
    /// controllable (.alignment is already the subtlest pattern), so
    /// "quieter" = SPARSER: crossings within this interval of the last tick
    /// are felt visually but not haptically. Slow deliberate sweeps still
    /// tick every tooth; fast flicks thin out instead of buzzing.
    private static let minimumTickInterval: TimeInterval = 0.09
    private var lastTick: TimeInterval = 0

    // MARK: - The speed gate

    /// A crossing counts as "fast" if it lands within this long of the previous
    /// one — 90ms ≈ 11 cells/sec. Picked because it is just above a comfortable
    /// *reading* drag (you cannot read a name in 90ms, so anyone actually
    /// scanning the semester stays below the bar and gets a calm, trail-free
    /// grid) and just below a flick (a deliberate swipe across the 16 columns
    /// clears it easily). The gate should separate *intents*, not speeds.
    private static let fastCrossingInterval: TimeInterval = 0.09

    /// Two in a row, not one — a single fast crossing is noise (a hand
    /// re-settling, a jump across the grid). Requiring two makes the gate
    /// respond to sustained motion, which is what "fluent" means.
    private static let fastCrossingsToOpen = 2

    /// Hysteresis. Once open, the gate survives this long without a fast
    /// crossing before closing. Without it the trail strobes on and off for
    /// anyone hovering right at the threshold — the single ugliest failure
    /// mode this mechanic has, because it reads as broken rather than as
    /// a rule.
    private static let gateHoldInterval: TimeInterval = 0.15

    /// How long one departed cell keeps glowing. 250ms is the whole settle
    /// budget: the trail must be perfectly still within ~300ms of the mouse
    /// stopping, or the menu stops feeling calm-until-touched.
    private static let afterglowDuration: TimeInterval = 0.25

    /// Peak stroke alpha at the instant a cell is departed. Subtle > flashy:
    /// the tail is a ghost of the live outline, never a competitor to it.
    private static let afterglowPeakAlpha: CGFloat = 0.55

    /// The soft fill rides at this fraction of the stroke's alpha — enough to
    /// give the tail body, not enough to read as a selection.
    private static let afterglowFillRatio: CGFloat = 0.3

    /// At 90ms/crossing and a 250ms life, at most ~3 entries are ever alive;
    /// the cap only bounds a pathological flick, and keeps the tail a tail.
    private static let maximumTrailLength = 12

    /// ~60fps. The decay is the only thing that needs frames, so this is the
    /// only thing that gets them — and only while a trail is alive.
    private static let tickInterval: TimeInterval = 1.0 / 60.0

    private struct Glow {
        let index: Int
        let born: TimeInterval
    }

    private var trail: [Glow] = []
    private var lastCrossing: TimeInterval = 0
    private var lastFastCrossing: TimeInterval = 0
    private var consecutiveFastCrossings = 0
    private var flickCount = 0
    private var decayTimer: Timer?

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

    // MARK: - Hover, the strum, and THE GATE

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
        let departed = self.hoveredIndex
        self.hoveredIndex = index
        self.needsDisplay = true

        // The comb rule, inherited from exp 14 and extended to the trail:
        // entering the grid counts (nil → cell), leaving does not (cell → nil).
        // A comb ticks when a tooth is reached, not when the thumb lifts off —
        // and a flick that runs off the edge shouldn't paint one last cell as
        // a parting gift.
        guard index != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime

        // THE experiment. Speed is measured as the gap between consecutive
        // crossings rather than as pointer velocity, because the cells are what
        // the hand is actually aiming at: crossings/sec is the rhythm you feel,
        // px/sec is a number about the mouse.
        let sinceLastCrossing = now - self.lastCrossing
        self.lastCrossing = now
        if sinceLastCrossing <= Self.fastCrossingInterval {
            self.consecutiveFastCrossings += 1
            self.lastFastCrossing = now
        } else {
            self.consecutiveFastCrossings = 0
        }

        if self.gateIsOpen(now: now), let departed {
            self.bloom(departed, now: now)
        }

        // exp 14's haptic, untouched — the afterglow layers ON TOP of the
        // strum, and the combination is the thing being judged.
        guard now - self.lastTick >= Self.minimumTickInterval else { return }
        self.lastTick = now
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func gateIsOpen(now: TimeInterval) -> Bool {
        self.consecutiveFastCrossings >= Self.fastCrossingsToOpen
            && now - self.lastFastCrossing <= Self.gateHoldInterval
    }

    private func bloom(_ index: Int, now: TimeInterval) {
        if self.trail.isEmpty {
            self.flickCount += 1
            print("[exp15] gate open — flick #\(self.flickCount)")
        }
        self.trail.append(Glow(index: index, born: now))
        if self.trail.count > Self.maximumTrailLength { self.trail.removeFirst() }
        self.startDecayTimerIfNeeded()
    }

    // MARK: - The decay driver

    /// The timer exists ONLY while something is fading. A permanent 60fps loop
    /// in a menu-bar app is a battery bug wearing an animation costume.
    ///
    /// `.common` mode is load-bearing, not defensive: an open NSMenu runs the
    /// run loop in `.eventTracking`, where a `.default`-mode timer never fires
    /// once — measured the hard way in experiment 12. Timer(timeInterval:) +
    /// RunLoop.add is the only spelling that lets the mode be chosen;
    /// `Timer.scheduledTimer` silently installs into `.default` and would leave
    /// the trail frozen on screen the entire time the menu is open.
    private func startDecayTimerIfNeeded() {
        guard self.decayTimer == nil else { return }
        // Strong capture, and the retain cycle (view → timer → block → view) is
        // deliberate: it is bounded by the decay, which always reaches empty
        // and invalidates. A weak self would need the block's own Timer
        // argument to shut itself down, and that argument cannot cross onto the
        // MainActor without tripping Swift 6's sending check.
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { _ in
            // Timers added to RunLoop.main always fire on the main thread, so
            // the isolation is real and assumeIsolated is honest.
            MainActor.assumeIsolated { self.decayTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.decayTimer = timer
    }

    private func decayTick() {
        let now = ProcessInfo.processInfo.systemUptime
        self.trail.removeAll { now - $0.born >= Self.afterglowDuration }
        if self.trail.isEmpty {
            self.decayTimer?.invalidate()
            self.decayTimer = nil
            // 250ms of decay outlasts the 150ms gate hold, so by the time the
            // last ember dies the gate is provably shut. Zeroing here keeps the
            // title from advertising "flick!" over a grid that is already still.
            self.consecutiveFastCrossings = 0
        }
        self.needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        if self.hoveredIndex != nil {
            self.hoveredIndex = nil
            self.needsDisplay = true
        }
        // The trail is deliberately NOT cleared: a flick that ends by leaving
        // the grid should still get to finish its streak. It dies on schedule.
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

    // MARK: - Drawing (exp 14's, plus the trail pass)

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = self.isHighlightedForMenu
        let now = ProcessInfo.processInfo.systemUptime

        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(
                roundedRect: self.bounds.insetBy(dx: Self.highlightInsetX, dy: Self.highlightInsetY),
                xRadius: Self.highlightRadius, yRadius: Self.highlightRadius
            ).fill()
        }

        // The title is the gate's instrument panel: it says "flick!" exactly
        // while the trail is licensed to paint, so a confusing session can be
        // resolved by reading instead of guessing.
        let counted: String
        if self.gateIsOpen(now: now) {
            counted = "\(self.title) · flick!"
        } else if self.flickCount > 0 {
            counted = "\(self.title) · \(self.flickCount) flicks"
        } else {
            counted = self.title
        }
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

        for (cell, rect) in zip(self.cells, rects) {
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

        // Trail, then live outline — in that order, and both after every cell
        // fill, so the tail is never painted over and the outline always leads
        // it. (exp 14 drew the outline inside the cell loop; it had nothing
        // behind it to sort against.)
        self.drawTrail(rects: rects, now: now, highlighted: highlighted)

        if let hovered = self.hoveredIndex, hovered < rects.count {
            let outline = NSBezierPath(
                roundedRect: rects[hovered].insetBy(dx: -1, dy: -1),
                xRadius: Self.cornerRadius, yRadius: Self.cornerRadius
            )
            outline.lineWidth = 1.5
            (highlighted ? NSColor.selectedMenuItemTextColor : .controlAccentColor).setStroke()
            outline.stroke()
        }

        if let hovered = self.hoveredIndex, let name = self.cells[hovered].name {
            self.drawBubble(text: name, near: rects[hovered])
        }
    }

    private func drawTrail(rects: [CGRect], now: TimeInterval, highlighted: Bool) {
        let base = highlighted ? NSColor.selectedMenuItemTextColor : NSColor.controlAccentColor
        for glow in self.trail where glow.index < rects.count {
            let remaining = Self.afterglowDuration - (now - glow.born)
            guard remaining > 0 else { continue }
            // Squared, not linear: the ember drops off its peak immediately so
            // the live outline stays the brightest thing on the row, then
            // lingers faint enough to read as a streak rather than a queue of
            // copies of the cursor.
            let progress = CGFloat(remaining / Self.afterglowDuration)
            let alpha = progress * progress * Self.afterglowPeakAlpha

            let path = NSBezierPath(
                roundedRect: rects[glow.index].insetBy(dx: -1, dy: -1),
                xRadius: Self.cornerRadius, yRadius: Self.cornerRadius
            )
            base.withAlphaComponent(alpha * Self.afterglowFillRatio).setFill()
            path.fill()
            path.lineWidth = 1.5
            base.withAlphaComponent(alpha).setStroke()
            path.stroke()
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
