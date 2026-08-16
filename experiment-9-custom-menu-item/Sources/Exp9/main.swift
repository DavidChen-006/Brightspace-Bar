import AppKit

// ═════════════════════════════════════════════════════════════════════════════
// Experiment 9 — native rows and custom-rendered course components, side by
// side in ONE menu, so the hover-unity difference is judged directly.
//
// The menu:
//   Fall 2026                 (native, disabled — today's section header)
//   CS 17600 — Data Eng…      (native — today's course row)
//   MA 26100 — Multivar…      (native)
//   ────────────────
//   ┌ Purdue Civics Knowledge Test ┐   CUSTOM: title + 28-day strip + submenu
//   │ [■][□][ ][■]…               ❯│           one hover capsule over all of it
//   └──────────────────────────────┘
//   ┌ SCLA 10100 — Transformative… ┐   CUSTOM: title + 7×16 GitHub grid (S5)
//   │  M/W/F + month labels        │
//   └──────────────────────────────┘
//   ────────────────
//   Quit                      (native)
//
// Sync top level (the experiment-5 lesson: a top-level await starves the
// MainActor and blanks the menu).
// ═════════════════════════════════════════════════════════════════════════════

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

/// Seeds. The strip mirrors the stub's Data Engineering pattern; the grid gets
/// enough scattered work that density and labels can be judged.
func stripCells() -> [DayCell] {
    var cells = (0..<28).map { _ in DayCell(nil) }
    cells[0] = DayCell(.assignment, isToday: true)
    cells[1] = DayCell(.quiz)
    cells[3] = DayCell(.assignment)
    cells[5] = DayCell(.quiz)
    cells[9] = DayCell(.quiz)
    cells[27] = DayCell(.assignment)
    return cells
}

func gridCells(columns: Int) -> [DayCell] {
    var cells = (0..<(columns * 7)).map { _ in DayCell(nil) }
    cells[2] = DayCell(.assignment, isToday: true)
    for index in [5, 9, 16, 23, 30, 44, 52, 61, 75, 88, 96, 104] where index < cells.count {
        cells[index] = DayCell(index.isMultiple(of: 3) ? .quiz : .assignment)
    }
    return cells
}

/// Keeps custom views told about highlight — the piece AppKit does not do.
/// `willHighlight` fires once per change with the item (or nil); every
/// component view compares itself against it.
@MainActor
final class MenuController: NSObject, @preconcurrency NSMenuDelegate {
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for menuItem in menu.items {
            if let component = menuItem.view as? CourseComponentView {
                component.isHighlightedForMenu = (menuItem === item)
            }
            if let david = menuItem.view as? DavidComponentView {
                david.isHighlightedForMenu = (menuItem === item)
            }
        }
    }
}

@MainActor
final class ClickTarget: NSObject {
    @objc func open(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func quit(_ sender: NSMenuItem) { NSApp.terminate(nil) }
}

let controller = MenuController()
let target = ClickTarget()

func nativeRow(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: #selector(ClickTarget.open(_:)), keyEquivalent: "")
    item.target = target
    item.representedObject = URL(string: "https://purdue.brightspace.com/d2l/home/1")!
    return item
}

func header(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
}

/// The ChatGPT-style boundary: a thin INERT row owning nothing but a 1pt grey
/// line, inset 14pt from each edge, centered so it carries its own breathing
/// room. A dedicated row (RepoBar's approach) rather than a line drawn at a
/// component's top pixel — padding around a line needs height, and height
/// belongs to a row.
final class HairlineRowView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        // A fixed mid-grey rather than .separatorColor: the system color is
        // near-white at low alpha in dark menus, which read as white lines.
        // Tune the two numbers to taste: white (0=black…1=white), alpha.
        NSColor(white: 0.5, alpha: 0.6).setFill()
        NSRect(x: 14, y: self.bounds.midY, width: self.bounds.width - 28, height: 1).fill()
    }
}

