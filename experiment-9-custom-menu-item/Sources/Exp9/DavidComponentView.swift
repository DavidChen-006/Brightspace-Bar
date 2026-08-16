import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// David's rendering playground — the CLICK-TO-CYCLE input experiment, and now
// the CELL-HOVER POPUP: hover a day that carries work and a card appears beside
// that cell listing everything due, one row per item, each row hoverable and
// clickable straight through to its Brightspace page.
//
// The popup is drawn INSIDE this view, not in a window of its own. That is the
// experiment's answer, and it was chosen after measuring the alternatives — an
// NSPanel above the menu and an NSPopover both fail in ways `MenuOverlayProbe`
// records.
//
// The card is CLAMPED inside this row. That is a choice, not a constraint:
// macOS 15 ships `NSView.clipsToBounds == false`, and the self-test measures a
// band painted 14pt below the frame surviving intact. What is NOT measured is
// whether the menu's own window clips an overhanging card, so the safe version
// stays inside the row and the overhang is left as a lever for the port.
//
// What the card needs from AppKit, and where each comes from:
//
//   which cell is under the pointer  — `cellIndex(at:)`, a pure inverse of the
//                                      drawing math
//   pointer motion during tracking   — NSTrackingArea `mouseMoved`, which DOES
//                                      arrive inside an open menu (measured)
//   row clicks                       — `mouseUp`, which view-backed items get
//   opening the link                 — cancelTracking() then NSWorkspace.open
//
// The question this row answers first: can a menu-hosted grid take repeated
// clicks — hover a cell, click it to rotate nothing → assignment → quiz → test
// → nothing — while the menu STAYS OPEN and repaints live?
//
// What we already know (found by clicking around BrightspaceBar): AppKit gives
// view-backed items no click behavior at all, so when our mouseUp does not
// cancel tracking, nothing closes the menu. What this row must still prove:
//
//   1. REPEATED clicks on one spot all arrive (or does double-click coalescing
//      eat every second one? `event.clickCount` is printed per click to tell).
//   2. The view repaints live mid-tracking on every click.
//   3. Hit-testing partitions one surface: clicks INSIDE a cell rotate it and
//      keep the menu open; clicks anywhere else keep the old behavior
//      (forward to the item's action, which closes the menu).
//   4. mouseMoved arrives during menu tracking, so the hovered cell can wear
//      an aiming outline — an 8pt target wants one.
//
// The cells are MUTABLE LOCAL STATE, on purpose and only here: this is an
// input experiment, not the overlay store. The real app routes the same click
// through a callback to a store, translates index → date with the window
// math, and re-derives. None of that belongs in this probe.
//
// Scaffolding notes (unchanged from the learning phase):
//   frame     — set in init; NSMenuItem honors it verbatim
//   highlight — `isHighlightedForMenu` flipped by MenuController's
//               willHighlight; the one hover signal AppKit provides
// ─────────────────────────────────────────────────────────────────────────────
@MainActor
final class DavidComponentView: NSView {

    // Metrics — the same values CourseComponentView measured against native
    // rows, duplicated so this canvas stays self-contained.
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

    // Popup metrics. Rows are 20pt so an 8pt cell's worth of pointer travel
    // never skips one, and the card is padded 6pt like a small menu.
    private static let popupRowHeight: CGFloat = 20
    private static let popupPadding: CGFloat = 6
    private static let popupGap: CGFloat = 6
    private static let popupCorner: CGFloat = 6
    private static let popupSwatch: CGFloat = 7
    private static let popupFont = NSFont.menuFont(ofSize: 11)

    let title: String

    /// Mutable ON PURPOSE — rotating these on click IS the experiment.
    private var cells: [DayCell]

    /// Every accepted cell click, shown in the title so no click can be
    /// swallowed silently.
    private var clickCount = 0

    /// The cell under the mouse, worn as an outline — the aiming aid.
    private var hoveredIndex: Int?

    /// The cell the popup is anchored to. Nil = no popup on screen. Set when
    /// the pointer enters a cell that carries work; cleared when the pointer
    /// leaves both that cell and the card.
    private var popupAnchor: Int?

