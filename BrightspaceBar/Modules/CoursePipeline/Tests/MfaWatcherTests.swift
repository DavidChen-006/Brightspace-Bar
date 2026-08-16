import Foundation
import Testing
import CoursePipeline

// ═════════════════════════════════════════════════════════════════════════════
// MfaWatcher — the transport: one program renames a 60-byte file into place, and
// this one has to have repainted before David has finished picking up his phone.
//
// Experiment 17 measured the three candidates and picked kqueue on the cache
// DIRECTORY (2.6 ms median, no cold-start tail). These tests do not measure
// anything — the experiment did that — they pin the six traps the experiment
// found, because every one of them is a bug that LOOKS like a working feature:
//
//   1. A watch on mfa.json itself goes deaf after one atomic write (measured:
//      1 event across 19 subsequent writes). The icon updates once and then
//      never again, which demos perfectly. → "five writes, five pickups".
//   2. One atomic write is two directory events and the first is a lie — the
//      temp file's creation, at which moment mfa.json is still the old file or
//      no file. → "one atomic write repaints exactly once".
//   5. `reset.sh --cache` removes cache/ wholesale, leaving a running watcher
//      pointed at a dead inode. → "survives the cache directory being deleted".
//   6. Delete is a first-class event: the challenge resolving IS the file going
//      away. → "deleting the file brings the logo back".
//
// And the one no filesystem event can ever announce: a rung that crashed without
// deleting its file. Nothing will move on disk when those sixty seconds are up,
// so the watcher schedules its own re-check. → "the number lapses on its own".
//
// PRIORITY: a watcher that cannot go deaf. Every failure above is silent — the
// menu bar simply keeps showing what it was showing, and no error is raised
// anywhere, which is why these are tests rather than review comments.
//
// SCOPE: medium, and deliberately so. kqueue is a kernel facility; a fake would
// only test the fake. Each test gets its own temp `BSB_ROOT`, writes with the
// daemon's exact atomic technique, and waits on a condition with a hard deadline,
// so a broken implementation fails in a couple of seconds rather than hanging.
// ═════════════════════════════════════════════════════════════════════════════