func hairlineRow() -> NSMenuItem {
    let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    item.isEnabled = false
    let view = HairlineRowView(frame: NSRect(x: 0, y: 0, width: 340, height: 10))
    view.autoresizingMask = [.width]
    item.view = view
    return item
}

func componentItem(view: NSView, submenu: NSMenu?) -> NSMenuItem {
    let item = NSMenuItem(title: "", action: #selector(ClickTarget.open(_:)), keyEquivalent: "")
    item.target = target
    item.representedObject = URL(string: "https://purdue.brightspace.com/d2l/home/412690")!
    item.view = view
    item.submenu = submenu
    return item
}

// ── The legos: each row built and named, chemistry kept out of the diagram ──

/// Seeds for the hover-popup experiment: every marked cell carries the real
/// WORK due that day — title, kind, and a Brightspace deep link — laid out like
/// a Multivariable Calculus semester, so hovering the graph answers "what is
/// that red cell?" and clicking the answer opens the page.
///
/// `MA 26100` uses org-unit 412690, one of the two courses experiment 7
/// verified links against; the item ids are stubs in the same shape.
let davidCourseId = 412690

func assignment(_ id: Int, _ title: String) -> WorkItem {
    WorkItem(kind: .assignment, title: title, url: WorkLink.assignment(courseId: davidCourseId, assignmentId: id))
}

func quiz(_ id: Int, _ title: String) -> WorkItem {
    WorkItem(kind: .quiz, title: title, url: WorkLink.quiz(courseId: davidCourseId, quizId: id))
}

func test(_ id: Int, _ title: String) -> WorkItem {
    WorkItem(kind: .test, title: title, url: WorkLink.quiz(courseId: davidCourseId, quizId: id))
}

/// A day carries a LIST; the cell's tier is the most severe thing on it, which
/// is what a real renderer would have to do too — one cell, many items.
func day(_ items: [WorkItem], isToday: Bool = false) -> DayCell {
    DayCell(items.map(\.kind).max(), isToday: isToday, items: items)
}

func davidCells(columns: Int) -> [DayCell] {
    var cells = (0..<(columns * 7)).map { _ in DayCell(nil) }
    cells[2] = day([assignment(648911, "HW 3 — Vector Fields")], isToday: true)
    cells[5] = day([quiz(619243, "Quiz 4 — Chain Rule")])
    cells[9] = day([assignment(648912, "HW 4 — Partial Derivatives")])
    cells[16] = day([test(619244, "Midterm 1 — Chapters 1–4")])
    // ── The list case: one day, an assignment AND a quiz. ──
    cells[23] = day([
        assignment(648913, "HW 5 — Gradients"),
        quiz(619245, "Quiz 5 — Lagrange Multipliers"),
    ])
    cells[30] = day([quiz(619246, "Quiz 6 — Directional Derivatives")])
    // ── And the crowded day: three items, to show the card grow. ──
    cells[44] = day([
        assignment(648914, "HW 6 — Double Integrals"),
        quiz(619247, "Quiz 7 — Polar Coordinates"),
        test(619248, "Lab Practical 2"),
    ])
    cells[61] = day([test(619249, "Midterm 2 — Chapters 5–8")])
    cells[75] = day([quiz(619250, "Quiz 8 — Surface Area")])
    cells[104] = day([test(619251, "Final Exam — cumulative")])
    return cells
}

// David's playground: directly under the native rows it must match, so parity
// is judged against adjacent neighbours. Now seeded with NAMED work so the
// hover popup has something true to say.
let davidRow = componentItem(
    view: DavidComponentView(
        title: "DAVID 10000 — Rendering Playground",
        cells: davidCells(columns: 16)
    ),
    submenu: nil
)

// The star of the experiment: Civics as ONE component with a submenu attached,
// probing highlight, click, arrow, and submenu coexistence at once (S1).
let civicsSubmenu = NSMenu()
civicsSubmenu.autoenablesItems = false
civicsSubmenu.addItem(nativeRow("Open Course Home"))
let noAssignments = NSMenuItem(title: "No assignments", action: nil, keyEquivalent: "")
noAssignments.isEnabled = false
civicsSubmenu.addItem(noAssignments)

let civicsRow = componentItem(
    view: CourseComponentView(
        title: "Purdue Civics Knowledge Test",
        cells: stripCells(),
        shape: .strip,
        showsChevron: true,
        hairlines: false  // boundaries are hairlineRow() items now
    ),
    submenu: civicsSubmenu
)

// The S5 probe: same component, GitHub-shaped semester grid, no submenu.
let sclaRow = componentItem(
    view: CourseComponentView(
        title: "SCLA 10100 — Transformative Texts",
        cells: gridCells(columns: 16),
        shape: .grid(columns: 16),
        showsChevron: false,
        hairlines: false  // boundaries are hairlineRow() items now
    ),
    submenu: nil
)

let quitRow = NSMenuItem(title: "Quit", action: #selector(ClickTarget.quit(_:)), keyEquivalent: "q")
quitRow.target = target

// ── The diagram: the whole menu, at a glance ────────────────────────────────
// No native .separator()s: every boundary is a hairlineRow() — a thin inert
// item carrying an inset grey line with its own vertical breathing room.
let rows: [NSMenuItem] = [
    header("Fall 2026"),
    hairlineRow(),
    nativeRow("CS 17600 — Data Engineering"),
    hairlineRow(),
    nativeRow("MA 26100 — Multivariate Calculus"),
    hairlineRow(),
    davidRow,          // ← your component
    hairlineRow(),
    civicsRow,
    hairlineRow(),
    sclaRow,
    hairlineRow(),
    quitRow,
]

let menu = NSMenu()
menu.autoenablesItems = false
menu.delegate = controller
rows.forEach(menu.addItem)

let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
statusItem.button?.image = NSImage(systemSymbolName: "square.grid.3x3", accessibilityDescription: "Experiment 9")
statusItem.menu = menu

// EXP9_SHOOT=1: pop the menu open at a fixed screen point shortly after launch
// so an external `screencapture` can photograph it. `popUp` rather than
// clicking the status item: a fullscreen Space can hide the status-bar menu
// from capture, but a popped menu window photographs anywhere. Menu tracking
// blocks the main thread, so the screenshot must come from outside the process.
// (Found: useless without the Screen Recording permission — screencapture then
// returns wallpaper + menu bar with every window, menus included, omitted.)
if ProcessInfo.processInfo.environment["EXP9_SHOOT"] == "1" {
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(1))
        let screenTop = NSScreen.main?.frame.height ?? 1000
        menu.popUp(positioning: nil, at: NSPoint(x: 400, y: screenTop - 60), in: nil)
    }
}

