import AppKit
import CourseMenu
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// One course = one menu item = one view (NewVertical-3.md §3.5).
//
// AppKit can highlight an item, never a pair of them, so the course name and its
// activity graph have to BE one item to light up together. A view-backed item
// replaces native rendering wholesale, which means everything AppKit used to do
// for free is done here by hand — and each hand-made piece is a finding from
// experiment 9, not a style choice:
//
//   highlight capsule — hand-drawn      (AppKit draws none for a view item)
//   highlight signal  — hand-delivered  (NSMenuDelegate.menu(_:willHighlight:))
//   click             — hand-forwarded  (mouseUp → performActionForItem)
//   submenu chevron   — hand-drawn      (no arrow for a view item)
//   height            — hand-computed   (a .zero frame renders an invisible row)
//
// The layering, and the seam is deliberate: SwiftUI for the heterogeneous
// surroundings that will reflow (badges, due counts, wrapping titles), direct
// drawing for the dense uniform cells.
//
//   MenuItemHostingView   AppKit  — highlight, chevron, click, frame
//   └ CourseCardView      SwiftUI — the title today; the badges later
//     └ CourseGraphView   SwiftUI — sizing + accessibility only
//       └ GraphRasterView NSViewRepresentable
//         └ GraphRasterNSView AppKit — the cells, drawn
//
// Known debt (§3.5): heights are arithmetic, not measured. The moment a title
// genuinely wraps, this becomes RepoBar's `measuredHeight` — measure at width,
// pixel-round, cache by (width, content version). Not before.
// ─────────────────────────────────────────────────────────────────────────────

/// Every metric the component is laid out from. One table, because the SwiftUI
/// layers lay content out from the same numbers the frame arithmetic predicts —
/// two tables would silently disagree and the row would clip.
public enum ComponentMetrics {
    /// Native menu rows lead their text by ~14pt inside the highlight capsule.
    public static let textInset: CGFloat = 14
    /// The capsule, inset from the item edge. RepoBar's 6/2/6, verified against
    /// real menu rows in experiment 9.
    static let highlightInsetX: CGFloat = 6
    static let highlightInsetY: CGFloat = 2
    static let highlightRadius: CGFloat = 6

    public static let cellSide: CGFloat = 8
    public static let cellGap: CGFloat = 2
    static let cellRadius: CGFloat = 2
    /// Cell to cell, stated once: the grid's only spacing arithmetic.
    static var cellStep: CGFloat { self.cellSide + self.cellGap }
    /// A week is a column, so the grid is seven deep for every window.
    static let rowsPerColumn = 7

    /// Reserved above the grid for the month headings.
    public static let monthRowHeight: CGFloat = 12
    /// Reserved left of it for the M/W/F letters.
    public static let weekdayGutter: CGFloat = 18

    static let titleHeight: CGFloat = 17
    /// Between the title baseline row and the graph.
    static let rowGap: CGFloat = 5
    static let verticalPad: CGFloat = 6
    /// A menu never looks right narrower than this, whatever the content is.
    static let minimumWidth: CGFloat = 240

    /// Where each cell of a flat window lands, read as columns of seven.
    ///
    /// The whole of the grid's geometry, and pure — `column = i / 7`,
    /// `row = i % 7`, row 0 (Sunday) at the TOP, which §3.3's week-aligned window
    /// makes true of every window rather than of this one. Rects are in a
    /// top-left-origin, y-downward space; `GraphRasterNSView` is `isFlipped` so
    /// they are used verbatim.
    ///
    /// `origin` is the grid's top-left corner, which is not the view's: the
    /// labels push the grid right by `weekdayGutter` and down by
    /// `monthRowHeight`.
    public static func gridRects(count: Int, origin: CGPoint) -> [CGRect] {
        (0..<max(count, 0)).map { index in
            CGRect(
                x: origin.x + CGFloat(index / self.rowsPerColumn) * self.cellStep,
                y: origin.y + CGFloat(index % self.rowsPerColumn) * self.cellStep,
                width: self.cellSide, height: self.cellSide
            )
        }
    }