/// Lets the main actor run until `condition` holds or the deadline passes.
///
/// Awaiting is the pump, and it has to be: in this test process a hand-turned
/// `RunLoop.run(until:)` does NOT drain the main dispatch queue (measured — a
/// `DispatchQueue.main.async` block never arrives), so a kqueue source targeting
/// `.main` would look broken to a test that pumped the run loop instead of
/// suspending. Suspending drives both — the queue AND run-loop timers.
///
/// Never asserts: the caller does, so a timeout reads as the real failure
/// rather than as "the pump gave up".
@MainActor
private func pumpMfa(until condition: () -> Bool, limit: TimeInterval = 2.0) async {
    let deadline = Date().addingTimeInterval(limit)
    while !condition() && Date() < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// Waits a fixed stretch with nothing to wait for — the shape a test needs when
/// its claim is that NOTHING further happens.
@MainActor
private func settle(_ seconds: TimeInterval = 0.4) async {
    await pumpMfa(until: { false }, limit: seconds)
}

@Suite("MfaWatcher — the cache directory is the thing to watch")
@MainActor
struct MfaWatcherTests {

    // Every timestamp here is `Date()`, never the fixture epoch: the TTL is
    // measured against the real clock the watcher's own timer runs on.

    // MARK: - Saying what is true right now

    @Test("start reports the state before it returns")
    func startReportsTheEmptyCase() {
        // Arrange — the app launches into an ordinary hour: no challenge, no
        // file. The icon still has to be told, or it shows whatever it was born
        // with and the wiring goes unexercised until the first login. Reported
        // synchronously, so the caller never has a frame in which the icon and
        // the disk disagree — and so every test below has a fixed starting point.
        let world = MfaWorld()
        let watcher = MfaWatcher(paths: world.paths)
        var seen: [IconState] = []

        // Act
        watcher.start { seen.append($0) }

        // Assert — no pumping: the report has already happened.
        #expect(seen == [.logo])
        watcher.stop()
    }

    @Test("start reports a challenge that is already on disk")
    func startReportsAChallengeInProgress() {
        // Arrange — a terminal-initiated full login can be mid-challenge when the
        // app starts (D8: the app is not always the spawner).
        let world = MfaWorld()
        world.writeChallenge(number: "42", mintedAt: Date())
        let watcher = MfaWatcher(paths: world.paths)
        var seen: [IconState] = []

        // Act
        watcher.start { seen.append($0) }

        // Assert
        #expect(seen == [.code("42")])
        watcher.stop()
    }

    @Test("the report arrives on the main thread")
    func callbacksAreDeliveredOnTheMainThread() async {
        // Arrange — the callback ends at `NSStatusItem.button`, and AppKit is
        // main-thread-only (exp 12's gotcha). A kqueue source is free to deliver
        // on whatever queue it was given, so this is the watcher's choice, not
        // the kernel's.
        let world = MfaWorld()
        let watcher = MfaWatcher(paths: world.paths)
        var threads: [Bool] = []

        // Act
        watcher.start { _ in threads.append(Thread.isMainThread) }
        world.writeChallenge(number: "20", mintedAt: Date())
        await pumpMfa(until: { threads.count >= 2 })
        watcher.stop()

        // Assert
        #expect(threads == [true, true])
    }

    // MARK: - Picking up what the daemon writes

    @Test("an atomic write puts the number on the icon")
    func aWriteIsPickedUp() async {
        // Arrange
        let world = MfaWorld()
        let watcher = MfaWatcher(paths: world.paths)
        var seen: [IconState] = []
        watcher.start { seen.append($0) }
        await pumpMfa(until: { !seen.isEmpty })

        // Act — temp file beside the target, then rename(2), exactly as
        // `writeJsonAtomic` does it.
        world.writeChallenge(number: "20", mintedAt: Date())
        await pumpMfa(until: { seen.count >= 2 })
        watcher.stop()

        // Assert
        #expect(seen == [.logo, .code("20")])
    }

    @Test("one atomic write repaints exactly once")
    func theTempFileEventIsNotRendered() async {
        // Arrange — trap 2. The rename is two directory events; the first fires
        // when the temp file appears and mfa.json is still the old file (or no
        // file at all). Re-reading and comparing before rendering is what makes
        // that harmless. Without it, write #1 renders a file that is not there.
        let world = MfaWorld()
        let watcher = MfaWatcher(paths: world.paths)
        var seen: [IconState] = []
        watcher.start { seen.append($0) }
        await pumpMfa(until: { !seen.isEmpty })

        // Act
        world.writeChallenge(number: "20", mintedAt: Date())
        await pumpMfa(until: { seen.count >= 2 })
        await settle()

        // Assert
        watcher.stop()
        #expect(seen == [.logo, .code("20")], "one write, one repaint")
    }

    @Test("rewriting the same challenge does not repaint")
    func identicalContentIsNotRerendered() async {
        // Arrange — same bytes, same number, same mintedAt. The directory
        // changed; what the icon should show did not.
        let world = MfaWorld()
        let json = MfaFixture.json(number: "20", mintedAt: Date())
        let watcher = MfaWatcher(paths: world.paths)
        var seen: [IconState] = []
        watcher.start { seen.append($0) }
        await pumpMfa(until: { !seen.isEmpty })
        world.writeChallenge(json: json)
        await pumpMfa(until: { seen.count >= 2 })

        // Act
        world.writeChallenge(json: json)
        await settle()
        watcher.stop()

        // Assert
        #expect(seen == [.logo, .code("20")])
    }

    @Test("five writes, five pickups")
    func theWatcherNeverGoesDeaf() async {
        // Arrange — trap 1, as a regression test. A descriptor opened on
        // mfa.json is unlinked by the first rename over it: exp 17 armed one
        // deliberately and measured a single delete event across nineteen
        // further writes. A directory descriptor survives, because the directory
        // is never replaced — only its entries are.
        let world = MfaWorld()
        let watcher = MfaWatcher(paths: world.paths)
        var seen: [IconState] = []
        watcher.start { seen.append($0) }
        await pumpMfa(until: { !seen.isEmpty })

        // Act
        for number in ["11", "22", "33", "44", "55"] {
            world.writeChallenge(number: number, mintedAt: Date())
            await pumpMfa(until: { seen.last == .code(number) })
        }
        watcher.stop()

        // Assert
        #expect(seen == [.logo, .code("11"), .code("22"), .code("33"), .code("44"), .code("55")])
    }

    @Test("deleting the file brings the logo back")
    func deleteIsAFirstClassEvent() async {
        // Arrange — trap 6. The daemon deletes mfa.json on every exit path
        // (success, expiry, error, crash path), and that deletion IS the "the
        // challenge is over" message. There is no other one.
        let world = MfaWorld()
        let watcher = MfaWatcher(paths: world.paths)
        var seen: [IconState] = []
        watcher.start { seen.append($0) }
        world.writeChallenge(number: "20", mintedAt: Date())
        await pumpMfa(until: { seen.count >= 2 })

        // Act
        world.deleteChallenge()
        await pumpMfa(until: { seen.count >= 3 })
        watcher.stop()

        // Assert
        #expect(seen == [.logo, .code("20"), .logo])
    }

    // MARK: - Surviving the directory itself

    @Test("a watcher started before cache/ exists still sees the first challenge")
    func theWatcherWaitsForItsDirectory() async {
        // Arrange — a fresh install: the app is running before the daemon has
        // ever written anything, so `cache/` does not exist yet. A watcher that
        // gave up here would need a relaunch to ever work.
        let world = MfaWorld(createsCacheDirectory: false)
        let watcher = MfaWatcher(paths: world.paths)
        var seen: [IconState] = []
        watcher.start { seen.append($0) }
        await pumpMfa(until: { !seen.isEmpty })

        // Act
        world.createCacheDirectory()
        world.writeChallenge(number: "31", mintedAt: Date())
        await pumpMfa(until: { seen.count >= 2 }, limit: 3.0)
        watcher.stop()

        // Assert
        #expect(seen == [.logo, .code("31")])
    }

    @Test("the watcher survives the cache directory being deleted")
    func theWatcherReArmsAfterAReset() async {
        // Arrange — trap 5. `reset.sh --cache` removes the directory wholesale;
        // exp 17 never tested it and said so. A watcher holding a descriptor on
        // a deleted inode is deaf for the life of the process, and the only
        // symptom is an icon that stops working days later.
        let world = MfaWorld()
        let watcher = MfaWatcher(paths: world.paths)
        var seen: [IconState] = []
        watcher.start { seen.append($0) }
        world.writeChallenge(number: "20", mintedAt: Date())
        await pumpMfa(until: { seen.count >= 2 })

        // Act
        world.deleteCacheDirectory()
        world.createCacheDirectory()
        world.writeChallenge(number: "77", mintedAt: Date())
        await pumpMfa(until: { seen.last == .code("77") }, limit: 3.0)
        watcher.stop()

        // Assert
        #expect(seen.last == .code("77"), "the watcher went deaf when cache/ was replaced")
    }

    // MARK: - The lapse nothing announces

    @Test("the number lapses on its own, with nothing moving on disk")
    func theIconRevertsWhenTheTtlPasses() async {
        // Arrange — the failure this exists for: the rung crashes between
        // scraping the number and deleting the file. No process is left to write
        // anything, so no filesystem event will ever arrive, and a purely
        // event-driven icon would show a dead number until the app was quit.
        // A short TTL so the test can be honest about waiting for real time.
        let world = MfaWorld()
        let watcher = MfaWatcher(paths: world.paths, ttl: 0.3)
        var seen: [IconState] = []
        watcher.start { seen.append($0) }
        world.writeChallenge(number: "20", mintedAt: Date())
        await pumpMfa(until: { seen.count >= 2 })

        // Act — no write, no delete, no touch. Only time passes.
        await pumpMfa(until: { seen.count >= 3 }, limit: 1.5)
        watcher.stop()

        // Assert
        #expect(seen == [.logo, .code("20"), .logo])
        #expect(world.mfaFileExists, "the file must still be there — the revert is the clock's doing, not a deletion's")
    }

    @Test("a challenge after a lapse still reaches the icon")
    func theWatcherKeepsWorkingAfterARevert() async {
        // Arrange — the revert must take down the number without taking down the
        // watcher: a login that times out is usually followed by another attempt.
        let world = MfaWorld()
        let watcher = MfaWatcher(paths: world.paths, ttl: 0.3)
        var seen: [IconState] = []
        watcher.start { seen.append($0) }
        world.writeChallenge(number: "20", mintedAt: Date())
        await pumpMfa(until: { seen.count >= 3 }, limit: 1.5)

        // Act
        world.writeChallenge(number: "88", mintedAt: Date())
        await pumpMfa(until: { seen.count >= 4 })
        watcher.stop()

        // Assert
        #expect(seen == [.logo, .code("20"), .logo, .code("88")])
    }

    @Test("a challenge already older than the TTL is never shown")
    func aStaleFileOnDiskIsIgnoredAtStart() async {
        // Arrange — the app launches and finds yesterday's crashed challenge
        // still lying in cache/. The TTL is applied at render time, so it
        // applies to this read too.
        let world = MfaWorld()
        world.writeChallenge(number: "20", mintedAt: Date().addingTimeInterval(-3600))
        let watcher = MfaWatcher(paths: world.paths)
        var seen: [IconState] = []

        // Act
        watcher.start { seen.append($0) }
        await settle()
        watcher.stop()

        // Assert
        #expect(seen == [.logo])
    }

    // MARK: - Stopping

    @Test("nothing is reported after stop")
    func stopEndsTheReports() async {
        // Arrange
        let world = MfaWorld()
        let watcher = MfaWatcher(paths: world.paths)
        var seen: [IconState] = []
        watcher.start { seen.append($0) }
        await pumpMfa(until: { !seen.isEmpty })

        // Act
        watcher.stop()
        world.writeChallenge(number: "20", mintedAt: Date())
        await settle()

        // Assert
        #expect(seen == [.logo])
    }

    @Test("stopping a watcher that never started is harmless")
    func stopBeforeStartIsSafe() {
        // Arrange — the composition root may tear down in any order.
        let world = MfaWorld()
        let watcher = MfaWatcher(paths: world.paths)

        // Act
        watcher.stop()
        watcher.stop()

        // Assert — reaching here without a crash is the claim.
        #expect(Bool(true))
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// Two claims about the watcher that no behaviour test in this package can make,
// checked the way `ArchitectureTests` and `DaemonWiringTests` check theirs: by
// reading the source. Crude, and the only mechanism available.
// ═════════════════════════════════════════════════════════════════════════════

@Suite("MfaWatcher — the claims that have to be read off the source")
struct MfaWatcherSourceTests {

    /// Four parents up from `Modules/CoursePipeline/Tests/<this file>`.
    private static var watcherSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // CoursePipeline
            .deletingLastPathComponent()   // Modules
            .deletingLastPathComponent()   // <package root>
            .appending(path: "Modules/CoursePipeline/Sources/MfaWatcher.swift")
            .standardizedFileURL
    }

    private func source() throws -> String {
        try String(contentsOf: Self.watcherSource, encoding: .utf8)
    }

    @Test("the scan finds the watcher")
    func theScanIsNotVacuous() throws {
        // Arrange / Act — a read that returned an empty string would pass every
        // negative claim below while checking nothing.
        let text = try self.source()

        // Assert
        #expect(text.contains("MfaWatcher"), "this does not look like the watcher's source")
    }

    @Test("a revert timer runs in .common run-loop mode")
    func theRevertTimerFiresWhileTheMenuIsOpen() throws {
        // Arrange — exp 12's gotcha, inherited by exp 17 as trap 7: while a menu
        // is open the run loop is in `.eventTracking`, where a `.default`-mode
        // timer does not fire. `Timer.scheduledTimer` gives you `.default`. The
        // menu being open is exactly when someone is looking at the icon, so the
        // revert would appear to hang for as long as they kept looking.
        let text = try self.source()

        // Act
        let usesATimer = text.contains("Timer(") || text.contains("Timer.scheduled")

        // Assert — a dispatch-based delay is fine (the main queue is drained in
        // the common modes); a run-loop Timer must say so.
        #expect(
            !usesATimer || text.contains(".common"),
            """
            MfaWatcher schedules a Timer without naming .common. A .default-mode \
            timer stops firing while a menu is open, so the number would stay on \
            the icon for as long as David kept the menu open. \
            RunLoop.main.add(timer, forMode: .common).
            """
        )
    }

    @Test("the watcher never asks for a headed login")
    func theWatcherCannotTripD8() throws {
        // Arrange — D8: the app never passes --allow-full-login. The watcher sits
        // closest to the login story of anything in the app, and it is a plain
        // reader of a file: it spawns nothing, and must never grow a "log in for
        // me" shortcut that a timer could reach with nobody at the machine.
        let text = try self.source()

        // Act
        let leaks = text.contains("--allow-full-login")

        // Assert
        #expect(leaks == false, "the MFA watcher must not name --allow-full-login")
    }
}
