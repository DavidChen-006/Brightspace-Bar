import Foundation
import Testing
import CoursePipeline

// ═════════════════════════════════════════════════════════════════════════════
// DataWatcher — the prompt-reload transport: the one-command start flow runs the
// login/fetch AFTER launching the app, so a freshly published `data.json` must
// reach the menu now, not at the next 30-minute poll.
//
// The watching mechanism is MfaWatcher's (kqueue on the cache DIRECTORY, per
// experiment 17), so these tests pin the same traps — a watcher that cannot go
// deaf, atomic-rename semantics, the directory being replaced wholesale — plus
// the two claims that are this watcher's own:
//
//   - Only `data.json` matters. The daemon writes `mfa.json` and `status.json`
//     into the same directory, and every one of those events reaches the same
//     directory source; a reload per MFA challenge would be a bug that demos
//     as a feature. → "a write to another cache file is not reported".
//   - Rapid writes coalesce. The reaction is a model rebuild, not an icon
//     repaint. → "five rapid writes debounce to fewer callbacks than writes".
//
// SCOPE: medium, deliberately — kqueue is a kernel facility, a fake would only
// test the fake. Each test gets its own temp `BSB_ROOT` (MfaWorld: it owns the
// daemon's exact atomic-write technique) and waits on a condition with a hard
// deadline. Short debounces so the honest waiting stays under a second.
// ═════════════════════════════════════════════════════════════════════════════

