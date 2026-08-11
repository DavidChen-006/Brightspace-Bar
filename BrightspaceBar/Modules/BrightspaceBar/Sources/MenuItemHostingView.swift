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
enum ComponentMetrics {
    /// Native menu rows lead their text by ~14pt inside the highlight capsule.
    static let textInset: CGFloat = 14
    /// The capsule, inset from the item edge. RepoBar's 6/2/6, verified against
    /// real menu rows in experiment 9.
    static let highlightInsetX: CGFloat = 6
    static let highlightInsetY: CGFloat = 2
    static let highlightRadius: CGFloat = 6

    static let cellSide: CGFloat = 8
    static let cellGap: CGFloat = 2
    static let cellRadius: CGFloat = 2

    static let titleHeight: CGFloat = 17
    /// Between the title baseline row and the cells.
    static let rowGap: CGFloat = 5
    static let verticalPad: CGFloat = 6
    /// A menu never looks right narrower than this, whatever the content is.
    static let minimumWidth: CGFloat = 240

    static func stripWidth(cells: Int) -> CGFloat {
        let count = CGFloat(max(cells, 0))
        return count * self.cellSide + max(count - 1, 0) * self.cellGap
    }

    /// What the item's frame must be. `NSMenuItem.view` is not laid out for you:
    /// AppKit honours this number and computes nothing, so a course with cells
    /// has to ask for the extra height itself or the cells have nowhere to draw.
    static func fittingSize(cells: Int) -> CGSize {
        let graph = cells > 0 ? self.rowGap + self.cellSide : 0
        return CGSize(
            width: max(self.minimumWidth, self.textInset * 2 + self.stripWidth(cells: cells)),
            height: self.verticalPad * 2 + self.titleHeight + graph
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

    /// Set by the menu delegate. The ONE highlight signal AppKit gives us, and
    /// it arrives on the delegate rather than on the view, which is why the
    /// assembler has to own the plumbing.
    public var isHighlightedForMenu = false {
        didSet {
            guard oldValue != self.isHighlightedForMenu else { return }
            self.hosting.rootView = self.card
            self.needsDisplay = true
        }
    }

    private let hosting: NSHostingView<CourseCardView>

    public init(title: String, cells: [GraphCell], showsChevron: Bool) {
        self.title = title
        self.cells = cells
        self.showsChevron = showsChevron
        self.hosting = NSHostingView(
            rootView: CourseCardView(title: title, cells: cells, isHighlighted: false)
        )
        super.init(frame: CGRect(origin: .zero, size: ComponentMetrics.fittingSize(cells: cells.count)))
        // Stretch to the menu's final width, so the capsule spans the row like a
        // native item's does instead of stopping at our content.
        self.autoresizingMask = [.width]
        self.hosting.frame = self.bounds
        self.hosting.autoresizingMask = [.width, .height]
        self.addSubview(self.hosting)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("MenuItemHostingView is built in code, never from a nib")
    }

    private var card: CourseCardView {
        CourseCardView(title: self.title, cells: self.cells, isHighlighted: self.isHighlightedForMenu)
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
    let isHighlighted: Bool

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
                CourseGraphView(cells: self.cells, isHighlighted: self.isHighlighted)
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
    let isHighlighted: Bool

    var body: some View {
        GraphRasterView(cells: self.cells, isHighlighted: self.isHighlighted)
            .frame(
                width: ComponentMetrics.stripWidth(cells: self.cells.count),
                height: ComponentMetrics.cellSide
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
    let isHighlighted: Bool

    func makeNSView(context: Context) -> GraphRasterNSView {
        GraphRasterNSView(cells: self.cells, isHighlighted: self.isHighlighted)
    }

    func updateNSView(_ view: GraphRasterNSView, context: Context) {
        view.isHighlighted = self.isHighlighted
    }
}

/// The cells, drawn. Immediate mode, no cache and no per-cell object: derivation
/// is microseconds and the menu is closed almost always (§3.2). A strip for now
/// — the week-aligned grid is slice 4, and it changes this rect arithmetic and
/// nothing above it.
final class GraphRasterNSView: NSView {
    private let cells: [GraphCell]

    var isHighlighted: Bool {
        didSet {
            guard oldValue != self.isHighlighted else { return }
            self.needsDisplay = true
        }
    }

    init(cells: [GraphCell], isHighlighted: Bool) {
        self.cells = cells
        self.isHighlighted = isHighlighted
        super.init(frame: CGRect(
            origin: .zero,
            size: CGSize(
                width: ComponentMetrics.stripWidth(cells: cells.count),
                height: ComponentMetrics.cellSide
            )
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GraphRasterNSView is built in code, never from a nib")
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, cell) in self.cells.enumerated() {
            let rect = CGRect(
                x: CGFloat(index) * (ComponentMetrics.cellSide + ComponentMetrics.cellGap),
                y: self.bounds.midY - ComponentMetrics.cellSide / 2,
                width: ComponentMetrics.cellSide,
                height: ComponentMetrics.cellSide
            )
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
            case .quiz: return base.withAlphaComponent(0.95)
            }
        }
        switch tier {
        case .none: return .quaternaryLabelColor
        case .assignment: return NSColor.controlAccentColor.withAlphaComponent(0.45)
        case .quiz: return .controlAccentColor
        }
    }
}
