import Foundation
import Testing

@testable import BrightspaceBar

// ═════════════════════════════════════════════════════════════════════════════
// RefreshScheduler.nextFireDate — the experiment's one addition to the
// production timer. The inherited behaviour (invalidate-first restart, handler
// release on stop, derived isRunning) is pinned in production's
// RefreshSchedulerTests; only the new surface is pinned here.
//
// PRIORITY: the date must TRACK THE TIMER, not a stored copy — nil exactly when
// no timer runs, and re-derived after every restart. No test waits for a fire:
// `fireDate` is observable immediately, which is what keeps these tests fast
// and unflaky.
// ═════════════════════════════════════════════════════════════════════════════

@Suite("RefreshScheduler — nextFireDate")
@MainActor
struct RefreshSchedulerTests {

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
