import Foundation
import Testing
import CoursePipeline

// ═════════════════════════════════════════════════════════════════════════════
// DaemonRunner — spawning `node src/refresh.mjs` and living to tell the tale.
//
// PRIORITY: reliability of the spawn. This is the one place the app leaves its
// own process, and every failure mode here is silent from the menu's point of
// view: a deadlocked child hangs the refresh forever, a lost exit code turns
// "needs login" into "everything is fine", a leaked `--allow-full-login` pops a
// browser window on a cron-safe timer tick.
//
// Two claims are load-bearing and come from prior art rather than imagination:
//
//   - **stdout/stderr must be redirected to FILES, not `Pipe`s.** A `Pipe` plus
//     `waitUntilExit()` deadlocks the moment the child fills the ~64KB buffer,
//     and a Node CLI logging its ladder progress will. RepoBar's
//     `GitProcessRunner` was bitten by exactly this. `aChattyChildDoesNotDeadlock`
//     is the regression test — it floods 256KB down each stream.
//   - **The timeout must actually kill the child**, not just stop waiting. An
//     abandoned headed-login browser would outlive the app. `.hang` leaves a
//     marker file after it sleeps, so its absence proves the SIGTERM landed.
//
// SCOPE: medium — real subprocesses, a real temp directory. There is no smaller
// scope that can make a claim about spawning. The child is a `/bin/sh` stub, so
// no node, no network and no credentials are involved.
// ═════════════════════════════════════════════════════════════════════════════

@Suite("DaemonRunner — the spawn, the exit code, and the timeout")
struct DaemonRunnerTests {

    // MARK: - Exit codes are the whole contract with the daemon

    @Test("exit 0 means a fresh cache was written")
    func exitZeroIsRanOk() async {
        // Arrange
        let world = DaemonWorld()
        world.plan(.ok)
        world.stage(data: DaemonJSON.twoCourses, status: DaemonJSON.freshStatus)

        // Act
        let outcome = await world.runner().run()

        // Assert — and the cache really landed under the root we handed over.
        #expect(outcome == .ranOk)
        #expect(FileManager.default.fileExists(atPath: world.paths.dataFile.path))
        #expect(FileManager.default.fileExists(atPath: world.paths.statusFile.path))
    }

    @Test("exit 2 means the ladder ran out and a human is needed")
    func exitTwoIsNeedsLogin() async {
        // Arrange
        let world = DaemonWorld()
        world.plan(.needsLogin)
        world.stage(status: DaemonJSON.status("needs-login"))

        // Act
        let outcome = await world.runner().run()

        // Assert
        #expect(outcome == .needsLogin)
    }

    @Test("exit 1 fails, carrying the daemon's own stderr as the detail")
    func exitOneCarriesTheReason() async {
        // Arrange — the daemon's last line is the only diagnosis the app gets.
        let world = DaemonWorld()
        world.plan(.error, argument: "the token mint answered HTTP 503")

        // Act
        let outcome = await world.runner().run()

        // Assert
        guard case .failed(let detail) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(detail.contains("the token mint answered HTTP 503"))
    }

    @Test("an unrecognized exit code is a failure, never a success")
    func unknownExitCodesAreNotSuccess() async {
        // Arrange — the stub answers an unknown mode with exit 1 and a complaint;
        // the point is that nothing but 0 may read as `.ranOk`.
        let world = DaemonWorld()
        world.write(plan: "some-future-mode")

        // Act
        let outcome = await world.runner().run()

        // Assert
        #expect(outcome != .ranOk)
        #expect(outcome != .needsLogin)
    }

    // MARK: - The two traps

    @Test("a chatty child does not deadlock the runner")
    func aChattyChildDoesNotDeadlock() async {
        // Arrange — 256KB down stdout AND stderr, four times the pipe buffer a
        // `Pipe` + `waitUntilExit()` implementation blocks on.
        let world = DaemonWorld()
        world.plan(.chatty)
        world.stage(data: DaemonJSON.twoCourses, status: DaemonJSON.freshStatus)

        // Act — a generous timeout, so a `.timedOut` here means genuinely stuck
        // rather than merely slow.
        let outcome = await world.runner(timeout: 20).run()

        // Assert
        #expect(outcome == .ranOk)
    }

    @Test("a child that outruns the timeout is reported as timed out")
    func theTimeoutIsTyped() async {
        // Arrange
        let world = DaemonWorld()
        world.plan(.hang, argument: "1.5")

        // Act
        let outcome = await world.runner(timeout: 0.25).run()

        // Assert
        #expect(outcome == .timedOut)
    }

    @Test("a timed-out child is killed, not abandoned")
    func theTimeoutTerminatesTheChild() async throws {
        // Arrange — `.hang` writes `finished.txt` only if it is allowed to run to
        // completion. An abandoned child (say, a headed login browser) would
        // outlive the refresh that started it.
        let world = DaemonWorld()
        world.plan(.hang, argument: "1.0")

        // Act
        _ = await world.runner(timeout: 0.25).run()
        // Real time, deliberately: the claim is about another process, which no
        // injected clock can hurry. Waited past the sleep the child asked for.
        try await Task.sleep(for: .milliseconds(1_400))

        // Assert
        #expect(world.childFinished == false, "the child survived its own timeout")
    }

    // MARK: - What the child is handed

    @Test("BSB_ROOT reaches the child")
    func theRootIsPassedThrough() async {
        // Arrange — the root is how the app and the daemon agree on one cache.
        let world = DaemonWorld()
        world.plan(.ok)

        // Act
        _ = await world.runner().run()

        // Assert
        #expect(world.recordedRoot == world.root.path)
    }

    @Test("the child receives exactly the arguments it was given")
    func argumentsArePassedVerbatim() async {
        // Arrange
        let world = DaemonWorld()
        world.plan(.ok)

        // Act
        _ = await world.runner(arguments: ["--quiet", "--attempts=2"]).run()

        // Assert
        #expect(world.recordedArguments == ["--quiet", "--attempts=2"])
    }

    @Test("the runner never adds --allow-full-login of its own accord")
    func theRunnerNeverInventsThePermissionFlag() async {
        // Arrange — D8: every spawn the app makes is cron-safe. The flag is the
        // difference between a silent re-mint and a browser window appearing
        // while nobody is at the machine.
        let world = DaemonWorld()
        world.plan(.ok)

        // Act
        _ = await world.runner().run()

        // Assert
        #expect(world.recordedArguments.isEmpty)
        #expect(!world.recordedArguments.contains("--allow-full-login"))
    }

    @Test("an executable that does not exist fails to spawn instead of crashing")
    func aMissingExecutableIsTyped() async {
        // Arrange — node missing from PATH, or a moved checkout.
        let world = DaemonWorld()

        // Act
        let outcome = await world.runner(executable: DaemonWorld.missingExecutable).run()

        // Assert
        guard case .spawnFailed(let detail) = outcome else {
            Issue.record("expected .spawnFailed, got \(outcome)")
            return
        }
        #expect(!detail.isEmpty, "a spawn failure must say something diagnosable")
    }
}
