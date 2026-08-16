import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// The negative-findings harness: what happens if the popup is NOT drawn inside
// the menu item view but in a surface of its own?
//
// Three questions, and the difficulty is that an open NSMenu blocks the main
// thread inside its own modal event loop, so ordinary `Task { }` and default
// run-loop work never runs while the menu is up:
//
//   Q1. Can our code run at all mid-tracking?  A timer scheduled ONLY in
//       `.eventTracking` proves it by firing.
//   Q2. Can an NSPanel float ABOVE the open menu?  Order one in, then read the
//       real z-order back from the window server.
//   Q3. Can an NSPopover be shown from a view inside a menu window?
//
// Everything is written to a log file as well as stdout, because the app is
// normally launched as a bundle where stdout goes nowhere.
//
// What this harness deliberately does NOT measure: whether a click reaches the
// panel. That needs synthetic input, which needs Accessibility permission this
// machine has not granted (`AXIsProcessTrusted() == false`, checked). The
// README marks that answer REASONED, not MEASURED, and says why.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
enum MenuOverlayProbe {

    private static var handle: FileHandle?
    private static var panel: NSPanel?
    private static var popover: NSPopover?

    static func open(logPath: String) {
        FileManager.default.createFile(atPath: logPath, contents: nil)
        self.handle = FileHandle(forWritingAtPath: logPath)
        self.log("=== exp9 menu-overlay probe — \(Date()) ===")
    }

    static func log(_ line: String) {
        print("[exp9probe] \(line)")
        self.handle?.write(Data(("[exp9probe] " + line + "\n").utf8))
    }

    /// Runs while the menu is open. `menu` is the tracking menu; `anchor` is
    /// the David row's view, which lives inside the menu's own window.
    static func probe(menu: NSMenu, anchor: NSView?) {
        // Q1 — we are here at all, from a timer registered only in
        // .eventTracking, so this line is the answer.
        self.log("Q1 mid-tracking execution: FIRED. runLoopMode=\(RunLoop.current.currentMode?.rawValue ?? "nil")")
        self.log("Q1 menu.highlightedItem=\(menu.highlightedItem?.title ?? "nil") anchorWindow=\(anchor?.window?.className ?? "nil")")

        self.probePanel(near: anchor)
        self.probePopover(anchor: anchor)
        self.dumpWindowOrder(tag: "after both overlays shown")
        self.warpOntoCell(23)
    }

    // MARK: - Q4, hover delivery, measured without a human

    /// Moves the REAL cursor onto a seeded cell of the David row while the menu
    /// is open, so the hover path can be observed end to end.
    ///
    /// `CGWarpMouseCursorPosition` only moves the cursor — it posts no event and
    /// needs no Accessibility permission, which this machine has not granted
    /// (`AXIsProcessTrusted() == false`). If the view's state changes anyway,
    /// AppKit synthesised the motion and hover genuinely works during tracking.
    private static func warpOntoCell(_ index: Int) {
        guard let view = self.trackedAnchor as? DavidComponentView,
              let window = view.window,
              let centre = view.cellCenter(forCell: index) else {
            self.log("Q4 warp: SKIPPED — no David view on screen")
            return
        }
        self.log("Q4 before warp: \(view.hoverStateDescription)")
        // The probe borrows the user's actual cursor; teardown puts it back.
        self.cursorHome = NSEvent.mouseLocation

        let inWindow = view.convert(centre, to: nil)
        let onScreen = window.convertPoint(toScreen: inWindow)
        // CG global space is top-left origin off the PRIMARY display; Cocoa
        // screen space is bottom-left. This flip is the whole conversion.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let target = CGPoint(x: onScreen.x, y: primaryHeight - onScreen.y)
        self.log("Q4 warping cursor to cell \(index): view\(centre) → screen\(onScreen) → CG\(target)")
        CGWarpMouseCursorPosition(target)

        // Read the state back a beat later, still inside tracking.
        let timer = Timer(timeInterval: 0.5, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard let view = Self.trackedAnchor as? DavidComponentView else { return }
                Self.log("Q4 after warp:  \(view.hoverStateDescription)")
                Self.log("Q4 cursor now at \(NSEvent.mouseLocation)")
                Self.injectEvents(onto: index)
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    // MARK: - Q5, hover and click delivery, measured by injected events

    /// Posts real `NSEvent`s into our OWN application queue — `NSApp.postEvent`,
    /// not `CGEventPost` — which needs no Accessibility permission. If the
    /// menu's modal tracking loop dequeues them, the whole hover→popup→click
    /// path is measured with nobody at the keyboard.
    private static func injectEvents(onto index: Int) {
        guard let view = self.trackedAnchor as? DavidComponentView,
              let window = view.window,
              let centre = view.cellCenter(forCell: index) else { return }
        let inWindow = view.convert(centre, to: nil)

        func post(_ type: NSEvent.EventType, at point: NSPoint, clicks: Int) {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: clicks, pressure: 0
            ) else {
                self.log("Q5 could not build a \(type) event")
                return
            }
            NSApp.postEvent(event, atStart: false)
        }

        self.log("Q5 posting mouseMoved into our own queue at window\(inWindow)")
        post(.mouseMoved, at: inWindow, clicks: 0)

        let readback = Timer(timeInterval: 0.4, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard let view = Self.trackedAnchor as? DavidComponentView else { return }
                Self.log("Q5 after injected mouseMoved: \(view.hoverStateDescription)")
                Self.injectRowClick()
            }
        }
        RunLoop.main.add(readback, forMode: .eventTracking)
    }

