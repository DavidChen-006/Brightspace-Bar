import AppKit

// ═════════════════════════════════════════════════════════════════════════════
// Experiment 15 — the speed-gated afterglow, in one menu.
//
// One David-style grid row, seeded with the same named semester as exp 9/14,
// carrying exp 14's haptic detents UNCHANGED plus one new ingredient: a comet
// tail behind the hover outline that only blooms above a speed threshold (see
// AfterglowGridView). Sweep fast and slow alternately and judge whether the
// fast one feels better — if it does, muscle memory is forming.
//
// Sync top level (the experiment-5 lesson: a top-level await starves the
// MainActor and blanks the menu).
// ═════════════════════════════════════════════════════════════════════════════

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

func semesterCells(columns: Int) -> [DayCell] {
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

@MainActor
final class MenuController: NSObject, @preconcurrency NSMenuDelegate {
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for menuItem in menu.items {
            if let grid = menuItem.view as? AfterglowGridView {
                grid.isHighlightedForMenu = (menuItem === item)
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

let gridRow = NSMenuItem(title: "", action: #selector(ClickTarget.open(_:)), keyEquivalent: "")
gridRow.target = target
gridRow.representedObject = URL(string: "https://purdue.brightspace.com/d2l/home/412690")!
gridRow.view = AfterglowGridView(
    title: "DAVID 10000 — Afterglow Playground",
    cells: semesterCells(columns: 16)
)

let quitRow = NSMenuItem(title: "Quit", action: #selector(ClickTarget.quit(_:)), keyEquivalent: "q")
quitRow.target = target

let menu = NSMenu()
menu.autoenablesItems = false
menu.delegate = controller
menu.addItem(gridRow)
menu.addItem(.separator())
menu.addItem(quitRow)

let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
statusItem.button?.image = NSImage(
    systemSymbolName: "wind", accessibilityDescription: "Experiment 15"
)
statusItem.menu = menu

app.run()
