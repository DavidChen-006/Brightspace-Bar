import AppKit

// ═════════════════════════════════════════════════════════════════════════════
// Experiment 17 — how fast does the icon learn?
//
// The daemon writes BSB_ROOT/cache/mfa.json ({"number":"20","mintedAt":…})
// mid-login and the menu bar has to be showing that number before David has
// finished picking up his phone. Exp 12 already priced the repaint: 1-4 ms.
// So the only unknown left is the TRANSPORT — the gap between one process
// renaming a 60-byte file into place and this process having repainted.
//
// Three candidates, one app, chosen by EXP17_MODE:
//
//   kqueue    DispatchSource file-system object source on the cache DIRECTORY
//   fsevents  FSEventStream on the same directory, latency 0.1 s
//   poll      a 500 ms Timer that just re-reads the path (the dumb baseline)
//
// The writer stamps each file with the wall-clock instant it began the write;
// this app stamps the instant AFTER the status item has been repainted. The
// difference is the number that matters, and it is measured, not modelled.
// Both halves read CLOCK_REALTIME, which is the only clock two processes can
// agree on without a handshake.
//
// Sync top level (the experiment-5 lesson: a top-level await starves the
// MainActor and blanks the menu).
// ═════════════════════════════════════════════════════════════════════════════

let environment = ProcessInfo.processInfo.environment
let mode = environment["EXP17_MODE"] ?? "kqueue"
let root = environment["EXP17_ROOT"] ?? NSTemporaryDirectory() + "exp17-root"
let cacheDirectory = root + "/cache"
let mfaPath = cacheDirectory + "/mfa.json"
let resultsPath = environment["EXP17_RESULTS"] ?? root + "/results.jsonl"
let idleSeconds = Double(environment["EXP17_IDLE_SECONDS"] ?? "60") ?? 60

func nowEpochMillis() -> Double { Date().timeIntervalSince1970 * 1000 }

/// User + system CPU consumed by this process so far. The idle-cost question
/// ("what does this watcher charge when nothing is happening?") is answered by
/// the delta across a window in which, by construction, nothing happens.
func cpuMillisUsed() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let user = Double(usage.ru_utime.tv_sec) * 1000 + Double(usage.ru_utime.tv_usec) / 1000
    let system = Double(usage.ru_stime.tv_sec) * 1000 + Double(usage.ru_stime.tv_usec) / 1000
    return user + system
}

/// One line of evidence per detection, appended as JSON. `FileHandle.write` is
/// an unbuffered `write(2)`, so a run that ends with SIGTERM still leaves every
/// line it earned on disk.
@MainActor
final class Recorder {
    private let handle: FileHandle

    init(path: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            FileHandle.standardError.write(Data("exp17: cannot write \(path)\n".utf8))
            exit(1)
        }
        handle.seekToEndOfFile()
        self.handle = handle
    }

    func record(_ fields: [String: Any]) {
        var line = fields
        line["technique"] = mode
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
        else { return }
        handle.write(data)
        handle.write(Data("\n".utf8))
    }
}

let recorder = Recorder(path: resultsPath)

/// What woke us. A poll tick that finds nothing changed is the technique
/// working as designed; a kqueue/FSEvents event that finds nothing changed is
/// a wakeup somebody paid for and nobody needed — worth counting separately.
enum Wakeup {
    case event
    case tick
}

@MainActor
final class Probe {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let doomedWatcher = DoomedFileKqueueWatcher()
    /// The bytes last seen at the path, or nil for "no file there". Comparing
    /// content is what makes an atomic writer safe to watch: the temp file's
    /// creation event and the rename event both say "the directory changed",
    /// and only one of them changed what we render.
    private var lastContent: Data?
    private var seenSequences: Set<Int> = []
    private var spuriousCount = 0

    // ── The two renders (exp 12's treatment B: bold red, unmissable) ─────────