// EXP9_RENDER=<path>: draw the component views offscreen into one PNG and
// exit. Not the real menu — no NSMenu chrome, no native rows — but it proves
// the drawing (capsule, tier colors, today outline, grid labels, both
// highlight states) in an environment where menus cannot be screenshotted.
if let renderPath = ProcessInfo.processInfo.environment["EXP9_RENDER"] {
    let width: CGFloat = 340
    let variants: [(String, GraphShape, Bool, Bool)] = [
        ("strip", .strip, true, false),
        ("strip highlighted", .strip, true, true),
        ("grid", .grid(columns: 16), false, false),
        ("grid highlighted", .grid(columns: 16), false, true),
    ]
    let views: [CourseComponentView] = variants.map { _, shape, chevron, highlighted in
        let isGrid = if case .grid = shape { true } else { false }
        let view = CourseComponentView(
            title: isGrid ? "SCLA 10100 — Transformative Texts" : "Purdue Civics Knowledge Test",
            cells: isGrid ? gridCells(columns: 16) : stripCells(),
            shape: shape,
            showsChevron: chevron
        )
        view.frame.size.width = width
        view.isHighlightedForMenu = highlighted
        return view
    }
    let gap: CGFloat = 8
    let totalHeight = views.map(\.frame.height).reduce(0, +) + gap * CGFloat(views.count + 1)
    let image = NSImage(size: NSSize(width: width + 16, height: totalHeight))
    image.lockFocus()
    // A menu-like backdrop so the dynamic colors read in context.
    NSColor.windowBackgroundColor.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: width + 16, height: totalHeight)).fill()
    var y = gap
    for view in views.reversed() {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        rep.draw(in: NSRect(x: 8, y: y, width: view.frame.width, height: view.frame.height))
        y += view.frame.height + gap
    }
    image.unlockFocus()
    let tiff = image.tiffRepresentation!
    let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: renderPath))
    exit(0)
}