    static func gridWidth(cells: Int) -> CGFloat {
        let columns = CGFloat((max(cells, 0) + self.rowsPerColumn - 1) / self.rowsPerColumn)
        return columns * self.cellSide + max(columns - 1, 0) * self.cellGap
    }

    static var gridHeight: CGFloat {
        CGFloat(self.rowsPerColumn) * self.cellSide + CGFloat(self.rowsPerColumn - 1) * self.cellGap
    }

    /// What the item's frame must be. `NSMenuItem.view` is not laid out for you:
    /// AppKit honours this number and computes nothing, so a course with cells
    /// has to ask for the extra height itself — and a grid is seven rows and a
    /// heading row, not the one row the strip was, so a frame left at the strip's
    /// height clips six rows away and reads as "not much is due".
    public static func fittingSize(cells: Int) -> CGSize {
        guard cells > 0 else {
            return CGSize(
                width: max(self.minimumWidth, self.textInset * 2),
                height: self.verticalPad * 2 + self.titleHeight
            )
        }
        return CGSize(
            width: max(
                self.minimumWidth,
                self.textInset * 2 + self.weekdayGutter + self.gridWidth(cells: cells)
            ),
            height: self.verticalPad * 2 + self.titleHeight + self.rowGap
                + self.monthRowHeight + self.gridHeight
        )
    }
}

/// The AppKit adapter in: what an `NSMenuItem` hosts, and the only layer that
/// knows this view lives in a menu at all.
@MainActor
public final class MenuItemHostingView: NSView {
    public let cells: [GraphCell]
    public let title: String
    /// AppKit draws no submenu arrow for a view-backed item, so a row that owns
    /// one has to say so itself — otherwise the submenu exists with nothing on
    /// screen suggesting it does.
    public let showsChevron: Bool
    /// One entry per week column of `cells`, nil where no month begins. Derived
    /// from the calendar in `GraphTranslation` — the renderer has no dates and
    /// draws whatever strings it is handed, over whatever columns exist.
    public let monthLabels: [String?]

    /// The "This week" block rendered right of the grid — pre-formatted by the
    /// adapter, drawn verbatim here. Empty renders nothing and the row keeps
    /// its pre-stats layout.
    public let weekLines: [String]

    /// Set by the menu delegate. The ONE highlight signal AppKit gives us, and
    /// it arrives on the delegate rather than on the view, which is why the
    /// assembler has to own the plumbing.
    public var isHighlightedForMenu = false {
        didSet {
            guard oldValue != self.isHighlightedForMenu else { return }
            // Losing the highlight gets the GRACE dismiss, not the hard one:
            // the popup hangs BELOW the row, so the pointer travelling into it
            // necessarily exits this item (de-highlighting it) on the way —
            // an immediate dismiss here made the popup untouchable (user
            // report, 2026-08-24). Arriving in the popup cancels the grace;
            // genuinely leaving lets it fire.
            if !self.isHighlightedForMenu { self.popup?.scheduleDismiss() }
            self.hosting.rootView = self.card
            self.needsDisplay = true
        }
    }

    private let hosting: NSHostingView<CourseCardView>
    /// The hover popup for this course's day cells, or nil when the assembler
    /// gave no opener — the headless-test shape, where no popup can exist and
    /// hovering degrades to nothing rather than to a crash.
    private var popup: GraphDayPopupController?

