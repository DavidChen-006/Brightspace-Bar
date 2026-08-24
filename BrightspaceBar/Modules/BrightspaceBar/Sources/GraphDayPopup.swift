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
//   dismissal    — SPATIAL, never timed. The popup lives exactly while the
//                  pointer is inside anchor-cell ∪ 4px bridge ∪ panel, the
//                  same hit-test-on-every-move rule Floating UI's safePolygon,
//                  Radix HoverCard, and NSPopover use. A timer-based grace
//                  (two earlier attempts) either expired mid-travel or held
//                  the popup open over cells the user had plainly left.
//   anchoring    — DIRECTLY BELOW the cell, left-aligned, never centred on it
//                  and never diagonal. Centred, the popup covers the hovered
//                  cell's row neighbours; diagonal (the first attempt) put it
//                  further away than the grace period lets a pointer travel —
//                  measured live: the popup expired before it could be reached.
//                  Straight down is the shortest path and keeps the row clear.
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

    /// Where the popup goes: directly BELOW the cell, left-aligned with it —
    /// top edge `offset` under the cell, left edge on the cell's own left edge.
    /// Straight-down is the shortest possible pointer path (the first, diagonal
    /// down-right placement was measured unreachable live: by the time the
    /// pointer had crossed the diagonal the grace period had expired). The
    /// frame still intersects nothing in the cell's horizontal band
    /// (`maxY < cell.minY`), so sliding along a row never fights the popup;
    /// covering the rows BELOW is acceptable because hover moves the popup
    /// with the cell and the grace period only ends on an empty target.
    public static func frame(
        anchoredTo cellScreenRect: CGRect,
        size: CGSize,
        offset: CGFloat = GraphPopupMetrics.anchorOffset
    ) -> CGRect {
        CGRect(
            x: cellScreenRect.minX,
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

    private let opener: any URLOpening
    /// Deletes one of the student's own items (Intent 4), or nil for a build
    /// without the feature — the ✕ then simply does not render.
    private let onDeleteItem: (@MainActor (UUID) -> Void)?
    /// Closes the whole menu after a row click — supplied by the hosting view,
    /// which is the layer that knows a menu exists at all.
    private let dismissMenu: () -> Void

    private var panel: NSPanel?
    /// The hovered cell's screen rect — one leg of the spatial keep-alive
    /// region. Set by every `show`, cleared by `dismiss`.
    private var anchorScreenRect: CGRect?

    /// Test seam: the shown panel's frame, or nil when nothing is showing.
    /// Exists because the zero-size regression (contentView installed before
    /// its size was read) was invisible to every headless assertion we had.
    var panelFrameForTesting: CGRect? { self.panel?.frame }

    init(
        opener: any URLOpening,
        onDeleteItem: (@MainActor (UUID) -> Void)? = nil,
        dismissMenu: @escaping () -> Void
    ) {
        self.opener = opener
        self.onDeleteItem = onDeleteItem
        self.dismissMenu = dismissMenu
    }

    /// Shows the popup for `detail`, anchored below-right of the hovered cell.
    /// Re-invoking with another cell's detail MOVES the one panel — a fresh
    /// window per cell would flicker its shadow on every step along a row.
    func show(_ detail: GraphDayDetail, anchoredTo cellScreenRect: CGRect, host: NSWindow?) {
        self.anchorScreenRect = cellScreenRect

        let content = GraphPopupContentView(
            detail: detail,
            onDelete: self.onDeleteItem.map { delete in
                { [weak self] id in
                    // Delete, then close everything: the menu model is rebuilt
                    // on the next open with the item (and its square) gone.
                    delete(id)
                    guard let self else { return }
                    self.dismiss()
                    self.dismissMenu()
                }
            },
            onClick: { [weak self] url in
                guard let self else { return }
                self.opener.open(url)
                self.dismiss()
                self.dismissMenu()
            },
            onHoverChange: { [weak self] inside in
                // Leaving the panel is a dismiss trigger like any other — and
                // like any other it only fires if the pointer is genuinely
                // outside the whole keep-alive region (it may have gone back
                // up into the grid, where hover will re-anchor the popup).
                if !inside { self?.dismissIfOutside() }
            }
        )

        let panel = self.panel ?? self.makePanel()
        self.panel = panel
        // Size FIRST, install second. Assigning `contentView` resizes the view
        // to the window's current content rect — `.zero` on the fresh panel —
        // so reading `content.frame.size` after installation answers 0×0 and
        // the panel becomes an invisible zero-size window (the live bug:
        // hover ring, no popup). `setFrame` then stretches the installed view
        // back to the size it laid itself out for.
        let size = content.frame.size
        panel.contentView = content
        panel.setFrame(
            GraphPopupMetrics.frame(anchoredTo: cellScreenRect, size: size),
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

    /// The conditional dismiss — every "the pointer left X" signal lands here.
    ///
    /// SPATIAL, not timed: the popup lives exactly while the pointer is inside
    /// the keep-alive region (hovered cell ∪ the bridge over the anchor gap ∪
    /// the panel itself, each with a hairline of slack for event rounding).
    /// One rule, asked at the moment of every exit event, with the pointer's
    /// REAL position (`NSEvent.mouseLocation`, screen coordinates, available
    /// without an event) — so travelling into the popup keeps it, and leaving
    /// everything kills it the instant the exit fires, not half a second later.
    func dismissIfOutside() {
        guard self.panel != nil else { return }
        if self.keepAliveRegion().contains(where: { $0.contains(NSEvent.mouseLocation) }) { return }
        self.dismiss()
    }

    /// The rects whose union keeps the popup alive. The bridge spans the
    /// `anchorOffset` gap between the cell's bottom and the panel's top, the
    /// panel's width — without it the union is disconnected and crossing the
    /// gap would read as "outside".
    private func keepAliveRegion() -> [CGRect] {
        var region: [CGRect] = []
        if let panel = self.panel { region.append(panel.frame.insetBy(dx: -1, dy: -1)) }
        if let cell = self.anchorScreenRect {
            region.append(cell.insetBy(dx: -2, dy: -2))
            if let panel = self.panel {
                region.append(CGRect(
                    x: panel.frame.minX, y: panel.frame.maxY,
                    width: panel.frame.width, height: max(0, cell.minY - panel.frame.maxY)
                ))
            }
        }
        return region
    }

    /// The unconditional dismiss: the menu closed, a row was clicked, or the
    /// spatial rule decided. Immediate.
    func dismiss() {
        guard let panel = self.panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
        self.anchorScreenRect = nil
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

    init(
        detail: GraphDayDetail,
        onDelete: ((UUID) -> Void)? = nil,
        onClick: @escaping (URL) -> Void,
        onHoverChange: @escaping (Bool) -> Void
    ) {
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
            let row = GraphPopupRowView(item: item, onDelete: onDelete, onClick: onClick)
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
    private let onDelete: ((UUID) -> Void)?
    private let onClick: (URL) -> Void
    private var isHovered = false {
        didSet {
            guard oldValue != self.isHovered else { return }
            self.needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    init(item: GraphDayItem, onDelete: ((UUID) -> Void)? = nil, onClick: @escaping (URL) -> Void) {
        self.item = item
        self.onDelete = onDelete
        self.onClick = onClick
        super.init(frame: .zero)
    }

    /// The ✕ renders only on the student's own items with a deleter wired —
    /// fetched rows have nothing to delete (a refresh restores them anyway).
    private var showsDelete: Bool { self.item.manualId != nil && self.onDelete != nil }

    /// Where the ✕ hit-target sits: the row's trailing edge, past the kind
    /// label, full row height so it is comfortable to hit at 11pt.
    private var deleteRect: CGRect {
        CGRect(x: self.bounds.width - 16, y: 0, width: 16, height: self.bounds.height)
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
        case .test: "test"
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

        // A simple ✕ (user decision: no confirm, no management list), drawn
        // only while the row is hovered so unhovered rows stay clean.
        var trailingInset: CGFloat = 0
        if self.showsDelete {
            trailingInset = self.deleteRect.width + 2
            if self.isHovered {
                let x = NSAttributedString(string: "✕", attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ])
                let size = x.size()
                x.draw(at: CGPoint(
                    x: self.deleteRect.midX - size.width / 2,
                    y: (self.bounds.height - size.height) / 2
                ))
            }
        }

        let kind = Self.kindLabel(of: self.item)
        let kindSize = kind.size()
        kind.draw(at: CGPoint(
            x: self.bounds.width - trailingInset - kindSize.width,
            y: (self.bounds.height - kindSize.height) / 2
        ))

        let title = Self.title(of: self.item)
        // Bounded drawing, not `draw(at:)`: a title longer than the space left
        // of the kind label must truncate rather than run underneath it.
        title.draw(
            with: CGRect(
                x: 0, y: (self.bounds.height - title.size().height) / 2,
                width: self.bounds.width - trailingInset - kindSize.width - GraphPopupMetrics.kindGap,
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
        let point = self.convert(event.locationInWindow, from: nil)
        if self.showsDelete, self.deleteRect.contains(point), let id = self.item.manualId {
            self.onDelete?(id)
            return
        }
        self.onClick(self.item.url)
    }
}
