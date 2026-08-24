import AppKit
import CourseMenu

// ─────────────────────────────────────────────────────────────────────────────
// The heatmap's hover popup: hover a non-empty day cell and a small panel lists
// the items due that day, each row a link into the signed-in browser.
//
// It is a borderless child WINDOW, not a drawn bubble, for two reasons the
// exp-16 bubble could not answer: the popup must extend past the menu item's
// bounds (a day near the grid's bottom edge would clip), and its rows must be
// CLICKABLE, which a painted bubble is not. The window recipe — borderless
// non-activating `NSPanel`, `canBecomeKey == false`, child of the anchor's own
// window — is RepoBar's autocomplete dropdown, which proved a panel like this
// receives its own mouse events without stealing key status from its host.
//
// Two menu-specific lessons are load-bearing here:
//
//   grace timer  — scheduled on RunLoop.main in `.common` mode, because a
//                  tracking menu spins `.eventTracking` and a `.default`-mode
//                  timer would simply never fire (measured, exp 12/16).
//   anchoring    — BELOW AND TO THE RIGHT of the cell, never centred on it.
//                  Centred, the popup covers the hovered cell's row neighbours
//                  and sliding along the row fights the popup for the pointer.
//                  Down-right leaves the whole row clear AND is the direction
//                  the safe-triangle grace period lets the pointer travel.
// ─────────────────────────────────────────────────────────────────────────────

/// The popup's geometry, pure and testable — the half that can be wrong in a
/// way a screenshot will not show. Frames speak SCREEN coordinates
/// (bottom-left origin, y upward), because that is the space `NSWindow.setFrame`
/// consumes and converting twice is where sign errors live.
public enum GraphPopupMetrics {
    /// The gap between the hovered cell and the popup's top-left corner, both
    /// axes. Small enough that the pointer's down-right travel crosses it
    /// within the grace period, large enough that the panel's shadow does not
    /// touch the cell.
    public static let anchorOffset: CGFloat = 4

    /// Where the popup goes: its top-left corner sits `offset` right of the
    /// cell's right edge and `offset` below its bottom edge. By construction
    /// the frame intersects neither the hovered cell nor anything in the
    /// cell's horizontal band — `minX > cell.maxX` and `maxY < cell.minY` —
    /// which is what lets the pointer slide along a row of cells without the
    /// popup ever sitting under it.
    public static func frame(
        anchoredTo cellScreenRect: CGRect,
        size: CGSize,
        offset: CGFloat = GraphPopupMetrics.anchorOffset
    ) -> CGRect {
        CGRect(
            x: cellScreenRect.maxX + offset,
            y: cellScreenRect.minY - offset - size.height,
            width: size.width,
            height: size.height
        )
    }

    // Content layout, one table like `ComponentMetrics` and for the same
    // reason: the size computation and the row placement read the same numbers.
    static let contentPadding: CGFloat = 10
    static let captionHeight: CGFloat = 15
    static let captionGap: CGFloat = 5
    static let rowHeight: CGFloat = 20
    /// Between a row's title and its kind label.
    static let kindGap: CGFloat = 14
    static let maximumWidth: CGFloat = 320
    static let cornerRadius: CGFloat = 6

    static func contentHeight(rows: Int) -> CGFloat {
        self.contentPadding * 2 + self.captionHeight + self.captionGap
            + CGFloat(rows) * self.rowHeight
    }
}

/// One popup per course component, owned by its `MenuItemHostingView`. Shows,
/// moves, and dismisses the panel; the grace delay lives here.
@MainActor
final class GraphDayPopupController {
    /// RepoBar's dropdown window class: a borderless panel must say explicitly
    /// that it never becomes key, or clicking a row deactivates the menu.
    private final class PopupPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// How long a dismiss trigger (empty cell, off the grid) waits before the
    /// panel actually goes — the safe-triangle budget for travelling down-right
    /// from the cell into the popup. Entering the popup cancels it.
    static let graceDelay: TimeInterval = 0.3

