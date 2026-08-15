import Foundation

/// The production timer: the thing that makes `PollTrigger.timer` more than a
/// value only tests ever pass.
///
/// A menu-bar app runs for weeks, so every failure mode of a long-lived timer is
/// cumulative, and each of the three answers here is deliberate (RepoBar's
/// `RefreshScheduler`, near-verbatim):
///
///   - `restart` **invalidates first**, always. A restart that left the old timer
///     running would double the daemon spawn rate silently, and the next one
///     would triple it.
///   - `stop` releases the handler as well as the timer. In production the
///     handler captures the poller, which holds the source, the cache and the
///     daemon runner; keeping a dead handler keeps all of it for the life of the
///     process.
///   - `isRunning` is **derived** from the timer, never stored. A separate bool
///     drifts out of sync with reality after the first missed invalidate, and
///     nothing ever notices.
///
/// `Timer` is a run-loop object, so this type is `@MainActor` and its tick runs
/// on the main actor — which is also where the caller wants to be when it
/// repaints a menu.
@MainActor
public final class RefreshScheduler {

    private var timer: Timer?
    private var tick: (@MainActor () -> Void)?

    public init() {}

    /// Whether a valid timer is scheduled right now.
    public var isRunning: Bool { self.timer?.isValid == true }

    /// Schedules `onTick` every `interval` seconds, replacing any previous
    /// schedule. Does not fire immediately: the launch fetch is the caller's
    /// business and happens on its own trigger.
    public func restart(interval: TimeInterval, onTick: @escaping @MainActor () -> Void) {
        self.stop()
        self.tick = onTick
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            // Timers scheduled from the main run loop fire on it.
            MainActor.assumeIsolated { self?.tick?() }
        }
        timer.tolerance = Self.tolerance(for: interval)
        self.timer = timer
    }

    public func stop() {
        self.timer?.invalidate()
        self.timer = nil
        self.tick = nil
    }

    /// A tenth of the interval, clamped to [1s, 30s]. Letting the system coalesce
    /// a background refresh is free battery; letting it slip half an hour is a
    /// stale menu.
    public static func tolerance(for interval: TimeInterval) -> TimeInterval {
        min(max(interval * 0.1, 1), 30)
    }
}
