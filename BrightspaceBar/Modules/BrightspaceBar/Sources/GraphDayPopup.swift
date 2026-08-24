import AppKit
import CourseMenu

// ─────────────────────────────────────────────────────────────────────────────
// The heatmap's hover popup: hover a non-empty day cell and a small bubble lists
// the items due that day, each row a link into the signed-in browser.
//
// It is a SUBVIEW of the course row's own `MenuItemHostingView`, not a window.
// The first build floated a borderless NSPanel (RepoBar's autocomplete recipe),
// and hover worked while clicks never arrived: NSMenu's modal tracking session
// owns every mouse event while a menu is open, and a click on a window that is
// not the menu reads as "outside the menu" — it closes the menu (tearing the
// panel down) before the panel can hear anything. A local event monitor did not
// save it either; the tracking session takes events ahead of monitors.
//
// Experiments 9 → 14 → 16 proved the one place clicks ARE delivered during
// menu tracking: a menu item's own view. So the bubble lives in the row's view
// tree, where the tracking session treats a click on it as a click on the row —
// the exact path Open Course Home rides. The costs, accepted deliberately:
//
//   clipping   — the bubble must fit the row's bounds. It anchors below the
//                cell, flips above when the row's bottom edge would cut it,
//                and clamps horizontally. A day with many items may still
//                brush the row's edge; that beats a popup that cannot be
//                clicked at all.
//   dismissal  — SPATIAL, never timed (unchanged from the panel build): the
//                bubble lives exactly while the pointer is inside anchor-cell
//                ∪ bridge ∪ bubble, hit-tested on every exit signal.
// ─────────────────────────────────────────────────────────────────────────────

/// The popup's geometry, pure and testable — the half that can be wrong in a
/// way a screenshot will not show. `frame(anchoredTo:size:)` speaks whatever
/// space the anchor rect is in (screen or an unflipped view — the arithmetic
/// is identical: below the cell means smaller y); `within:` adds the row's
/// bounds and the flip/clamp the in-row bubble needs.
public enum GraphPopupMetrics {
    /// The gap between the hovered cell and the bubble's near edge, both axes.
    public static let anchorOffset: CGFloat = 4