    private let opener: any URLOpening
    /// Closes the whole menu after a row click — supplied by the hosting view,
    /// which is the layer that knows a menu exists at all.
    private let dismissMenu: () -> Void

    private var panel: NSPanel?
    private var graceTimer: Timer?

    init(opener: any URLOpening, dismissMenu: @escaping () -> Void) {
        self.opener = opener
        self.dismissMenu = dismissMenu
    }

    /// Shows the popup for `detail`, anchored below-right of the hovered cell.
    /// Re-invoking with another cell's detail MOVES the one panel — a fresh
    /// window per cell would flicker its shadow on every step along a row.
    func show(_ detail: GraphDayDetail, anchoredTo cellScreenRect: CGRect, host: NSWindow?) {
        self.cancelGrace()

        let content = GraphPopupContentView(
            detail: detail,
            onClick: { [weak self] url in
                guard let self else { return }
                self.opener.open(url)
                self.dismiss()
                self.dismissMenu()
            },
            onHoverChange: { [weak self] inside in
                // The pointer arriving IN the popup is what the grace delay
                // exists for; leaving it is an ordinary dismiss trigger.
                inside ? self?.cancelGrace() : self?.scheduleDismiss()
            }
        )

        let panel = self.panel ?? self.makePanel()
        self.panel = panel
        panel.contentView = content
        panel.setFrame(
            GraphPopupMetrics.frame(anchoredTo: cellScreenRect, size: content.frame.size),
            display: true
        )
        // A child window rides its parent — and a menu's carrier window is a
        // real window — so the panel stays glued if the menu ever moves, and
        // sits above it in z-order without guessing at menu window levels.
        if let host, panel.parent == nil {
            host.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    /// The soft dismiss: the pointer left the trigger (empty cell, off the
    /// grid) but may be en route to the popup. Nothing happens for
    /// `graceDelay`; arriving in the popup cancels this, anything else lets it
    /// fire.
    func scheduleDismiss() {
        guard self.panel != nil, self.graceTimer == nil else { return }
        let timer = Timer(timeInterval: Self.graceDelay, repeats: false) { _ in
            // Timer's block is @Sendable; hop back to the actor by hand.
            Task { @MainActor [weak self] in self?.dismiss() }
        }
        // `.common` includes `.eventTracking`, the mode a tracking menu spins
        // in — in `.default` this timer would never fire while the menu is up.
        RunLoop.main.add(timer, forMode: .common)
        self.graceTimer = timer
    }

    /// The hard dismiss: highlight moved to another row, the menu closed, or
    /// the grace period expired. Immediate.
    func dismiss() {
        self.cancelGrace()
        guard let panel = self.panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
    }

    private func cancelGrace() {
        self.graceTimer?.invalidate()
        self.graceTimer = nil
    }

    private func makePanel() -> NSPanel {
        let panel = PopupPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.transient, .ignoresCycle]
        return panel
    }
}

/// The popup's content: a caption line, then one clickable row per item. Sizes
/// itself at init — the controller reads `frame.size` to place the window —
/// and is flipped so rows read top-down like the list they are.
final class GraphPopupContentView: NSView {
    private let onHoverChange: (Bool) -> Void

    override var isFlipped: Bool { true }

