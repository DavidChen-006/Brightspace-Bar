import Foundation
import Testing
import CoursePipeline

// ═════════════════════════════════════════════════════════════════════════════
// RefreshScheduler — the production timer the app has never had.
//
// Until now `.timer` was a `PollTrigger` that only tests ever fired: the app
// fetched at launch and when David clicked Refresh, and otherwise sat there
// going stale. This is the piece that makes the daemon worth spawning.
//
// PRIORITY: reliability of a long-lived object. A menu-bar app runs for weeks,
// so the failure modes are all cumulative — a `restart()` that forgets to
// invalidate leaves two timers ticking (then three), a `stop()` that keeps the
// tick handler alive retains the whole backend stack forever, and an `isRunning`
// stored separately from the timer drifts out of sync with reality after the
// first missed invalidate. RepoBar's `RefreshScheduler` answers all three, and
// these tests pin those answers rather than the implementation:
// restart-invalidates-first, stop-releases-the-handler, isRunning-is-derived.
//
// SCOPE: small, but wall-clock bound — `Timer` is a run-loop object and no
// injected `Clock` can make one fire. The suite keeps that honest by driving the
// main run loop by hand at 20ms intervals with a hard deadline, so a broken
// implementation fails in under two seconds instead of hanging.
// ═════════════════════════════════════════════════════════════════════════════

/// Turns the main run loop until `condition` holds or the deadline passes.
///
/// `@MainActor`, so `RunLoop.current` is the main run loop the scheduler
/// scheduled its timer on. Never asserts — the caller does, so a timeout reads
/// as the real failure rather than as "pump gave up".
@MainActor
private func pump(until condition: () -> Bool, limit: TimeInterval = 2.0) {
    let deadline = Date().addingTimeInterval(limit)
    while !condition() && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
}

/// Something for the tick handler to hold, so its release is observable.
private final class Witness {}

/// `(interval, expected tolerance)` — 10% of the interval, clamped to [1s, 30s].
/// Values worked out by hand from the rule, not read off the implementation.
///
/// File scope rather than a member of the suite: `arguments:` is evaluated
/// outside the suite's `@MainActor` isolation.
private let tolerances: [(TimeInterval, TimeInterval)] = [
    (5, 1),       // 0.5s → clamped up: never tighter than a second
    (10, 1),      // exactly the lower clamp
    (60, 6),      // the plain 10% case
    (300, 30),    // exactly the upper clamp
    (900, 30),    // 90s → clamped down: the app's real 15-minute interval
]

@Suite("RefreshScheduler — a timer that can be reconfigured without leaking")
@MainActor
struct RefreshSchedulerTests {

    // MARK: - isRunning is derived, never stored

    @Test("a fresh scheduler is not running")
    func nothingTicksBeforeItIsStarted() {
        // Arrange / Act
        let scheduler = RefreshScheduler()

        // Assert
        #expect(scheduler.isRunning == false)
    }

    @Test("restart starts it")
    func restartStartsTheTimer() {
        // Arrange
        let scheduler = RefreshScheduler()

        // Act
        scheduler.restart(interval: 60) {}

        // Assert
        #expect(scheduler.isRunning == true)
        scheduler.stop()
    }

    @Test("stop stops it")
    func stopStopsTheTimer() {
        // Arrange
        let scheduler = RefreshScheduler()
        scheduler.restart(interval: 60) {}

        // Act
        scheduler.stop()

        // Assert
        #expect(scheduler.isRunning == false)
    }

    @Test("stopping twice is harmless")
    func stopIsIdempotent() {
        // Arrange
        let scheduler = RefreshScheduler()
        scheduler.restart(interval: 60) {}

        // Act
        scheduler.stop()
        scheduler.stop()

        // Assert
        #expect(scheduler.isRunning == false)
    }

    // MARK: - Ticking

    @Test("the handler fires repeatedly while the run loop turns")
    func theTimerRepeats() {
        // Arrange
        let scheduler = RefreshScheduler()
        var ticks = 0

        // Act
        scheduler.restart(interval: 0.02) { ticks += 1 }
        pump(until: { ticks >= 3 })
        scheduler.stop()

        // Assert — repeating, not one-shot: a one-shot timer would refresh once
        // at launch and never again, which is the bug this type prevents.
        #expect(ticks >= 3, "the timer fired \(ticks) times")
    }

    @Test("no handler fires after stop")
    func stopReallyStopsTheTicks() {
        // Arrange
        let scheduler = RefreshScheduler()
        var ticks = 0
        scheduler.restart(interval: 0.02) { ticks += 1 }
        pump(until: { ticks >= 1 })

        // Act
        scheduler.stop()
        let afterStop = ticks
        pump(until: { false }, limit: 0.2)

        // Assert
        #expect(ticks == afterStop, "the timer kept firing after stop")
    }