    public init(
        title: String, cells: [GraphCell], showsChevron: Bool, monthLabels: [String?] = [],
        weekLines: [String] = [],
        opener: (any URLOpening)? = nil,
        onDeleteItem: (@MainActor (UUID) -> Void)? = nil
    ) {
        self.title = title
        self.cells = cells
        self.showsChevron = showsChevron
        self.monthLabels = monthLabels
        self.weekLines = weekLines
        self.hosting = NSHostingView(
            rootView: CourseCardView(
                title: title, cells: cells, monthLabels: monthLabels, weekLines: weekLines,
                isHighlighted: false, popup: nil
            )
        )
        super.init(frame: CGRect(origin: .zero, size: ComponentMetrics.fittingSize(cells: cells.count)))
        // Stretch to the menu's final width, so the capsule spans the row like a
        // native item's does instead of stopping at our content.
        self.autoresizingMask = [.width]
        self.hosting.frame = self.bounds
        self.hosting.autoresizingMask = [.width, .height]
        self.addSubview(self.hosting)

        // After super.init, because closing the menu on a popup click needs
        // `self` — this view is the one layer that knows a menu exists at all.
        if let opener {
            self.popup = GraphDayPopupController(opener: opener, onDeleteItem: onDeleteItem) { [weak self] in
                self?.enclosingMenuItem?.menu?.cancelTracking()
            }
            self.hosting.rootView = self.card
        }
    }

