import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// The boundary between courses, drawn (NewVertical-3.md §3.1).
//
// A 1pt line, inset from both edges, centred inside its own short inert row. The
// row exists so that ROW HEIGHT IS THE PADDING: the item is disabled, so hover
// skips it, and the line can never end up inside a highlight capsule the way an
// in-component line would.
// ─────────────────────────────────────────────────────────────────────────────

/// The view behind a `.hairline` row.
///
/// `public` because the app's own test target imports this module by name.
public final class HairlineRowView: NSView {
    /// §3.1's "≈10pt tall" row. The line is 1pt of it; the rest is the breathing
    /// room that would otherwise be padding inside each course component.
    static let rowHeight: CGFloat = 10
    static let thickness: CGFloat = 1

    /// Shares `ComponentMetrics.textInset`, so the line starts exactly where a
    /// course title does rather than at a second, separately-tuned number.
    static var inset: CGFloat { ComponentMetrics.textInset }

    /// Deliberately NOT `NSColor.separatorColor`: measured in experiment 9, it
    /// renders near-white in a dark menu, which is the whole reason the footer's
    /// native separator is not wanted between courses. Resolved per appearance so
    /// one row reads correctly in both.
    static let lineColor = NSColor(name: "hairline") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.5, alpha: 0.6)
            : NSColor(white: 0.0, alpha: 0.12)
    }

    public init() {
        // A width is needed up front — an `NSMenuItem.view` is not laid out for
        // you, and a `.zero` frame renders an invisible row. The autoresizing mask
        // then stretches it to whatever width the menu settles on.
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: Self.rowHeight))
        self.autoresizingMask = [.width]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override func draw(_ dirtyRect: NSRect) {
        Self.lineColor.setFill()
        NSRect(
            x: Self.inset,
            y: (self.bounds.height - Self.thickness) / 2,
            width: max(self.bounds.width - Self.inset * 2, 0),
            height: Self.thickness
        ).fill()
    }
}