    @Test("restart replaces the previous timer instead of adding one")
    func restartInvalidatesFirst() {
        // Arrange — the interval is user-visible policy and will be
        // reconfigurable; a restart that leaves the old timer running doubles
        // the daemon spawn rate silently, and the next restart triples it.
        let scheduler = RefreshScheduler()
        var oldTicks = 0
        var newTicks = 0
        scheduler.restart(interval: 0.02) { oldTicks += 1 }

        // Act
        scheduler.restart(interval: 0.02) { newTicks += 1 }
        pump(until: { newTicks >= 3 })
        scheduler.stop()

        // Assert
        #expect(newTicks >= 3, "the replacement timer fired \(newTicks) times")
        #expect(oldTicks == 0, "the replaced timer fired \(oldTicks) times and is still alive")
    }

    // MARK: - Not leaking the world

    @Test("stop releases the tick handler")
    func stopBreaksTheRetainCycle() {
        // Arrange — in production the handler captures the poller, which holds
        // the source, the cache and the daemon runner. A scheduler that keeps a
        // dead handler keeps all of it, for the life of the process.
        let scheduler = RefreshScheduler()
        weak var released: Witness?
        do {
            let witness = Witness()
            released = witness
            scheduler.restart(interval: 60) { _ = witness }
        }
        #expect(released != nil, "the scheduler is expected to hold its handler while running")

        // Act
        scheduler.stop()

        // Assert
        #expect(released == nil, "stop must nil the handler, not just invalidate the timer")
    }

    // MARK: - Tolerance

    @Test(
        "tolerance is a tenth of the interval, clamped to one second and thirty",
        arguments: tolerances
    )
    func toleranceIsClamped(_ interval: TimeInterval, _ expected: TimeInterval) {
        // Arrange / Act — letting the system coalesce a background refresh is
        // free battery; letting it slip half an hour is a stale menu.
        let tolerance = RefreshScheduler.tolerance(for: interval)

        // Assert
        #expect(tolerance == expected)
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// nextFireDate — experiment 18's one addition to this timer: the date the menu's
// "Refreshes in N min" line counts down to.
//
// PRIORITY: the date must TRACK THE TIMER, not a stored copy — nil exactly when
// no timer runs, and re-derived after every restart. No test here waits for a
// fire: `fireDate` is observable immediately, which keeps this suite fast and
// unflaky.
// ═════════════════════════════════════════════════════════════════════════════

@Suite("RefreshScheduler — nextFireDate")
@MainActor
struct RefreshSchedulerNextFireDateTests {

    @Test("before any restart there is no next fire date")
    func nilBeforeRestart() {
        #expect(RefreshScheduler().nextFireDate == nil)
    }

    @Test("after restart the next fire is one interval away, within tolerance")
    func nextFireIsOneIntervalAway() throws {
        // Arrange
        let scheduler = RefreshScheduler()
        let interval: TimeInterval = 15 * 60
        let scheduledAt = Date()

        // Act
        scheduler.restart(interval: interval) {}
        defer { scheduler.stop() }

        // Assert — the window is [interval, interval + tolerance] from the
        // moment of scheduling, plus slack for the lines between the two Date()
        // reads. `Timer.fireDate` is the scheduled target, so this cannot flake.
        let next = try #require(scheduler.nextFireDate)
        let remaining = next.timeIntervalSince(scheduledAt)
        #expect(remaining >= interval - 1)
        #expect(remaining <= interval + RefreshScheduler.tolerance(for: interval) + 1)
    }

    @Test("stop clears the next fire date")
    func stopClearsNextFireDate() {
        // Arrange
        let scheduler = RefreshScheduler()
        scheduler.restart(interval: 600) {}

        // Act
        scheduler.stop()

        // Assert — an invalidated timer must not leak a stale date to the menu.
        #expect(scheduler.nextFireDate == nil)
    }

    @Test("a restart replaces the previous schedule's date")
    func restartRederivesTheDate() throws {
        // Arrange — long schedule first, then a short one. If the date were
        // stored rather than derived, the first schedule's date would survive.
        let scheduler = RefreshScheduler()
        scheduler.restart(interval: 3600) {}

        // Act
        scheduler.restart(interval: 60) {}
        defer { scheduler.stop() }

        // Assert
        let next = try #require(scheduler.nextFireDate)
        #expect(next.timeIntervalSinceNow < 120, "old 1-hour schedule leaked through a restart")
    }
}