    /// Leaving the window (the menu closed) must take the popup along — a child
    /// window is removed with its parent, but the controller's state has to
    /// agree that nothing is showing.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if self.window == nil { self.popup?.dismiss() }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("MenuItemHostingView is built in code, never from a nib")
    }

    private var card: CourseCardView {
        CourseCardView(
            title: self.title, cells: self.cells, monthLabels: self.monthLabels,
            weekLines: self.weekLines,
            isHighlighted: self.isHighlightedForMenu, popup: self.popup
        )
    }

    /// Only the two things that sit *behind* and *beside* the SwiftUI content:
    /// the capsule (subviews draw over it) and the chevron, which lands in the
    /// trailing margin the card leaves empty.
    public override func draw(_ dirtyRect: NSRect) {
        guard self.isHighlightedForMenu || self.showsChevron else { return }

        if self.isHighlightedForMenu {
            let capsule = self.bounds.insetBy(
                dx: ComponentMetrics.highlightInsetX, dy: ComponentMetrics.highlightInsetY
            )
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(
                roundedRect: capsule,
                xRadius: ComponentMetrics.highlightRadius,
                yRadius: ComponentMetrics.highlightRadius
            ).fill()
        }

        guard self.showsChevron else { return }
        let chevron = NSAttributedString(string: "❯", attributes: [
            .font: NSFont.menuFont(ofSize: 11),
            .foregroundColor: self.isHighlightedForMenu
                ? NSColor.selectedMenuItemTextColor : NSColor.tertiaryLabelColor,
        ])
        chevron.draw(at: CGPoint(
            x: self.bounds.width - ComponentMetrics.textInset - chevron.size().width,
            y: self.bounds.height - ComponentMetrics.verticalPad - ComponentMetrics.titleHeight + 2
        ))
    }

    /// AppKit delivers the event to the view, not to the item, so a view-backed
    /// row is silently unclickable unless it forwards. A row that owns a submenu
    /// is left alone: AppKit refuses to fire its action anyway, and cancelling
    /// tracking here would close the submenu the user was reaching for.
    public override func mouseUp(with event: NSEvent) {
        guard
            let item = self.enclosingMenuItem, item.submenu == nil,
            let menu = item.menu, let index = menu.items.firstIndex(of: item)
        else { return }
        menu.cancelTracking()
        menu.performActionForItem(at: index)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SwiftUI: the surroundings
// ─────────────────────────────────────────────────────────────────────────────

/// The card: everything a course row says about itself. Today that is the title
/// and the graph. What lands here later — and the reason this layer is SwiftUI
/// rather than more drawing code — is the heterogeneous, reflowing content:
/// unread/overdue badges, a due-count, status symbols, and a title allowed to
/// wrap. Those are stack-and-spacer problems, not geometry problems.
struct CourseCardView: View {
    let title: String
    let cells: [GraphCell]
    let monthLabels: [String?]
    var weekLines: [String] = []
    let isHighlighted: Bool
    /// Threaded down to the raster view, which is where hover is detected.
    /// A reference, not data — the popup is a side-effect port like `opener`.
    let popup: GraphDayPopupController?

    var body: some View {
        VStack(alignment: .leading, spacing: ComponentMetrics.rowGap) {
            Text(self.title)
                .font(Font(NSFont.menuFont(ofSize: 0)))
                // Over the accent capsule, label colour is unreadable — the swap
                // is required, not cosmetic (§5).
                .foregroundStyle(Color(
                    self.isHighlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor
                ))
                .lineLimit(1)
                .frame(height: ComponentMetrics.titleHeight, alignment: .leading)

            if !self.cells.isEmpty {
                // The stats ride BESIDE the grid — the space to its right was
                // empty by construction (the row stretches to the menu's width)
                // and "what's hitting me this week, and what's first" is the one
                // question the squares can't answer at a glance.
                HStack(alignment: .top, spacing: ComponentMetrics.textInset) {
                    CourseGraphView(
                        cells: self.cells, monthLabels: self.monthLabels,
                        isHighlighted: self.isHighlighted, popup: self.popup
                    )
                    if !self.weekLines.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(self.weekLines.enumerated()), id: \.offset) { index, line in
                                // Line 0 is the "This week" heading — semibold
                                // and label-strength, naming the window the
                                // dimmer lines under it describe.
                                Text(line)
                                    .font(.system(size: 10, weight: index == 0 ? .semibold : .regular))
                                    .foregroundStyle(Color(
                                        self.isHighlighted
                                            ? NSColor.selectedMenuItemTextColor
                                            : index == 0 ? NSColor.labelColor : NSColor.secondaryLabelColor
                                    ))
                                    .lineLimit(1)
                            }
                        }
                        // Under the month row, level with the grid's top edge.
                        .padding(.top, ComponentMetrics.monthRowHeight)
                    }
                }
            }
        }
        .padding(.horizontal, ComponentMetrics.textInset)
        .padding(.vertical, ComponentMetrics.verticalPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Sizing and accessibility only. The cells themselves are drawn a layer down:
/// dense uniform geometry is where direct drawing beats declarative layout, and
/// this is the seam between the two (§3.5).
struct CourseGraphView: View {
    let cells: [GraphCell]
    let monthLabels: [String?]
    let isHighlighted: Bool
    let popup: GraphDayPopupController?

    var body: some View {
        GraphRasterView(
            cells: self.cells, monthLabels: self.monthLabels, isHighlighted: self.isHighlighted,
            popup: self.popup
        )
        .frame(
            width: ComponentMetrics.weekdayGutter + ComponentMetrics.gridWidth(cells: self.cells.count),
            height: ComponentMetrics.monthRowHeight + ComponentMetrics.gridHeight
        )
        .accessibilityLabel(self.label)
    }

    /// VoiceOver cannot read a drawing, and the drawing is the whole content.
    private var label: String {
        let busy = self.cells.count { $0.tier != nil }
        return busy == 0
            ? "No work due in the coming days"
            : "\(busy) day\(busy == 1 ? "" : "s") with work due"
    }
}

/// The adapter back out to AppKit.
struct GraphRasterView: NSViewRepresentable {
    let cells: [GraphCell]
    let monthLabels: [String?]
    let isHighlighted: Bool
    let popup: GraphDayPopupController?

    func makeNSView(context: Context) -> GraphRasterNSView {
        GraphRasterNSView(
            cells: self.cells, monthLabels: self.monthLabels, isHighlighted: self.isHighlighted,
            popup: self.popup
        )
    }

    func updateNSView(_ view: GraphRasterNSView, context: Context) {
        view.isHighlighted = self.isHighlighted
        // Re-attached on every update, because the hosting view swaps its root
        // on each highlight change and the port must survive the swap.
        view.popup = self.popup
    }
}

/// The grid, drawn. Immediate mode, no cache and no per-cell object: derivation
/// is microseconds and the menu is closed almost always (§3.2). The geometry is
/// `ComponentMetrics.gridRects` and lives there because it is the half that can
/// be wrong in a way a screenshot will not show; this layer only paints.
///
/// `isFlipped` is true, deliberately. `gridRects` speaks a top-left-origin,
/// y-downward space so that "row 0 is Sunday, at the top" is the smallest y,
/// and flipping the view lets those rects be used verbatim — the alternative
/// (§5) is subtracting every one of them from `bounds.height`, which is the same
/// arithmetic written once per drawing call instead of never. Text draws
/// correctly in a flipped view; `NSAttributedString.draw(at:)` takes the
/// string's top-left corner here.
final class GraphRasterNSView: NSView {
    private let cells: [GraphCell]
    private let monthLabels: [String?]

    var isHighlighted: Bool {
        didSet {
            guard oldValue != self.isHighlighted else { return }
            self.needsDisplay = true
        }
    }

    /// The hover popup's port, or nil in headless builds. Weak on purpose:
    /// the controller is the hosting view's, and a raster view recreated by
    /// SwiftUI must not keep a stale one alive.
    weak var popup: GraphDayPopupController?

    /// The day cell under the pointer, tracked for the hover ring. Only cells
    /// with a `detail` are ever hovered — an empty day is a dismiss trigger,
    /// not a target, so it gets no ring and no popup.
    private var hoveredIndex: Int? {
        didSet {
            guard oldValue != self.hoveredIndex else { return }
            self.needsDisplay = true
        }
    }

    /// The grid's top-left corner inside this view: the gutters the labels need.
    private static let gridOrigin = CGPoint(
        x: ComponentMetrics.weekdayGutter, y: ComponentMetrics.monthRowHeight
    )

    override var isFlipped: Bool { true }

    init(cells: [GraphCell], monthLabels: [String?], isHighlighted: Bool,
         popup: GraphDayPopupController? = nil) {
        self.cells = cells
        self.monthLabels = monthLabels
        self.isHighlighted = isHighlighted
        self.popup = popup
        super.init(frame: CGRect(
            origin: .zero,
            size: CGSize(
                width: ComponentMetrics.weekdayGutter + ComponentMetrics.gridWidth(cells: cells.count),
                height: ComponentMetrics.monthRowHeight + ComponentMetrics.gridHeight
            )
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GraphRasterNSView is built in code, never from a nib")
    }

    // MARK: - Hover (Intent 2 — the day popup)

    /// The exp-16 recipe, verbatim: `.activeAlways` because a menu's carrier
    /// window is never key, and `.inVisibleRect` so the area needs no manual
    /// resize plumbing.
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
        let point = self.convert(event.locationInWindow, from: nil)
        let rects = ComponentMetrics.gridRects(count: self.cells.count, origin: Self.gridOrigin)
        // Inset by the gutter's half, so the 2pt gap between cells does not
        // flicker the hover off between neighbours (exp 16's tolerance).
        let index = rects.firstIndex { $0.insetBy(dx: -1, dy: -1).contains(point) }

        // Only a cell with a detail is a hover target; an empty cell — like
        // leaving the grid — is a dismiss trigger, softened by the grace delay
        // so the pointer can travel down-right into the popup.
        guard let index, let detail = self.cells[index].detail else {
            self.hoveredIndex = nil
            self.popup?.scheduleDismiss()
            return
        }
        guard index != self.hoveredIndex else { return }
        self.hoveredIndex = index
        guard let window = self.window else { return }
        self.popup?.show(
            detail,
            anchoredTo: window.convertToScreen(self.convert(rects[index], to: nil)),
            host: window
        )
    }

    override func mouseExited(with event: NSEvent) {
        self.hoveredIndex = nil
        self.popup?.scheduleDismiss()
    }

    override func draw(_ dirtyRect: NSRect) {
        let rects = ComponentMetrics.gridRects(count: self.cells.count, origin: Self.gridOrigin)
        self.drawLabels(over: rects)

        for (cell, rect) in zip(self.cells, rects) {
            self.fillColor(for: cell.tier).setFill()
            NSBezierPath(
                roundedRect: rect,
                xRadius: ComponentMetrics.cellRadius, yRadius: ComponentMetrics.cellRadius
            ).fill()

            guard cell.isToday else { continue }
            // Stroked AFTER the fill and inset by half a line width, so today's
            // marker sits on the cell's own edge rather than covering the tier
            // colour that says what is actually due.
            let outline = NSBezierPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                xRadius: ComponentMetrics.cellRadius, yRadius: ComponentMetrics.cellRadius
            )
            outline.lineWidth = 1
            (self.isHighlighted ? NSColor.selectedMenuItemTextColor : .labelColor).setStroke()
            outline.stroke()
        }

        // The hover ring, over everything: the affordance that says "this cell
        // answers". Inflated OUTWARD (exp 16's ring) so it never covers the
        // fill that says what is due, and drawn only for popup-bearing cells —
        // `hoveredIndex` is never set for an empty day.
        if let hovered = self.hoveredIndex, hovered < rects.count {
            let ring = NSBezierPath(
                roundedRect: rects[hovered].insetBy(dx: -1, dy: -1),
                xRadius: ComponentMetrics.cellRadius, yRadius: ComponentMetrics.cellRadius
            )
            ring.lineWidth = 1.5
            (self.isHighlighted ? NSColor.selectedMenuItemTextColor : .controlAccentColor).setStroke()
            ring.stroke()
        }
    }

    /// The scale: weekday letters down the left gutter, month names across the
    /// top row. Drawn BEFORE the cells, so a label can never paint over a fill.
    ///
    /// The weekday letters are a literal here rather than contract vocabulary:
    /// §3.3's week-aligned window makes row 0 Sunday for every window the backend
    /// can emit, so rows 1, 3 and 5 are Monday, Wednesday and Friday forever —
    /// GitHub's own choice, and the only three that fit at 8pt cells.
    private func drawLabels(over rects: [CGRect]) {
        guard !rects.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: self.isHighlighted
                ? NSColor.selectedMenuItemTextColor.withAlphaComponent(0.75)
                : NSColor.secondaryLabelColor,
        ]

        for (letter, row) in [("M", 1), ("W", 3), ("F", 5)] where row < rects.count {
            let label = NSAttributedString(string: letter, attributes: attributes)
            label.draw(at: CGPoint(
                x: Self.gridOrigin.x - 4 - label.size().width,
                y: rects[row].minY - 2
            ))
        }

        // Indexed BY COLUMN — entry i heads the column starting at cell i × 7 —
        // which is why the backend hands over the nils rather than a compacted
        // list of the named columns.
        for (column, month) in self.monthLabels.enumerated() {
            guard let month, column * ComponentMetrics.rowsPerColumn < rects.count else { continue }
            NSAttributedString(string: month, attributes: attributes)
                .draw(at: CGPoint(x: rects[column * ComponentMetrics.rowsPerColumn].minX, y: 0))
        }
    }

    /// Darker means more important. While highlighted the palette goes
    /// white-alpha: accent-coloured cells are invisible against the accent
    /// capsule, which is the one place a colour choice is a correctness bug (§5).
    private func fillColor(for tier: CellTier?) -> NSColor {
        if self.isHighlighted {
            let base = NSColor.selectedMenuItemTextColor
            switch tier {
            case .none: return base.withAlphaComponent(0.25)
            case .assignment: return base.withAlphaComponent(0.6)
            case .quiz: return base.withAlphaComponent(0.8)
            case .test: return base.withAlphaComponent(1.0)
            }
        }
        switch tier {
        case .none: return .quaternaryLabelColor
        case .assignment: return NSColor.controlAccentColor.withAlphaComponent(0.45)
        case .quiz: return .controlAccentColor
        // Darker than the accent itself, continuing the "darker means more
        // important" ramp — a test outranks a quiz in the tier contract, so it
        // must read as the heavier square.
        case .test: return NSColor.controlAccentColor
            .blended(withFraction: 0.35, of: .black) ?? .controlAccentColor
        }
    }
}
