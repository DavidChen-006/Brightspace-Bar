import AppKit
import UserNotifications

// ═════════════════════════════════════════════════════════════════════════════
// Experiment 13 — can a notification be (a) fired on demand, (b) pushed
// THROUGH Do Not Disturb, and (c) held on screen for EXACTLY 6 seconds?
//
// Why this exists: BrightspaceBar's login sometimes hits Microsoft MFA number
// matching — a 2-digit code appears headlessly and the human must type it on
// their phone. A notification is the obvious carrier, except David runs Focus
// permanently, so an ordinary notification never arrives. macOS's answer is
// `UNNotificationInterruptionLevel.timeSensitive`, which Apple documents as
// breaking through Focus. This experiment tests whether an UNSIGNED (ad-hoc
// signed) local build can actually claim it.
//
// The menu:
//   Fire time-sensitive (auto-dismiss 6s)   ← the candidate
//   Fire normal (auto-dismiss 6s)           ← A/B control under DND
//   Fire time-sensitive, no auto-dismiss    ← observe the OS's own lifetime
//   ───────────────
//   Quit
//
// Two hard constraints discovered while building, both encoded here:
//   1. `UNUserNotificationCenter.current()` TRAPS if the process has no bundle
//      identifier. A bare `swift run` binary is not enough — Scripts/run.sh
//      assembles a real .app. We guard and say so rather than crash opaquely.
//   2. Launched via `open`, stdout goes nowhere. Every log line is therefore
//      mirrored into artifacts/run.log so the run is readable after the fact.
// ═════════════════════════════════════════════════════════════════════════════

// ── Logging: stdout AND a file, because `open` detaches stdout ───────────────

/// Where the mirror lives. EXP13_LOG is set by run.sh; without it, file
/// mirroring is simply skipped (running the binary straight from a terminal
/// already shows stdout).
let logURL = ProcessInfo.processInfo.environment["EXP13_LOG"].map(URL.init(fileURLWithPath:))

let logFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
}()

nonisolated func log(_ message: String) {
    let line = "[\(logFormatter.string(from: Date()))] \(message)\n"
    FileHandle.standardOutput.write(Data(line.utf8))
    guard let logURL else { return }
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: logURL)
    }
}

// ── App ─────────────────────────────────────────────────────────────────────

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

log("=== Experiment 13 starting ===")
log("bundleIdentifier = \(Bundle.main.bundleIdentifier ?? "nil")")
log("bundlePath       = \(Bundle.main.bundlePath)")

// Constraint 1, made explicit. Calling `.current()` without a bundle id is a
// hard trap inside UserNotifications, not a catchable error, so we refuse
// first and print the fix.
guard Bundle.main.bundleIdentifier != nil else {
    log("FATAL: no CFBundleIdentifier — UNUserNotificationCenter.current() would trap.")
    log("       Run ./Scripts/run.sh instead of the bare binary.")
    exit(1)
}

let center = UNUserNotificationCenter.current()

/// macOS shows a banner for a notification whose own app is frontmost only if
/// the delegate asks for it. An `.accessory` app is rarely "frontmost", but the
/// delegate also gives us a free observation point: `willPresent` firing is
/// proof the notification reached the presentation stage rather than being
/// dropped, and it reports the interruption level the SYSTEM ended up with.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let content = notification.request.content
        log("willPresent id=\(notification.request.identifier) level=\(describe(content.interruptionLevel)) — requesting .banner + .sound")
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        log("didReceive action=\(response.actionIdentifier) id=\(response.notification.request.identifier)")
        completionHandler()
    }
}

nonisolated func describe(_ level: UNNotificationInterruptionLevel) -> String {
    switch level {
    case .passive: "passive"
    case .active: "active"
    case .timeSensitive: "timeSensitive"
    case .critical: "critical"
    @unknown default: "unknown(\(level.rawValue))"
    }
}

let notificationDelegate = NotificationDelegate()
center.delegate = notificationDelegate

// ── Authorization ───────────────────────────────────────────────────────────
// Requested at launch. The first run raises the system prompt; later runs are
// answered from the stored decision. `getNotificationSettings` afterwards is
// the honest reading — `granted` only tells us the user's answer, while
// settings tell us what the app may actually DO (alert style, whether it is
// allowed in Focus, whether it can show on the lock screen).

