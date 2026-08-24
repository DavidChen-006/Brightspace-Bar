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

/// Seeds for the hover-popup experiment: every marked cell carries the NAME of
/// the thing it represents, laid out like a real Multivariable Calculus
/// semester, so hovering the graph answers "what is that red cell?".
func davidCells(columns: Int) -> [DayCell] {
    var cells = (0..<(columns * 7)).map { _ in DayCell(nil) }
    cells[2] = DayCell(.assignment, isToday: true, name: "HW 3 — Vector Fields (due today)")
    cells[5] = DayCell(.quiz, name: "Quiz 4 — Chain Rule")
    cells[9] = DayCell(.assignment, name: "HW 4 — Partial Derivatives")
    cells[16] = DayCell(.test, name: "Midterm 1 — Chapters 1–4")
    cells[23] = DayCell(.assignment, name: "HW 5 — Gradients")
    cells[30] = DayCell(.quiz, name: "Quiz 5 — Lagrange Multipliers")
    cells[44] = DayCell(.assignment, name: "HW 6 — Double Integrals")
    cells[61] = DayCell(.test, name: "Midterm 2 — Chapters 5–8")
    cells[75] = DayCell(.quiz, name: "Quiz 6 — Surface Area")
    cells[104] = DayCell(.test, name: "Final Exam — cumulative")
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

app.run()
