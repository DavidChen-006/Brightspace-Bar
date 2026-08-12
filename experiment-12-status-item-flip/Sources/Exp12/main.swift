import AppKit

// ═════════════════════════════════════════════════════════════════════════════
// Experiment 12 — the status item IS the notification.
//
// Microsoft MFA number matching shows a 2-digit code that the human must type
// on their phone. We can scrape it headlessly; the open question is how to SHOW
// it. A notification banner needs a glance the user may not give (Do Not
// Disturb swallows it) and an alert steals focus. The menu bar is already in
// the user's eyeline, always visible, and DND has no opinion about it.
//
// So: temporarily repaint the status item as the code, then revert.
//
//   normal:    [book.closed]
//   challenge: [lock.badge.exclamationmark 20]   ← treatment A
//              [ 🔐 20 ]  bold red, no symbol    ← treatment B
//
// The levers below flip between those live, so the question "is it readable at
// a glance in a real menu bar" is answered by looking, not by reasoning.
//
// Sync top level (the experiment-5 lesson: a top-level await starves the
// MainActor and blanks the menu).
// ═════════════════════════════════════════════════════════════════════════════

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

/// The two visual treatments under test. Both are set on the SAME
/// `statusItem.button`; nothing is rebuilt, which is why the flip is free.
enum Treatment: String {
    /// SF Symbol + plain title. Inherits the menu bar's own text color, so it
    /// tracks dark/light and the "reduce transparency" wallpaper cases for free.
    case symbolAndText = "A: symbol + text"
    /// No symbol; an attributed title — bold, rounded, systemRed, with a lock
    /// emoji doing the icon's job. Louder, but the color is ours to get wrong.
    case boldRedText = "B: bold red text"
}

@MainActor
final class Flipper: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var treatment: Treatment = .symbolAndText
    /// The code currently displayed, or nil when showing the normal icon —
    /// kept so a treatment switch can repaint without re-deciding the state.
    var shownCode: Int?
    var revertTimer: Timer?
    var blinkTimer: Timer?

    // ── The two states ──────────────────────────────────────────────────────

    func showIcon() {
        revertTimer?.invalidate()
        revertTimer = nil
        stopBlink()
        shownCode = nil
        let started = Date()
        guard let button = item.button else { return }
        button.attributedTitle = NSAttributedString(string: "")
        button.title = ""
        button.image = NSImage(systemSymbolName: "book.closed", accessibilityDescription: "BrightspaceBar")
        button.imagePosition = .imageOnly
        report("icon", since: started)
    }

    func show(code: Int) {
        let started = Date()
        shownCode = code
        guard let button = item.button else { return }
        switch treatment {
        case .symbolAndText:
            button.image = NSImage(
                systemSymbolName: "lock.badge.exclamationmark",
                accessibilityDescription: "MFA code \(code)"
            )
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(string: "")
            button.title = " \(code)"
        case .boldRedText:
            button.image = nil
            button.imagePosition = .noImage
            // Monospaced digits so a code with a 1 in it does not visibly
            // shrink the item and shove every neighbour left.
            button.attributedTitle = NSAttributedString(
                string: "🔐 \(code)",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .bold),
                    .foregroundColor: NSColor.systemRed,
                ]
            )
        }
        report("code \(code) via \(treatment.rawValue)", since: started)
    }

    /// Repaints whatever state we are already in — used when the treatment
    /// changes mid-challenge, so David can A/B without restarting the flow.
    func repaint() {
        if let code = shownCode { show(code: code) } else { showIcon() }
    }

    // ── Attention treatment: pulse the whole button ─────────────────────────
    // `appearsDisabled` is the cheapest blink there is — AppKit dims the button
    // (image AND title, tinted or not) without us touching the content, so it
    // stacks on either treatment without either knowing about it.

    func startBlink() {
        stopBlink()
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let button = self?.item.button else { return }
                button.appearsDisabled.toggle()
            }
        }
        // .common, not .default: while a menu is open the run loop is in
        // .eventTracking, and a .default-mode timer silently stops firing.
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    func stopBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        item.button?.appearsDisabled = false
    }

    // ── Levers ──────────────────────────────────────────────────────────────

    @objc func showFixed(_ sender: NSMenuItem) { show(code: 20) }

    @objc func showRandom(_ sender: NSMenuItem) { show(code: Int.random(in: 10...99)) }

    /// The real use case: a challenge appears, the human types it on the phone,
    /// the challenge resolves, the icon comes back — all with no click here.
    @objc func simulateChallenge(_ sender: NSMenuItem) {
        show(code: Int.random(in: 10...99))
        revertTimer?.invalidate()
        let timer = Timer(timeInterval: 8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showIcon() }
        }
        RunLoop.main.add(timer, forMode: .common)
        revertTimer = timer
        print("challenge simulated — auto-revert in 8s")
    }

    @objc func toggleTreatment(_ sender: NSMenuItem) {
        treatment = (treatment == .symbolAndText) ? .boldRedText : .symbolAndText
        sender.title = "Treatment → switch to \(treatment == .symbolAndText ? Treatment.boldRedText.rawValue : Treatment.symbolAndText.rawValue)"
        repaint()
    }

    @objc func toggleBlink(_ sender: NSMenuItem) {
        if blinkTimer == nil {
            startBlink()
            sender.title = "Blink: ON (click to stop)"
        } else {
            stopBlink()
            sender.title = "Blink: off"
        }
    }

    @objc func reset(_ sender: NSMenuItem) { showIcon() }

    @objc func quit(_ sender: NSMenuItem) { NSApp.terminate(nil) }

    /// Every flip is timestamped: the claim "instantaneous" should be a number,
    /// not a vibe. Measures the set itself, not the redraw — but the redraw is
    /// the next run-loop pass, so the two are within a frame of each other.
    private func report(_ what: String, since started: Date) {
        let ms = Date().timeIntervalSince(started) * 1000
        print(String(format: "flip → %@  (%.3f ms on the main thread)", what, ms))
    }
}

let flipper = Flipper()

func lever(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.target = flipper
    return item
}

func header(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
}

let menu = NSMenu()
menu.autoenablesItems = false
[
    header("Status item flip"),
    NSMenuItem.separator(),
    lever("Show code 20", #selector(Flipper.showFixed(_:))),
    lever("Show random code", #selector(Flipper.showRandom(_:))),
    lever("Simulate challenge (auto-revert in 8s)", #selector(Flipper.simulateChallenge(_:))),
    lever("Reset to icon", #selector(Flipper.reset(_:))),
    NSMenuItem.separator(),
    lever("Treatment → switch to \(Treatment.boldRedText.rawValue)", #selector(Flipper.toggleTreatment(_:))),
    lever("Blink: off", #selector(Flipper.toggleBlink(_:))),
    NSMenuItem.separator(),
    lever("Quit", #selector(Flipper.quit(_:)), key: "q"),
].forEach(menu.addItem)

flipper.item.menu = menu
flipper.showIcon()

// EXP12_SELFTEST=1: drive the levers without a human so the flip timings get
// measured rather than asserted, then quit. Not a test — a stopwatch.
if ProcessInfo.processInfo.environment["EXP12_SELFTEST"] == "1" {
    Task { @MainActor in
        for step in 1...6 {
            try? await Task.sleep(for: .milliseconds(400))
            flipper.treatment = step > 3 ? .boldRedText : .symbolAndText
            step.isMultiple(of: 3) ? flipper.showIcon() : flipper.show(code: Int.random(in: 10...99))
        }
        try? await Task.sleep(for: .milliseconds(400))
        NSApp.terminate(nil)
    }
}

app.run()