/// Dump what the OS currently permits. Called BEFORE the authorization request
/// as well as after, because the first run's request blocks indefinitely while
/// the system prompt waits for a human — measured the hard way: with the prompt
/// on screen, `requestAuthorization` never returns, so anything sequenced after
/// it (including the settings dump) silently never runs.
@MainActor
func logSettings(_ label: String) async {
    let settings = await center.notificationSettings()
    log("[\(label)] authorizationStatus  = \(settings.authorizationStatus.rawValue) (0=notDetermined 1=denied 2=authorized 3=provisional)")
    log("[\(label)] alertSetting         = \(settings.alertSetting.rawValue) (0=notSupported 1=disabled 2=enabled)")
    log("[\(label)] alertStyle           = \(settings.alertStyle.rawValue) (0=none 1=banner 2=alert)  ← banner auto-hides, alert persists")
    log("[\(label)] timeSensitiveSetting = \(settings.timeSensitiveSetting.rawValue) (0=notSupported 1=disabled 2=enabled)")
    log("[\(label)]   ^ timeSensitiveSetting is THE answer to 'did we get the entitlement':")
    log("[\(label)]     notSupported(0) = the OS does not believe this app may send time-sensitive.")
}

Task {
    await logSettings("before")
    log("requesting authorization — IF THIS IS THE FIRST RUN, a system prompt is now")
    log("waiting for you on screen. Nothing below this line prints until you answer it.")
    do {
        let granted = try await center.requestAuthorization(options: [.alert, .sound])
        log("requestAuthorization granted = \(granted)")
    } catch {
        log("requestAuthorization FAILED: \(error)")
    }
    await logSettings("after")
}

// ── Firing ──────────────────────────────────────────────────────────────────

// Top-level code is already MainActor-isolated, so this needs no attribute
// (and Swift 6 rejects one here).
var fireCount = 0

/// Deliver one notification and, optionally, withdraw it after exactly 6.0s.
///
/// Three things are measured here and nowhere else:
///   • whether `add` returns without error (the request was accepted),
///   • what interruption level the DELIVERED copy reports — if the OS
///     downgrades an unauthorised `.timeSensitive`, this is where it shows,
///   • the real wall-clock gap between delivery and the withdrawal call, so
///     "exactly 6 seconds" is a measurement rather than a hope.
@MainActor
func fire(timeSensitive: Bool, autoDismissAfter seconds: Double?) {
    fireCount += 1
    let id = "exp13-\(fireCount)"

    let content = UNMutableNotificationContent()
    content.title = "BrightspaceBar — approve sign-in"
    content.body = "Enter 20 on your phone"
    content.sound = .default
    content.interruptionLevel = timeSensitive ? .timeSensitive : .active

    log("--- fire id=\(id) requested level=\(describe(content.interruptionLevel)) autoDismiss=\(seconds.map { "\($0)s" } ?? "no") ---")

    let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
    let requestedAt = Date()

    Task {
        do {
            try await center.add(request)
            log("add() accepted id=\(id) after \(String(format: "%.3f", Date().timeIntervalSince(requestedAt)))s")
        } catch {
            log("add() FAILED id=\(id): \(error)")
            return
        }

        // What the OS permits AT THE MOMENT OF FIRING — the launch-time dump is
        // stale once David toggles anything in System Settings → Notifications.
        let settings = await center.notificationSettings()
        log("at-fire: authStatus=\(settings.authorizationStatus.rawValue) alertStyle=\(settings.alertStyle.rawValue) timeSensitiveSetting=\(settings.timeSensitiveSetting.rawValue)")

        // Read the delivered copy back. If the system stripped or downgraded
        // the interruption level, the level reported here differs from the one
        // we asked for. Absence from this list is also informative: it means
        // the notification never landed in Notification Center.
        let delivered = await center.deliveredNotifications()
        if let mine = delivered.first(where: { $0.request.identifier == id }) {
            log("delivered id=\(id) level-as-delivered=\(describe(mine.request.content.interruptionLevel)) date=\(mine.date)")
        } else {
            log("delivered id=\(id) NOT FOUND in deliveredNotifications() — it did not reach Notification Center")
        }
        log("deliveredNotifications() now holds \(delivered.count): \(delivered.map(\.request.identifier).joined(separator: ", "))")

        guard let seconds else {
            log("id=\(id) left alone — watch how long the OS itself keeps the banner up")
            return
        }

        // The 6-second lever, timed from the DELIVERY timestamp (not the
        // request timestamp) so the interval measured is banner-visible time.
        let deliveredAt = Date()
        afterPrecisely(seconds) {
            let elapsed = Date().timeIntervalSince(deliveredAt)
            log("withdrawing id=\(id) at +\(String(format: "%.3f", elapsed))s (asked for \(seconds)s)")
            center.removeDeliveredNotifications(withIdentifiers: [id])

            // Confirm the removal took at the DATA layer. Whether the pixels
            // went with it is David's call — this process cannot see a screen.
            Task {
                let after = await center.deliveredNotifications()
                let stillThere = after.contains { $0.request.identifier == id }
                log("post-withdraw: id=\(id) still in Notification Center = \(stillThere); remaining = \(after.count)")
            }
        }
    }
}