    /// If the popup did open, aim a click at its second row — the quiz on the
    /// two-item day — with link opening switched to a dry run.
    private static func injectRowClick() {
        guard let view = self.trackedAnchor as? DavidComponentView,
              let window = view.window else { return }
        guard let geometry = view.popupGeometry(forCell: 23), geometry.rows.count > 1 else {
            self.log("Q5 row click: SKIPPED — no popup geometry")
            return
        }
        let row = geometry.rows[1]
        let inWindow = view.convert(CGPoint(x: row.midX, y: row.midY), to: nil)
        DavidComponentView.opensLinksForReal = false
        self.log("Q5 posting leftMouseDown+Up on popup row 1 at window\(inWindow)")
        // A lone mouse-up is discarded by the tracking loop (measured on the
        // previous run), so the pair is posted the way a real click arrives.
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: inWindow, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0
            ) {
                NSApp.postEvent(event, atStart: false)
            }
        }

        let readback = Timer(timeInterval: 0.4, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard let view = Self.trackedAnchor as? DavidComponentView else { return }
                Self.log("Q5 after injected click: \(view.hoverStateDescription)"
                    + " menuStillOpen=\(Self.trackedMenu?.highlightedItem != nil || view.window != nil)")
            }
        }
        RunLoop.main.add(readback, forMode: .eventTracking)
    }

    // MARK: - Q2, a panel of our own

    private static func probePanel(near anchor: NSView?) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        // Order matters and cost us a run: `isFloatingPanel = true` SETS the
        // level to .floating (3), so assigning the level first silently threw
        // it away and the panel measured as "below the menu" for the wrong
        // reason. Level is assigned last, and read back below.
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.backgroundColor = .windowBackgroundColor
        panel.ignoresMouseEvents = false
        panel.contentView = ProbePanelContentView(frame: NSRect(x: 0, y: 0, width: 220, height: 60))

        // Park it beside the menu so a human watching can see whether it is on
        // top of, or buried under, the open menu.
        if let window = anchor?.window {
            let f = window.frame
            panel.setFrameOrigin(NSPoint(x: f.maxX + 8, y: f.midY))
        } else {
            panel.setFrameOrigin(NSPoint(x: 600, y: 600))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        self.log("Q2 panel: isVisible=\(panel.isVisible) level=\(panel.level.rawValue) (menu level is \(NSWindow.Level.popUpMenu.rawValue)) "
            + "occlusion=\(panel.occlusionState.contains(.visible) ? "visible" : "occluded") "
            + "windowNumber=\(panel.windowNumber)")
    }

    /// A content view that shouts if it is ever hit — so if a human DOES click
    /// the panel while the menu is open, the transcript records it.
    private final class ProbePanelContentView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.setFill()
            dirtyRect.fill()
            NSAttributedString(string: "probe panel", attributes: [
                .font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.labelColor,
            ]).draw(at: NSPoint(x: 10, y: 22))
        }
        override func mouseDown(with event: NSEvent) {
            MenuOverlayProbe.log("Q2 panel RECEIVED mouseDown — a panel CAN take clicks during tracking")
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            MenuOverlayProbe.log("Q2 panel hitTest at \(point)")
            return super.hitTest(point)
        }
    }

    // MARK: - Q3, a popover from a view inside the menu window

    private static func probePopover(anchor: NSView?) {
        guard let anchor else {
            self.log("Q3 popover: SKIPPED — no anchor view")
            return
        }
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 50))
        popover.contentViewController = content
        self.popover = popover

        // Whether this throws, no-ops, or shows is the finding.
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        self.log("Q3 popover: isShown=\(popover.isShown) "
            + "contentWindow=\(popover.contentViewController?.view.window.map { "\($0.windowNumber)@level\($0.level.rawValue)" } ?? "none")")
    }

    // MARK: - The window server's own account, front to back

    static func dumpWindowOrder(tag: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            self.log("z-order (\(tag)): CGWindowListCopyWindowInfo returned nil")
            return
        }
        self.log("z-order (\(tag)) — front to back, this process only:")
        for entry in list where (entry[kCGWindowOwnerPID as String] as? Int32) == pid {
            let number = entry[kCGWindowNumber as String] as? Int ?? -1
            let layer = entry[kCGWindowLayer as String] as? Int ?? -1
            let bounds = entry[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let name = entry[kCGWindowName as String] as? String ?? ""
            let mine = number == self.panel?.windowNumber ? "  ← our probe panel" : ""
            self.log("    #\(number) layer=\(layer) \(bounds) \(name)\(mine)")
        }
    }

    private static var cursorHome: CGPoint?

    static func teardown() {
        self.popover?.close()
        self.panel?.orderOut(nil)
        if let home = self.cursorHome {
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            CGWarpMouseCursorPosition(CGPoint(x: home.x, y: primaryHeight - home.y))
            self.log("cursor returned to \(home)")
        }
        self.log("teardown complete")
        try? self.handle?.close()
    }

    // MARK: - Driving the whole run with nobody at the keyboard

    private static var trackedMenu: NSMenu?
    private static var trackedAnchor: NSView?

    /// Opens the menu itself and probes it from inside its own tracking loop,
    /// so the run needs no human and no synthetic input.
    ///
    /// The scheduling is the trick: work is enqueued in `.eventTracking` BEFORE
    /// `popUp`, because `popUp` does not return until the menu closes. If the
    /// enqueued work never runs, the watchdog below ends the process — and that
    /// silence would itself be the finding.
    static func drive(menu: NSMenu, anchor: NSView?, logPath: String) {
        self.open(logPath: logPath)
        self.trackedMenu = menu
        self.trackedAnchor = anchor
        self.dumpWindowOrder(tag: "before the menu opens")

        RunLoop.main.perform(inModes: [.eventTracking]) {
            MainActor.assumeIsolated {
                guard let menu = Self.trackedMenu else { return }
                Self.probe(menu: menu, anchor: Self.trackedAnchor)
                Self.scheduleFinish()
            }
        }

        // Watchdog on a thread the menu's modal loop cannot block.
        DispatchQueue.global().asyncAfter(deadline: .now() + 12) {
            MenuOverlayProbe.logFromAnyThread("WATCHDOG — 12s elapsed, exiting")
            exit(3)
        }

        let screenTop = NSScreen.main?.frame.height ?? 1000
        self.log("popping the menu open at (400, \(screenTop - 60))")
        menu.popUp(positioning: nil, at: NSPoint(x: 400, y: screenTop - 60), in: nil)
        self.log("popUp returned — menu tracking has ended")
        self.teardown()
        exit(0)
    }

    private static func scheduleFinish() {
        let timer = Timer(timeInterval: 3.0, repeats: false) { _ in
            MainActor.assumeIsolated {
                Self.log("Q1 second timer in .eventTracking also fired — tracking mode keeps servicing timers")
                Self.dumpWindowOrder(tag: "2s later, menu still open")
                Self.trackedMenu?.cancelTracking()
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    /// The watchdog runs off the main thread, so it cannot touch the
    /// MainActor-isolated file handle; stdout is enough for its one line.
    nonisolated static func logFromAnyThread(_ line: String) {
        print("[exp9probe] \(line)")
    }
}
