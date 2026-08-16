import Foundation

/// The production timer, copied near-verbatim from BrightspaceBar's
/// `CoursePipeline/RefreshScheduler.swift` (itself RepoBar's), with ONE
/// addition this experiment exists to prove out: `nextFireDate`.
///
/// The three inherited answers stay deliberate:
///
///   - `restart` **invalidates first**, always. A restart that left the old timer
///     running would double the daemon spawn rate silently.
///   - `stop` releases the handler as well as the timer, or everything the
///     handler captures lives for the life of the process.
///   - `isRunning` is **derived** from the timer, never stored.
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

    /// The experiment's addition: when the timer will next fire, or nil when no
    /// timer is running. Derived from `Timer.fireDate` — never stored — for the
    /// same reason `isRunning` is: a copy drifts after the first restart, and
    /// `fireDate` also tracks the *actual* schedule after the system applies
    /// tolerance or coalesces a fire around sleep. This is the one true source
    /// for the menu's "Refreshes in N min" line.
    public var nextFireDate: Date? {
        guard let timer, timer.isValid else { return nil }
        return timer.fireDate
    }

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