/// Run `body` at exactly `seconds` from now.
///
/// MEASURED: `Task.sleep(for: .seconds(6))` fired at +6.328s in an idle
/// `.accessory` app — macOS coalesces timers for a napping process, and a
/// third of a second is a lot when the whole question is "exactly 6.0". A
/// DispatchSourceTimer with 1ms leeway, held awake by a `beginActivity`
/// assertion for the duration, lands within a few milliseconds.
var liveTimers: [DispatchSourceTimer] = []

// Top-level FUNCTIONS (unlike top-level vars) are not MainActor by default.
@MainActor
func afterPrecisely(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
    let activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .latencyCritical],
        reason: "pinning a notification's on-screen lifetime"
    )
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + seconds, leeway: .milliseconds(1))
    timer.setEventHandler {
        MainActor.assumeIsolated {
            body()
            liveTimers.removeAll { $0 === timer }
        }
        ProcessInfo.processInfo.endActivity(activity)
    }
    liveTimers.append(timer)   // a DispatchSourceTimer dies with its last reference
    timer.resume()
}

// ── Menu ────────────────────────────────────────────────────────────────────

@MainActor
final class Levers: NSObject {
    @objc func fireTimeSensitive(_ sender: NSMenuItem) { fire(timeSensitive: true, autoDismissAfter: 6.0) }
    @objc func fireNormal(_ sender: NSMenuItem) { fire(timeSensitive: false, autoDismissAfter: 6.0) }
    @objc func fireTimeSensitiveNoDismiss(_ sender: NSMenuItem) { fire(timeSensitive: true, autoDismissAfter: nil) }
    @objc func quit(_ sender: NSMenuItem) { log("=== quit ==="); NSApp.terminate(nil) }
}

let levers = Levers()

func item(_ title: String, _ action: Selector) -> NSMenuItem {
    let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
    menuItem.target = levers
    return menuItem
}

let menu = NSMenu()
menu.autoenablesItems = false
menu.addItem(item("Fire time-sensitive notification (auto-dismiss 6s)", #selector(Levers.fireTimeSensitive(_:))))
menu.addItem(item("Fire normal notification (auto-dismiss 6s)", #selector(Levers.fireNormal(_:))))
menu.addItem(item("Fire time-sensitive, no auto-dismiss", #selector(Levers.fireTimeSensitiveNoDismiss(_:))))
menu.addItem(.separator())
menu.addItem(item("Quit", #selector(Levers.quit(_:))))

let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
statusItem.button?.image = NSImage(systemSymbolName: "bell.badge", accessibilityDescription: "Experiment 13")
statusItem.menu = menu

// EXP13_AUTOFIRE=1: fire the time-sensitive lever once, unattended, ~2s after
// launch. Lets the harness prove delivery end to end without a human click —
// the LOG is the evidence; the pixels still need David.
if ProcessInfo.processInfo.environment["EXP13_AUTOFIRE"] == "1" {
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(2))
        log("EXP13_AUTOFIRE — firing the time-sensitive lever unattended")
        fire(timeSensitive: true, autoDismissAfter: 6.0)
    }
}

// EXP13_PROBE=1: the CONTROL for the downgrade finding. Fires one notification
// at each interruption level and reads each delivered copy back. If `passive`
// and `active` survive the round trip but `timeSensitive` comes back as
// `active`, the downgrade is a real OS decision about THIS level — not the
// readback API flattening everything to a default.
if ProcessInfo.processInfo.environment["EXP13_PROBE"] == "1" {
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(2))
        log("EXP13_PROBE — round-tripping every interruption level")
        for (name, level) in [("passive", UNNotificationInterruptionLevel.passive),
                              ("active", .active),
                              ("timeSensitive", .timeSensitive)] {
            let id = "probe-\(name)"
            let content = UNMutableNotificationContent()
            content.title = "Exp13 probe — \(name)"
            content.body = "interruptionLevel = \(name)"
            content.interruptionLevel = level
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            let delivered = await center.deliveredNotifications()
            let got = delivered.first { $0.request.identifier == id }
            log("PROBE requested=\(name) delivered=\(got.map { describe($0.request.content.interruptionLevel) } ?? "NOT DELIVERED")")
        }
        try? await Task.sleep(for: .seconds(2))
        center.removeAllDeliveredNotifications()
        log("PROBE done — cleared")
    }
}

log("menu bar item installed — click the bell icon")
app.run()
