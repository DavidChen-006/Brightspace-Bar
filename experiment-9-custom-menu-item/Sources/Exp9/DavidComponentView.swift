import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// David's rendering playground. All the NSMenuItem plumbing is done; only
// `draw(_:)` — and eventually the layout math feeding it — is yours.
//
// A/B: this view receives the SAME cells as the SCLA grid component directly
// above it in the menu, so any visual difference between the two rows is your
// rendering and nothing else.
//
// Scaffolding already handled here (the pieces AppKit refuses to do for a
// view-backed item — no need to touch them while learning to draw):
//   frame        — set in init; NSMenuItem honors it verbatim (frame == .zero
//                  would make the row invisible)
//   highlight    — `isHighlightedForMenu` is flipped by MenuController in
//                  main.swift and triggers a redraw
//   click        — mouseUp forwards to the item's action, the canonical pattern
// ─────────────────────────────────────────────────────────────────────────────
@MainActor
final class DavidComponentView: NSView {

    let title: String
    let cells: [DayCell]

    /// Flipped from outside by NSMenuDelegate.willHighlight (see MenuController
    /// in main.swift) — the one hover signal that exists for view-backed items.
    var isHighlightedForMenu = false {
        didSet { if oldValue != self.isHighlightedForMenu { self.needsDisplay = true } }
    }

    init(title: String, cells: [DayCell]) {
        self.title = title
        self.cells = cells
        // A native menu row's height. Grows as you add the graph, hairlines,
        // and spacing — the frame is what NSMenuItem honors.
        super.init(frame: CGRect(x: 0, y: 0, width: 340, height: 22))
        // Stretch to the menu's final width, so a highlight capsule can span the
        // row like a native item's does.
        self.autoresizingMask = [.width]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("code-built only") }

    // ── YOUR CANVAS ─────────────────────────────────────────────────────────
    //
    // Starting point: full parity with the native rows above — title AND hover.
    // The capsule below is what "being hovered" IS for a view-backed item:
    // AppKit draws no highlight for items that carry a view, so a row that
    // wants to hover like its native neighbours must paint the capsule itself
    // (RepoBar does the same). Everything from here — hairlines, spacing,
    // cells, today, the graph palette — is yours to derive.
    //
    override func draw(_ dirtyRect: NSRect) {
        // The system hover capsule, native metrics: inset 6 horizontal /
        // 2 vertical, radius 6. Drawn first so everything else sits on top.
        if self.isHighlightedForMenu {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(
                roundedRect: self.bounds.insetBy(dx: 6, dy: 2),
                xRadius: 6, yRadius: 6
            ).fill()
        }

        // Native rows flip their text color while highlighted; so do we.
        let text = self.title as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: self.isHighlightedForMenu
                ? NSColor.selectedMenuItemTextColor
                : NSColor.labelColor,
        ]
        let textHeight = text.size(withAttributes: attributes).height
        text.draw(
            at: NSPoint(x: 14, y: (self.bounds.height - textHeight) / 2),
            withAttributes: attributes
        )
    }

    // Click forwarding — the canonical view-backed-item pattern, same as
    // CourseComponentView. Not part of the rendering curriculum.
    override func mouseUp(with event: NSEvent) {
        guard let item = self.enclosingMenuItem, let menu = item.menu else { return }
        menu.cancelTracking()
        if let index = menu.items.firstIndex(of: item), index >= 0 {
            menu.performActionForItem(at: index)
        }
    }
}