    /// Where the popup goes: directly BELOW the cell, left-aligned with it —
    /// top edge `offset` under the cell, left edge on the cell's own left edge.
    /// Straight-down is the shortest possible pointer path (a diagonal
    /// placement was measured unreachable live).
    public static func frame(
        anchoredTo cellRect: CGRect,
        size: CGSize,
        offset: CGFloat = GraphPopupMetrics.anchorOffset
    ) -> CGRect {
        CGRect(
            x: cellRect.minX,
            y: cellRect.minY - offset - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// The in-row placement: below-left-aligned as above, then kept inside
    /// `bounds` — flipped ABOVE the cell when the row's bottom edge would clip
    /// it, slid horizontally when the right edge would. In an unflipped view
    /// "below the cell" is toward y = 0, so "clipped by the bottom" is
    /// `minY < 0`.
    public static func frame(
        anchoredTo cellRect: CGRect,
        size: CGSize,
        within bounds: CGRect,
        offset: CGFloat = GraphPopupMetrics.anchorOffset
    ) -> CGRect {
        var frame = self.frame(anchoredTo: cellRect, size: size, offset: offset)
        if frame.minY < bounds.minY {
            frame.origin.y = cellRect.maxY + offset
        }
        frame.origin.y = max(bounds.minY, min(frame.origin.y, bounds.maxY - size.height))
        frame.origin.x = max(bounds.minX, min(frame.origin.x, bounds.maxX - size.width))
        return frame
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

/// One popup per course component, owned by its `MenuItemHostingView` — which
/// is also its canvas: the bubble is installed as a subview of the host so its
/// clicks travel the menu-native path.
@MainActor
final class GraphDayPopupController {
    private let opener: any URLOpening
    /// Deletes one of the student's own items (Intent 4), or nil for a build
    /// without the feature — the ✕ then simply does not render.
    private let onDeleteItem: (@MainActor (UUID) -> Void)?
    /// Closes the whole menu after a row click — supplied by the hosting view,
    /// which is the layer that knows a menu exists at all.
    private let dismissMenu: () -> Void
    /// The row view the bubble draws into. Weak: the host owns the controller.
    private(set) weak var host: NSView?

    private var bubble: GraphPopupContentView?
    /// The hovered cell's rect in the HOST's coordinates — one leg of the
    /// spatial keep-alive region. Set by every `show`, cleared by `dismiss`.
    private var anchorRect: CGRect?

    /// Test seam: the shown bubble's frame (in host coordinates, unclamped
    /// when there is no host), or nil when nothing is showing. Exists because
    /// the zero-size regression (contentView installed before its size was
    /// read, in the panel era) was invisible to every headless assertion.
    var panelFrameForTesting: CGRect? { self.bubble?.frame }

    init(
        opener: any URLOpening,
        onDeleteItem: (@MainActor (UUID) -> Void)? = nil,
        host: NSView? = nil,
        dismissMenu: @escaping () -> Void
    ) {
        self.opener = opener
        self.onDeleteItem = onDeleteItem
        self.host = host
        self.dismissMenu = dismissMenu
    }

    /// Shows the bubble for `detail`, anchored below the hovered cell.
    /// `cellRect` is in the HOST view's coordinate space (callers convert; the
    /// tests pass arbitrary rects with no host and get the unclamped frame).
    /// Re-invoking with another cell's detail replaces the one bubble in place.
    func show(_ detail: GraphDayDetail, anchoredTo cellRect: CGRect) {
        self.anchorRect = cellRect

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
                // Close the menu FIRST — the exp-14 order (cancelTracking,
                // then act) — so the spawn never races menu teardown.
                self.dismiss()
                self.dismissMenu()
                self.opener.open(url)
            },
            onHoverChange: { [weak self] inside in
                // Leaving the bubble is a dismiss trigger like any other — and
                // like any other it only fires if the pointer is genuinely
                // outside the whole keep-alive region (it may have gone back
                // up into the grid, where hover will re-anchor the popup).
                if !inside { self?.dismissIfOutside() }
            }
        )

        let size = content.frame.size
        content.frame = self.host.map { host in
            GraphPopupMetrics.frame(anchoredTo: cellRect, size: size, within: host.bounds)
        } ?? GraphPopupMetrics.frame(anchoredTo: cellRect, size: size)

        self.bubble?.removeFromSuperview()
        self.bubble = content
        // On TOP of the SwiftUI hosting view — subview order is z-order.
        self.host?.addSubview(content)
    }

    /// The conditional dismiss — every "the pointer left X" signal lands here.
    ///
    /// SPATIAL, not timed: the bubble lives exactly while the pointer is inside
    /// the keep-alive region (hovered cell ∪ the bridge over the anchor gap ∪
    /// the bubble itself, each with a hairline of slack for event rounding).
    /// One rule, asked at the moment of every exit event, with the pointer's
    /// REAL position (`NSEvent.mouseLocation`, screen coordinates, available
    /// without an event).
    func dismissIfOutside() {
        guard self.bubble != nil else { return }
        let pointer = self.pointerInHostCoordinates()
        if self.keepAliveRegion().contains(where: { $0.contains(pointer) }) { return }
        self.dismiss()
    }

    /// `NSEvent.mouseLocation` is screen space; the region is host space.
    /// With no window (headless tests) the point cannot be converted and the
    /// region can never contain it — dismissal-by-position degrades to always
    /// dismissing, which is the safe direction.
    private func pointerInHostCoordinates() -> CGPoint {
        guard let host = self.host, let window = host.window else {
            return CGPoint(x: -.greatestFiniteMagnitude, y: -.greatestFiniteMagnitude)
        }
        return host.convert(
            window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil
        )
    }

    /// The rects whose union keeps the bubble alive, in host coordinates. The
    /// bridge spans the `anchorOffset` gap between the cell's bottom and the
    /// bubble's top — without it the union is disconnected and crossing the
    /// gap would read as "outside". (Unflipped: the bubble sits at SMALLER y
    /// than the cell, except when it flipped above.)
    private func keepAliveRegion() -> [CGRect] {
        var region: [CGRect] = []
        if let bubble = self.bubble { region.append(bubble.frame.insetBy(dx: -1, dy: -1)) }
        if let cell = self.anchorRect {
            region.append(cell.insetBy(dx: -2, dy: -2))
            if let bubble = self.bubble {
                let gapBottom = min(cell.minY, bubble.frame.maxY)
                let gapTop = max(cell.minY, bubble.frame.maxY)
                region.append(CGRect(
                    x: bubble.frame.minX, y: gapBottom,
                    width: bubble.frame.width, height: gapTop - gapBottom
                ))
            }
        }
        return region
    }

    /// The unconditional dismiss: the menu closed, a row was clicked, or the
    /// spatial rule decided. Immediate.
    func dismiss() {
        self.bubble?.removeFromSuperview()
        self.bubble = nil
        self.anchorRect = nil
        self.host?.needsDisplay = true
    }
}

/// The popup's content: a caption line, then one clickable row per item. Sizes
/// itself at init — the controller reads `frame.size` to place it — and is
/// flipped so rows read top-down like the list they are.
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
        // truncates in its row rather than dragging the bubble across the row.
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

    /// Routes a click that landed on the bubble but not on a row's own view
    /// (the caption, the padding) — and the seam the hosting view can call if
    /// an event ever arrives at the row level instead. Finds the row under
    /// the point and runs the same action a direct mouseUp would have.
    func performClick(at point: CGPoint) {
        for case let row as GraphPopupRowView in self.subviews
        where row.frame.contains(point) {
            row.performClick(at: self.convert(point, to: row))
            return
        }
    }

    /// The bubble draws its own card: popover background over a hairline
    /// border — exp 16's bubble dress, at list scale.
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
        // `.activeAlways`: a menu's carrier window is never key, so the default
        // active-in-key-window scope would leave these areas permanently deaf.
        self.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { self.onHoverChange(true) }
    override func mouseExited(with event: NSEvent) { self.onHoverChange(false) }

    /// Clicks on the bubble's chrome (caption, padding) must not fall through
    /// the responder chain to `MenuItemHostingView.mouseUp`, which would fire
    /// the ROW's action for a click the user aimed at the popup.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        self.performClick(at: self.convert(event.locationInWindow, from: nil))
    }

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