    func showNumber(_ number: String) {
        guard let button = item.button else { return }
        button.image = nil
        button.imagePosition = .noImage
        button.attributedTitle = NSAttributedString(
            string: "🔐 \(number)",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .bold),
                .foregroundColor: NSColor.systemRed,
            ]
        )
    }

    func showIcon() {
        guard let button = item.button else { return }
        button.attributedTitle = NSAttributedString(string: "")
        button.title = ""
        button.image = NSImage(systemSymbolName: "book.closed", accessibilityDescription: "BrightspaceBar")
        button.imagePosition = .imageOnly
    }

    /// Exp 12 measured the FIRST attributed title at 19 ms and every later one
    /// under 1 ms — font resolution, paid once. Left unwarmed it would land on
    /// sample 1 of every run and quietly become "the tail" in the p95 column.
    func warmFont() {
        showNumber("88")
        showIcon()
    }

    // ── The measurement ─────────────────────────────────────────────────────

    func poke(_ wakeup: Wakeup) {
        let content = FileManager.default.contents(atPath: mfaPath)
        guard content != lastContent else {
            if wakeup == .event {
                spuriousCount += 1
                recorder.record(["event": "spurious", "detectedAtEpochMs": nowEpochMillis()])
            }
            return
        }
        lastContent = content

        guard let content else {
            showIcon()
            recorder.record([
                "event": "delete",
                "detectedAtEpochMs": nowEpochMillis(),
                "spuriousSoFar": spuriousCount,
                "doomedFileWatchArmed": doomedWatcher.isArmed,
                "doomedFileWatchEvents": doomedWatcher.eventCount,
                "doomedFileWatchFlags": doomedWatcher.flagsSeen.joined(separator: ","),
            ])
            return
        }

        let parsed = try? JSONSerialization.jsonObject(with: content) as? [String: Any]
        guard let json = parsed ?? nil,
              let number = json["number"] as? String,
              let sequence = json["seq"] as? Int,
              let writtenAt = json["t0EpochMs"] as? Double
        else {
            // A torn read would land here. With temp+rename it should never
            // happen — which is the claim, so it gets recorded rather than
            // assumed.
            recorder.record(["event": "unparseable", "detectedAtEpochMs": nowEpochMillis()])
            return
        }

        showNumber(number)
        let detectedAt = nowEpochMillis()

        let alreadySeen = seenSequences.contains(sequence)
        seenSequences.insert(sequence)
        recorder.record([
            "event": alreadySeen ? "duplicate" : "update",
            "seq": sequence,
            "number": number,
            "t0EpochMs": writtenAt,
            "detectedAtEpochMs": detectedAt,
            "latencyMs": detectedAt - writtenAt,
        ])

        // Arm the file-level watch once there is a file to arm it on, so the
        // rename-over trap gets measured instead of asserted.
        if mode == "kqueue" { doomedWatcher.armIfNeeded(file: mfaPath) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let probe = Probe()

let menu = NSMenu()
menu.addItem(NSMenuItem(title: "exp 17 — \(mode)", action: nil, keyEquivalent: ""))
menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
probe.item.menu = menu

try? FileManager.default.createDirectory(atPath: cacheDirectory, withIntermediateDirectories: true)
probe.warmFont()

let kqueueWatcher = DirectoryKqueueWatcher()
let fsEventsWatcher = FSEventsWatcher()
let pollWatcher = PollWatcher()

switch mode {
case "kqueue": kqueueWatcher.start(directory: cacheDirectory)
case "fsevents": fsEventsWatcher.start(directory: cacheDirectory)
case "poll": pollWatcher.start(interval: 0.5)
default:
    FileHandle.standardError.write(Data("exp17: unknown EXP17_MODE '\(mode)'\n".utf8))
    exit(2)
}

// The idle window is the first `idleSeconds` of the process's life, and the
// driver holds its writes until this fires. Nothing else in the app is running,
// so the delta is the watcher's standing charge and nothing else.
let cpuAtStart = cpuMillisUsed()
let idleStartedAt = Date()
let idleTimer = Timer(timeInterval: idleSeconds, repeats: false) { _ in
    MainActor.assumeIsolated {
        let elapsed = Date().timeIntervalSince(idleStartedAt)
        let spent = cpuMillisUsed() - cpuAtStart
        recorder.record(["event": "idle-cpu", "cpuMs": spent, "wallSeconds": elapsed])
        print(String(format: "IDLE-DONE %@ %.1f ms CPU over %.1f s", mode, spent, elapsed))
        fflush(stdout)
    }
}
RunLoop.main.add(idleTimer, forMode: .common)

print("READY \(mode) watching \(cacheDirectory)")
fflush(stdout)

app.run()