/// Lets the main actor run until `condition` holds or the deadline passes.
/// Awaiting is the pump — see MfaWatcherTests for why a hand-turned run loop
/// would not drain the main queue here.
@MainActor
private func pumpData(until condition: () -> Bool, limit: TimeInterval = 2.0) async {
    let deadline = Date().addingTimeInterval(limit)
    while !condition() && Date() < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// Waits a fixed stretch with nothing to wait for — the shape a test needs when
/// its claim is that NOTHING further happens.
@MainActor
private func settle(_ seconds: TimeInterval = 0.4) async {
    await pumpData(until: { false }, limit: seconds)
}

/// One atomic publish of a file in `cache/`, `writeJsonAtomic` transcribed:
/// a dot-prefixed temp file beside the target, then `rename(2)` over it.
@MainActor
private func publish(_ world: MfaWorld, file: String, contents: String) {
    let target = world.cacheDirectory.appending(path: file)
    let temp = world.cacheDirectory.appending(path: ".\(file).\(getpid()).\(UUID().uuidString).tmp")
    try? Data(contents.utf8).write(to: temp)
    _ = rename(temp.path, target.path)
}

@Suite("DataWatcher — a new data.json is reported promptly, and nothing else is")
@MainActor
struct DataWatcherTests {

    // MARK: - The change that must be reported

    @Test("an atomic write of data.json fires the callback")
    func aWriteIsPickedUp() async {
        // Arrange — the flow this exists for: app already up, daemon publishing.
        let world = MfaWorld()
        let watcher = DataWatcher(paths: world.paths, debounce: 0.05)
        var fired = 0
        watcher.start { fired += 1 }

        // Act — temp file beside the target, then rename(2), exactly as
        // `writeJsonAtomic` does it.
        publish(world, file: "data.json", contents: #"{"courses":[]}"#)
        await pumpData(until: { fired >= 1 })
        watcher.stop()

        // Assert
        #expect(fired >= 1, "a published data.json never reached the callback")
    }

    @Test("start does not report the file already on disk")
    func startIsSilentAboutTheBaseline() async {
        // Arrange — the launch path reads data.json itself; a callback for the
        // state at start would double the launch reload for nothing.
        let world = MfaWorld()
        publish(world, file: "data.json", contents: #"{"courses":[]}"#)
        let watcher = DataWatcher(paths: world.paths, debounce: 0.05)
        var fired = 0

        // Act
        watcher.start { fired += 1 }
        await settle()
        watcher.stop()

        // Assert
        #expect(fired == 0)
    }

    @Test("the callback arrives on the main thread")
    func callbacksAreDeliveredOnTheMainThread() async {
        // Arrange — the reaction ends at AppKit, which is main-thread-only.
        let world = MfaWorld()
        let watcher = DataWatcher(paths: world.paths, debounce: 0.05)
        var threads: [Bool] = []
        watcher.start { threads.append(Thread.isMainThread) }

        // Act
        publish(world, file: "data.json", contents: #"{"courses":[]}"#)
        await pumpData(until: { !threads.isEmpty })
        watcher.stop()

        // Assert
        #expect(threads == [true])
    }

    @Test("five writes, five pickups — the watcher never goes deaf")
    func theWatcherNeverGoesDeaf() async {
        // Arrange — trap 1: a descriptor on the FILE is unlinked by the first
        // rename over it. Spaced past the debounce so each write is its own
        // window and every one must arrive.
        let world = MfaWorld()
        let watcher = DataWatcher(paths: world.paths, debounce: 0.05)
        var fired = 0
        watcher.start { fired += 1 }

        // Act
        for round in 1...5 {
            publish(world, file: "data.json", contents: #"{"round":\#(round)}"#)
            await pumpData(until: { fired >= round })
        }
        watcher.stop()

        // Assert
        #expect(fired == 5)
    }

    // MARK: - The changes that must NOT be reported

    @Test("a write to another cache file is not reported")
    func otherFilesInCacheAreIgnored() async {
        // Arrange — the daemon writes mfa.json and status.json into the same
        // directory, and the directory source hears all of it. A reload per MFA
        // challenge is exactly the bug this test exists to keep out.
        let world = MfaWorld()
        publish(world, file: "data.json", contents: #"{"courses":[]}"#)
        let watcher = DataWatcher(paths: world.paths, debounce: 0.05)
        var fired = 0
        watcher.start { fired += 1 }

        // Act
        publish(world, file: "mfa.json", contents: #"{"number":"42"}"#)
        publish(world, file: "status.json", contents: #"{"state":"running"}"#)
        await settle()
        watcher.stop()

        // Assert
        #expect(fired == 0, "an unrelated cache file triggered a reload")
    }

    @Test("rapid successive writes debounce to fewer callbacks than writes")
    func rapidWritesCoalesce() async {
        // Arrange — the reaction is a model rebuild; a burst of directory events
        // from one daemon run must settle into one look, not five rebuilds.
        let world = MfaWorld()
        let watcher = DataWatcher(paths: world.paths, debounce: 0.15)
        var fired = 0
        watcher.start { fired += 1 }

        // Act — all five inside one debounce window, no pumping in between.
        for round in 1...5 {
            publish(world, file: "data.json", contents: #"{"burst":\#(round)}"#)
        }
        await pumpData(until: { fired >= 1 })
        await settle()
        watcher.stop()

        // Assert — at least one (the fresh data must land) and fewer than one
        // per write (the debounce must be doing something).
        #expect(fired >= 1, "the burst's final data.json never reached the callback")
        #expect(fired < 5, "five writes in one window produced five reloads — no debounce")
    }

    // MARK: - Surviving the directory itself

    @Test("a watcher started before cache/ exists still sees the first publish")
    func theWatcherWaitsForItsDirectory() async {
        // Arrange — the one-command start flow verbatim: app up first, daemon
        // creates cache/ and publishes afterwards.
        let world = MfaWorld(createsCacheDirectory: false)
        let watcher = DataWatcher(paths: world.paths, debounce: 0.05)
        var fired = 0
        watcher.start { fired += 1 }

        // Act
        world.createCacheDirectory()
        publish(world, file: "data.json", contents: #"{"courses":[]}"#)
        await pumpData(until: { fired >= 1 }, limit: 3.0)
        watcher.stop()

        // Assert
        #expect(fired >= 1, "the watcher never noticed the directory being born")
    }

    @Test("the watcher survives the cache directory being deleted")
    func theWatcherReArmsAfterAReset() async {
        // Arrange — trap 5: `reset.sh --cache` removes the directory wholesale,
        // and a descriptor on the dead inode is deaf for the life of the process.
        let world = MfaWorld()
        publish(world, file: "data.json", contents: #"{"before":true}"#)
        let watcher = DataWatcher(paths: world.paths, debounce: 0.05)
        var fired = 0
        watcher.start { fired += 1 }

        // Act
        world.deleteCacheDirectory()
        world.createCacheDirectory()
        publish(world, file: "data.json", contents: #"{"after":true}"#)
        await pumpData(until: { fired >= 1 }, limit: 3.0)
        watcher.stop()

        // Assert
        #expect(fired >= 1, "the watcher went deaf when cache/ was replaced")
    }

    // MARK: - Stopping

    @Test("nothing is reported after stop")
    func stopEndsTheReports() async {
        // Arrange
        let world = MfaWorld()
        let watcher = DataWatcher(paths: world.paths, debounce: 0.05)
        var fired = 0
        watcher.start { fired += 1 }

        // Act
        watcher.stop()
        publish(world, file: "data.json", contents: #"{"courses":[]}"#)
        await settle()

        // Assert
        #expect(fired == 0)
    }

    @Test("stopping a watcher that never started is harmless")
    func stopBeforeStartIsSafe() {
        // Arrange — the composition root may tear down in any order.
        let world = MfaWorld()
        let watcher = DataWatcher(paths: world.paths)

        // Act
        watcher.stop()
        watcher.stop()

        // Assert — reaching here without a crash is the claim.
        #expect(Bool(true))
    }
}