    /// The popup row under the pointer, highlighted like a menu row.
    private var popupRow: Int?

    /// Cleared by the probe so a measured click reports its URL instead of
    /// throwing a browser at whoever is running the experiment.
    static var opensLinksForReal = true

    /// Set by the offscreen-render path only: draws a red block below the
    /// view's own bounds so a test can see whether anything outside the frame
    /// survives. It never does — that is the point.
    static var drawsOutOfBoundsProbe = false

    /// Flipped from outside by NSMenuDelegate.willHighlight (see MenuController
    /// in main.swift).
    // Dismissal is `mouseExited`'s job alone. Also clearing the card here, when
    // the menu moves its highlight away, looks like cheap insurance and is not:
    // `willHighlight` fires between the hover and the click, so the card was
    // being torn down before `mouseUp` could read it, and the measured click
    // path went dead. (Found by --probe, which caught the regression.)
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

        // MEASUREMENT, not the feature: register a NATIVE macOS tooltip on
        // every named cell. The suspicion is that menu tracking suppresses
        // ordinary tooltip windows entirely — if that's right, the query
        // callback below never logs and the hand-drawn bubble is the only
        // path. If a native tooltip DOES appear, that's worth knowing too.
        for (index, rect) in self.cellRects().enumerated() where !cells[index].items.isEmpty {
            self.addToolTip(rect, owner: self, userData: nil)
        }
    }

    /// NSViewToolTipOwner (informal protocol, hence no `override`) — answers
    /// native tooltip queries, and logs each one so suppression-in-menus is
    /// observable rather than assumed.
    @objc func view(
        _ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint, userData: UnsafeMutableRawPointer?
    ) -> String {
        let name = self.cellIndex(at: point).flatMap { self.cells[$0].items.first?.title } ?? ""
        print("[exp9] NATIVE tooltip queried → \"\(name)\" — so menus do NOT suppress them")
        return name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("code-built only") }

    // MARK: - Geometry

    /// Column-major GitHub layout: index = column * 7 + row, row 0 at the top.
    /// The drawing math; `cellIndex(at:)` below must be its exact inverse.
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

    /// The inverse mapping: a point → the cell it lands on. Each rect is
    /// inflated by 1pt per side, so the 2pt gaps between cells are split
    /// between their neighbors instead of being dead zones — a forgiving
    /// target without ever being ambiguous.
    private func cellIndex(at point: CGPoint) -> Int? {
        self.cellRects().firstIndex { $0.insetBy(dx: -1, dy: -1).contains(point) }
    }

    // MARK: - Popup geometry (pure functions of the cell rect and the items)

    /// How wide the card has to be to hold its widest row without truncating.
    /// Text is measured, not guessed, because assignment names vary wildly and
    /// a fixed width would either waste the row or clip "Midterm 1 — Chapters
    /// 1–4" to nonsense.
    private static func popupSize(for items: [WorkItem]) -> CGSize {
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: Self.popupFont]
        let kindAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9)]
        let widest = items.map { item in
            NSAttributedString(string: item.title, attributes: titleAttrs).size().width
                + NSAttributedString(string: item.kindLabel, attributes: kindAttrs).size().width
        }.max() ?? 0
        return CGSize(
            // padding + swatch + swatch-gap + title + title/kind gap + kind + padding
            width: Self.popupPadding * 2 + Self.popupSwatch + 6 + widest + 10,
            height: Self.popupPadding * 2 + Self.popupRowHeight * CGFloat(items.count)
        )
    }

    /// The card's frame for a given cell — beside the cell like a submenu,
    /// flipped to the cell's left when the right side has no room, and finally
    /// clamped inside this view.
    ///
    /// The clamp keeps the card inside the row even though nothing forces it
    /// to (measured — see `drawsOutOfBoundsProbe`): an overhanging card would
    /// paint over the neighbouring menu rows, whose own redraws we do not
    /// control. Anchoring "next to the cell" therefore means *next to it,
    /// within the row*.
    private func popupFrame(forCell index: Int) -> CGRect? {
        let items = self.cells[index].items
        guard !items.isEmpty, index < self.cellRects().count else { return nil }
        let cell = self.cellRects()[index]
        let size = Self.popupSize(for: items)

        var x = cell.maxX + Self.popupGap
        if x + size.width > self.bounds.width - Self.highlightInsetX - 2 {
            x = cell.minX - Self.popupGap - size.width
        }
        let minX = Self.highlightInsetX + 2
        let maxX = max(minX, self.bounds.width - Self.highlightInsetX - 2 - size.width)
        x = min(max(x, minX), maxX)

        // The card may cover the grid — it is a surface above it — but never the
        // row's title, which is the only thing naming the course it belongs to.
        // That ceiling is what limits the card to about three rows at this row
        // height; a fourth would have nowhere to go.
        let ceiling = self.bounds.height - Self.verticalPad - Self.titleHeight
        let minY = Self.highlightInsetY + 2
        let maxY = max(minY, ceiling - size.height)
        let y = min(max(cell.midY - size.height / 2, minY), maxY)

        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// One rect per item, top row first — the inverse of the row drawing loop.
    private func popupRowRects(forCell index: Int) -> [CGRect] {
        guard let frame = self.popupFrame(forCell: index) else { return [] }
        return self.cells[index].items.indices.map { row in
            CGRect(
                x: frame.minX + Self.popupPadding,
                y: frame.maxY - Self.popupPadding - Self.popupRowHeight * CGFloat(row + 1),
                width: frame.width - Self.popupPadding * 2,
                height: Self.popupRowHeight
            )
        }
    }

    /// Where the pointer may wander without dismissing the popup: the cell, the
    /// card, and the gap between them. Without the union the 6pt gap would be a
    /// dead strip that closed the card on the way to it.
    private func popupKeepAlive(forCell index: Int) -> CGRect? {
        guard let frame = self.popupFrame(forCell: index), index < self.cellRects().count else { return nil }
        return frame.union(self.cellRects()[index]).insetBy(dx: -3, dy: -3)
    }

    /// Forces a popup open for the offscreen render and the geometry self-test,
    /// which have no pointer to hover with.
    func showPopup(forCell index: Int, row: Int?) {
        self.popupAnchor = index
        self.popupRow = row
        self.hoveredIndex = index
        self.needsDisplay = true
    }

    /// The self-test's window into the pure geometry above.
    func popupGeometry(forCell index: Int) -> (frame: CGRect, rows: [CGRect])? {
        guard let frame = self.popupFrame(forCell: index) else { return nil }
        return (frame, self.popupRowRects(forCell: index))
    }

    func items(forCell index: Int) -> [WorkItem] { self.cells[index].items }

    /// A cell's centre in view coordinates — what the probe warps the real
    /// cursor to, so hover delivery is measured rather than assumed.
    func cellCenter(forCell index: Int) -> CGPoint? {
        let rects = self.cellRects()
        guard index < rects.count else { return nil }
        return CGPoint(x: rects[index].midX, y: rects[index].midY)
    }

    /// What the view currently believes the pointer is doing. Read back by the
    /// probe after warping the cursor.
    var hoverStateDescription: String {
        "hoveredCell=\(self.hoveredIndex.map(String.init) ?? "nil")"
            + " popupAnchor=\(self.popupAnchor.map(String.init) ?? "nil")"
            + " popupRow=\(self.popupRow.map(String.init) ?? "nil")"
    }

    // MARK: - The rotation

    private static func nextTier(after tier: Tier?) -> Tier? {
        switch tier {
        case .none: .assignment
        case .assignment: .quiz
        case .quiz: .test
        case .test: nil
        }
    }

    // MARK: - Input

    override func mouseUp(with event: NSEvent) {
        let point = self.convert(event.locationInWindow, from: nil)

        // A popup row: open its Brightspace page and close the menu. The card
        // is drawn over the grid, so it must be tested BEFORE the cells or a
        // row click would fall through to the cell underneath it.
        if let anchor = self.popupAnchor,
           let row = self.popupRowRects(forCell: anchor).firstIndex(where: { $0.contains(point) }) {
            let item = self.cells[anchor].items[row]
            print("[exp9] popup row click → \(item.kindLabel): \(item.title) → \(item.url)")
            // Cancel first, open second: cancelTracking unwinds the menu's
            // modal loop, and the open then happens with no menu on screen.
            self.enclosingMenuItem?.menu?.cancelTracking()
            self.popupAnchor = nil
            self.popupRow = nil
            if Self.opensLinksForReal {
                NSWorkspace.shared.open(item.url)
            } else {
                print("[exp9] (dry run) would open \(item.url)")
            }
            return
        }

        // Inside a cell: rotate it, repaint, and DO NOT close the menu.
        if let index = self.cellIndex(at: point) {
            // Days that carry work are not cyclable — their tier is a fact
            // about the items, and rotating it would make the cell's color
            // disagree with the popup listing them.
            guard self.cells[index].items.isEmpty else { return }
            let old = self.cells[index]
            self.cells[index] = DayCell(Self.nextTier(after: old.tier), isToday: old.isToday)
            self.clickCount += 1
            // event.clickCount reveals double-click coalescing: if rapid
            // clicks arrive as clickCount 1,2,3… they all reached us.
            print("[exp9] cell \(index): \(old.tier.map(String.init(describing:)) ?? "empty")"
                + " → \(self.cells[index].tier.map(String.init(describing:)) ?? "empty")"
                + " (accepted #\(self.clickCount), event.clickCount=\(event.clickCount))")
            self.needsDisplay = true
            return
        }

        // Anywhere else on the component: the pre-existing contract — forward
        // to the item's action, which closes the menu. The partition question,
        // answered by rect membership.
        guard let item = self.enclosingMenuItem, let menu = item.menu else { return }
        menu.cancelTracking()
        if let index = menu.items.firstIndex(of: item), index >= 0 {
            menu.performActionForItem(at: index)
        }
    }

    // MARK: - Hover (mouseMoved during menu tracking)

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
        self.updateHover(at: self.convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        self.updateHover(at: nil)
    }

    /// The whole hover policy in one place: which cell is aimed at, whether a
    /// popup is open, and which of its rows is lit. Priority order matters and
    /// mirrors what is drawn on top of what.
    private func updateHover(at point: CGPoint?) {
        var cell: Int?
        var anchor: Int?
        var row: Int?

        if let point {
            let overCell = self.cellIndex(at: point)

            if let open = self.popupAnchor, self.popupFrame(forCell: open)?.contains(point) == true {
                // The card is painted over the grid, so inside the card the
                // card wins — the cells beneath it are not hoverable.
                anchor = open
                cell = open
                row = self.popupRowRects(forCell: open).firstIndex { $0.contains(point) }
            } else if let overCell, !self.cells[overCell].items.isEmpty {
                // A day with work: open (or move) the popup to it.
                anchor = overCell
                cell = overCell
            } else if let open = self.popupAnchor,
                      self.popupKeepAlive(forCell: open)?.contains(point) == true {
                // The gap between the cell and its card — travelling, not leaving.
                anchor = open
                cell = overCell ?? open
            } else {
                // An empty day or bare view: no popup, plain aiming outline.
                cell = overCell
            }
        }

        if cell != self.hoveredIndex || anchor != self.popupAnchor || row != self.popupRow {
            self.hoveredIndex = cell
            self.popupAnchor = anchor
            self.popupRow = row
            self.needsDisplay = true
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = self.isHighlightedForMenu

        // The system hover capsule — native metrics, drawn first.
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(
                roundedRect: self.bounds.insetBy(dx: Self.highlightInsetX, dy: Self.highlightInsetY),
                xRadius: Self.highlightRadius, yRadius: Self.highlightRadius
            ).fill()
        }

        // Title, with the click counter — the unambiguous readout that every
        // click was received.
        let counted = self.clickCount > 0 ? "\(self.title) · \(self.clickCount) clicks" : self.title
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor,
        ]
        NSAttributedString(string: counted, attributes: titleAttrs).draw(at: CGPoint(
            x: Self.textInset,
            y: self.bounds.height - Self.verticalPad - Self.titleHeight + 1
        ))

        let rects = self.cellRects()

        // M/W/F gutter labels — kept so edge cells sit next to real neighbors,
        // which is where off-by-one hit-testing errors would live.
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

        // Cells: fill, then today's outline, then the hover outline on top.
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

        // The hover popup, hand-drawn LAST so it floats over everything else.
        // Drawn inside the view because a card is just geometry + text — the
        // same immediate-mode toolkit as the cells — and unlike a tooltip
        // window, a popover, or a panel, nothing about menu tracking can
        // suppress it or steal its clicks.
        if let anchor = self.popupAnchor {
            self.drawPopup(forCell: anchor)
        }

        // The clipping measurement, with its own control. Two identical bands
        // are painted: one just INSIDE the bottom edge, one 14pt BELOW it. A
        // test that finds the first and not the second has measured clipping;
        // a test that finds neither has merely sampled the wrong row.
        if Self.drawsOutOfBoundsProbe {
            NSColor.systemRed.setFill()
            NSRect(x: 0, y: 2, width: self.bounds.width, height: 12).fill()
            NSRect(x: 0, y: -14, width: self.bounds.width, height: 12).fill()
        }
    }

    /// The card: one row per item due that day, each a tier swatch, a title,
    /// and a right-aligned kind. The hovered row wears the system selection
    /// capsule, so a row reads as clickable for the same reason a menu row
    /// does.
    ///
    /// Colors are the plain (unhighlighted) palette even when the menu row
    /// itself is highlighted: the card is a surface *above* the accent capsule,
    /// not part of it, and inheriting the white-alpha palette here would make
    /// it look painted onto the row.
    private func drawPopup(forCell index: Int) {
        guard let frame = self.popupFrame(forCell: index) else { return }
        let items = self.cells[index].items
        let rows = self.popupRowRects(forCell: index)

        // A shadow is what separates "floating card" from "rectangle drawn on
        // the grid" — the only cue available without a real window behind it.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        let card = NSBezierPath(roundedRect: frame, xRadius: Self.popupCorner, yRadius: Self.popupCorner)
        NSColor.windowBackgroundColor.setFill()
        card.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        card.lineWidth = 1
        card.stroke()

        for (row, (item, rect)) in zip(items, rows).enumerated() {
            let lit = row == self.popupRow
            if lit {
                NSColor.selectedContentBackgroundColor.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: 0), xRadius: 4, yRadius: 4).fill()
            }

            // Tier swatch: the same color the cell wears, so the row and the
            // day it came from are visibly the same fact.
            let swatch = CGRect(
                x: rect.minX,
                y: rect.midY - Self.popupSwatch / 2,
                width: Self.popupSwatch, height: Self.popupSwatch
            )
            self.fillColor(for: item.kind, highlighted: false).setFill()
            NSBezierPath(roundedRect: swatch, xRadius: 2, yRadius: 2).fill()

            let titleColor: NSColor = lit ? .selectedMenuItemTextColor : .labelColor
            let title = NSAttributedString(string: item.title, attributes: [
                .font: Self.popupFont, .foregroundColor: titleColor,
            ])
            title.draw(at: CGPoint(
                x: swatch.maxX + 6,
                y: rect.midY - title.size().height / 2
            ))

            let kind = NSAttributedString(string: item.kindLabel, attributes: [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: lit
                    ? NSColor.selectedMenuItemTextColor.withAlphaComponent(0.8)
                    : NSColor.tertiaryLabelColor,
            ])
            kind.draw(at: CGPoint(
                x: rect.maxX - kind.size().width,
                y: rect.midY - kind.size().height / 2
            ))
        }
    }

    /// Same palette as CourseComponentView, so the A/B against SCLA holds.
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