// EXP9_POPUP_RENDER=<path>: the David row with the hover popup forced open,
// once for the two-item day and once for the three-item day, drawn offscreen.
// Not the real menu — but it proves the card's layout, clamping, row highlight
// and swatches in an environment where menus cannot be screenshotted.
if let renderPath = ProcessInfo.processInfo.environment["EXP9_POPUP_RENDER"] {
    let width: CGFloat = 340
    // (anchor cell, hovered row) — cell 23 holds 2 items, cell 44 holds 3.
    let states: [(Int, Int?)] = [(23, 1), (44, 0)]
    let views: [DavidComponentView] = states.map { anchor, row in
        let view = DavidComponentView(
            title: "DAVID 10000 — Rendering Playground",
            cells: davidCells(columns: 16)
        )
        view.frame.size.width = width
        view.showPopup(forCell: anchor, row: row)
        return view
    }
    let gap: CGFloat = 8
    let totalHeight = views.map(\.frame.height).reduce(0, +) + gap * CGFloat(views.count + 1)
    let image = NSImage(size: NSSize(width: width + 16, height: totalHeight))
    image.lockFocus()
    NSColor.windowBackgroundColor.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: width + 16, height: totalHeight)).fill()
    var y = gap
    for view in views.reversed() {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        rep.draw(in: NSRect(x: 8, y: y, width: view.frame.width, height: view.frame.height))
        y += view.frame.height + gap
    }
    image.unlockFocus()
    let tiff = image.tiffRepresentation!
    let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: renderPath))
    exit(0)
}