    static func title(of item: GraphDayItem, hovered: Bool = false) -> NSAttributedString {
        NSAttributedString(string: item.title, attributes: [
            .font: NSFont.menuFont(ofSize: 13),
            .foregroundColor: hovered ? NSColor.selectedMenuItemTextColor : NSColor.linkColor,
        ])
    }

    static func kindLabel(of item: GraphDayItem, hovered: Bool = false) -> NSAttributedString {
        NSAttributedString(string: Self.kindName(of: item.tier), attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: hovered
                ? NSColor.selectedMenuItemTextColor.withAlphaComponent(0.7)
                : NSColor.tertiaryLabelColor,
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        if self.isHovered {
            // The menu's own selection blue (exp 12's highlight treatment,
            // extended here): a popup row under the pointer reads exactly like
            // a highlighted menu row, white text included.
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: self.bounds, xRadius: 4, yRadius: 4).fill()
        }

        // A simple ✕ (user decision: no confirm, no management list), drawn
        // only while the row is hovered so unhovered rows stay clean.
        var trailingInset: CGFloat = 0
        if self.showsDelete {
            trailingInset = self.deleteRect.width + 2
            if self.isHovered {
                let x = NSAttributedString(string: "✕", attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: self.isHovered
                        ? NSColor.selectedMenuItemTextColor.withAlphaComponent(0.8)
                        : NSColor.secondaryLabelColor,
                ])
                let size = x.size()
                x.draw(at: CGPoint(
                    x: self.deleteRect.midX - size.width / 2,
                    y: (self.bounds.height - size.height) / 2
                ))
            }
        }

        let kind = Self.kindLabel(of: self.item, hovered: self.isHovered)
        let kindSize = kind.size()
        kind.draw(at: CGPoint(
            x: self.bounds.width - trailingInset - kindSize.width,
            y: (self.bounds.height - kindSize.height) / 2
        ))

        let title = Self.title(of: self.item, hovered: self.isHovered)
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

    /// The menu-native click path (exp 9/14/16): the tracking session delivers
    /// the event to the deepest view under the pointer — this row — because
    /// the bubble lives in the menu item's own view tree.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        self.performClick(at: self.convert(event.locationInWindow, from: nil))
    }

    /// The one click action, shared by the direct path and the content view's
    /// fall-through hit-test.
    func performClick(at point: CGPoint) {
        if self.showsDelete, self.deleteRect.contains(point), let id = self.item.manualId {
            self.onDelete?(id)
            return
        }
        self.onClick(self.item.url)
    }
}