    init(detail: GraphDayDetail, onClick: @escaping (URL) -> Void, onHoverChange: @escaping (Bool) -> Void) {
        self.onHoverChange = onHoverChange

        // Width: the widest line wins, capped — a long assignment name
        // truncates in its row rather than dragging the panel across the menu.
        let caption = Self.captionString(detail.caption)
        let rowWidths = detail.items.map {
            GraphPopupRowView.title(of: $0).size().width
                + GraphPopupMetrics.kindGap + GraphPopupRowView.kindLabel(of: $0).size().width
        }
        let width = min(
            GraphPopupMetrics.maximumWidth,
            (([caption.size().width] + rowWidths).max() ?? 0) + GraphPopupMetrics.contentPadding * 2
        )
        super.init(frame: CGRect(
            x: 0, y: 0, width: width,
            height: GraphPopupMetrics.contentHeight(rows: detail.items.count)
        ))
        self.wantsLayer = true

        let pad = GraphPopupMetrics.contentPadding
        let captionField = NSTextField(labelWithAttributedString: caption)
        captionField.lineBreakMode = .byTruncatingTail
        captionField.frame = CGRect(
            x: pad, y: pad, width: width - pad * 2, height: GraphPopupMetrics.captionHeight
        )
        self.addSubview(captionField)

        for (index, item) in detail.items.enumerated() {
            let row = GraphPopupRowView(item: item, onClick: onClick)
            row.frame = CGRect(
                x: pad,
                y: pad + GraphPopupMetrics.captionHeight + GraphPopupMetrics.captionGap
                    + CGFloat(index) * GraphPopupMetrics.rowHeight,
                width: width - pad * 2,
                height: GraphPopupMetrics.rowHeight
            )
            self.addSubview(row)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GraphPopupContentView is built in code, never from a nib")
    }

    /// The panel is a bare window; the rounded card is drawn here. Popover
    /// background over a hairline border, matching how exp 16's bubble dressed
    /// itself, at panel scale.
    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(
            roundedRect: self.bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: GraphPopupMetrics.cornerRadius, yRadius: GraphPopupMetrics.cornerRadius
        )
        NSColor.windowBackgroundColor.setFill()
        card.fill()
        NSColor.separatorColor.setStroke()
        card.lineWidth = 1
        card.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in self.trackingAreas { self.removeTrackingArea(area) }
        // `.activeAlways`: the panel never becomes key, so the default
        // active-in-key-window scope would leave these areas permanently deaf.
        self.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { self.onHoverChange(true) }
    override func mouseExited(with event: NSEvent) { self.onHoverChange(false) }

    private static func captionString(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }
}

/// One clickable line: the item's name in link colour, a dim kind label
/// right-aligned after it. The whole row is the click target, not just the
/// text — an 11pt word is a poor thing to have to hit inside a menu.
final class GraphPopupRowView: NSView {
    private let item: GraphDayItem
    private let onClick: (URL) -> Void
    private var isHovered = false {
        didSet {
            guard oldValue != self.isHovered else { return }
            self.needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    init(item: GraphDayItem, onClick: @escaping (URL) -> Void) {
        self.item = item
        self.onClick = onClick
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GraphPopupRowView is built in code, never from a nib")
    }

    /// How a tier is named on screen. The renderer's word choice, exactly like
    /// the tier's fill colour — the contract sends the ranking, not prose.
    static func kindName(of tier: CellTier) -> String {
        switch tier {
        case .assignment: "assignment"
        case .quiz: "quiz"
        }
    }

    static func title(of item: GraphDayItem) -> NSAttributedString {
        NSAttributedString(string: item.title, attributes: [
            .font: NSFont.menuFont(ofSize: 13),
            .foregroundColor: NSColor.linkColor,
        ])
    }

    static func kindLabel(of item: GraphDayItem) -> NSAttributedString {
        NSAttributedString(string: Self.kindName(of: item.tier), attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        if self.isHovered {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: self.bounds, xRadius: 3, yRadius: 3).fill()
        }

        let kind = Self.kindLabel(of: self.item)
        let kindSize = kind.size()
        kind.draw(at: CGPoint(
            x: self.bounds.width - kindSize.width,
            y: (self.bounds.height - kindSize.height) / 2
        ))

        let title = Self.title(of: self.item)
        // Bounded drawing, not `draw(at:)`: a title longer than the space left
        // of the kind label must truncate rather than run underneath it.
        title.draw(
            with: CGRect(
                x: 0, y: (self.bounds.height - title.size().height) / 2,
                width: self.bounds.width - kindSize.width - GraphPopupMetrics.kindGap,
                height: title.size().height
            ),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in self.trackingAreas { self.removeTrackingArea(area) }
        self.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { self.isHovered = true }
    override func mouseExited(with event: NSEvent) { self.isHovered = false }

    override func mouseUp(with event: NSEvent) {
        self.onClick(self.item.url)
    }
}