// EXP9_SELFTEST=1: headless checks on everything about the popup that is pure
// arithmetic — the row hit-testing inverse, the clamp that keeps the card
// inside the row, the deep links, and the clipping that forces the clamp.
// Event DELIVERY is not testable here; that is what --probe and a human are for.
if ProcessInfo.processInfo.environment["EXP9_SELFTEST"] == "1" {
    var failures: [String] = []
    func check(_ condition: Bool, _ name: String) {
        print("\(condition ? "PASS" : "FAIL")  \(name)")
        if !condition { failures.append(name) }
    }

    let view = DavidComponentView(title: "selftest", cells: davidCells(columns: 16))
    view.frame.size.width = 340

    // 1. Every seeded day with work has a card, and every row of that card
    //    hit-tests back to its own index — the inverse the click path relies on.
    let seeded = [2, 5, 9, 16, 23, 30, 44, 61, 75, 104]
    for cell in seeded {
        guard let geometry = view.popupGeometry(forCell: cell) else {
            check(false, "cell \(cell) produces a popup"); continue
        }
        let items = view.items(forCell: cell)
        check(geometry.rows.count == items.count, "cell \(cell): \(items.count) rows for \(items.count) items")
        for (row, rect) in geometry.rows.enumerated() {
            let hit = geometry.rows.firstIndex { $0.contains(CGPoint(x: rect.midX, y: rect.midY)) }
            check(hit == row, "cell \(cell) row \(row): centre hit-tests to itself")
        }
        // 2. The clamp: the card never leaves the row it is drawn in, including
        //    for the last column (104) where "to the right" does not fit.
        check(view.bounds.contains(geometry.frame), "cell \(cell): card stays inside the row's bounds")
    }

    // 3. The list case actually exists — an assignment AND a quiz on one day.
    let multi = view.items(forCell: 23)
    check(multi.count == 2 && multi[0].kind == .assignment && multi[1].kind == .quiz,
          "cell 23 is the list case: one assignment + one quiz")
    check(view.items(forCell: 44).count == 3, "cell 44 holds three items")

    // 4. The deep links are the shapes experiment 7 verified.
    check(multi[0].url.absoluteString
        == "https://purdue.brightspace.com/d2l/lms/dropbox/user/folder_submit_files.d2l?db=648913&grpid=0&ou=412690",
        "assignment link shape")
    check(multi[1].url.absoluteString
        == "https://purdue.brightspace.com/d2l/lms/quizzing/user/quiz_summary.d2l?qi=619245&ou=412690",
        "quiz link shape")

    // 5. Does a view's drawing survive outside its own frame? The card is
    //    clamped inside the row either way, but the answer decides whether
    //    overhanging is a lever the production port may pull.
    DavidComponentView.drawsOutOfBoundsProbe = true
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 200))
    let clipped = DavidComponentView(title: "clip", cells: davidCells(columns: 16))
    clipped.frame = NSRect(x: 10, y: 60, width: 340, height: clipped.frame.height)
    host.addSubview(clipped)
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    DavidComponentView.drawsOutOfBoundsProbe = false
    // The bitmap is Retina — 2 pixels per point — so a view-space y maps to
    // scale * (host.height - (view.frame.minY + y)). Sampling in points is the
    // mistake that made an earlier version of this check pass vacuously.
    let scale = CGFloat(rep.pixelsHigh) / host.bounds.height
    func bandIsPainted(atViewY y: CGFloat) -> Bool {
        let row = Int(scale * (host.bounds.height - (clipped.frame.minY + y)))
        return stride(from: 20, to: 340, by: 20).contains { x in
            (rep.colorAt(x: Int(CGFloat(x) * scale), y: row)?.alphaComponent ?? 0) > 0.01
        }
    }
    let inside = bandIsPainted(atViewY: 8)
    let outside = bandIsPainted(atViewY: -8)
    // Control: if the INSIDE band is missing, the sampling is wrong and the
    // result below means nothing.
    check(inside, "control: a band inside the view's bounds IS sampled")
    // The finding, pinned so a future OS default change fails here loudly.
    // macOS 15 ships clipsToBounds = false, so a view CAN paint outside its
    // own frame; the card is clamped by choice, not by force.
    print("      clipsToBounds=\(clipped.clipsToBounds), out-of-bounds band painted=\(outside)")
    check(outside == !clipped.clipsToBounds,
          "out-of-bounds drawing follows clipsToBounds (false on macOS 15 → NOT clipped)")

    print(failures.isEmpty
        ? "\nSELFTEST PASS — \(seeded.count) seeded days, geometry inverse and links verified"
        : "\nSELFTEST FAIL — \(failures.count): \(failures.joined(separator: ", "))")
    exit(failures.isEmpty ? 0 : 1)
}

// EXP9_PROBE=1: open the menu without a human and interrogate it from inside
// its own tracking loop — can our code run there, can a panel float above it,
// can a popover show at all? Writes artifacts/probe.log.
if ProcessInfo.processInfo.environment["EXP9_PROBE"] == "1" {
    let logPath = ProcessInfo.processInfo.environment["EXP9_PROBE_LOG"] ?? "probe.log"
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(1))
        MenuOverlayProbe.drive(menu: menu, anchor: davidRow.view, logPath: logPath)
    }
}

app.run()
