import Foundation

/// The functional core of polling: every "should we touch the network?" decision,
/// as a pure function. No clock, no state, no I/O — `now` is a parameter, so the
/// whole decision is testable with plain values.
///
/// The decisions this module hides from its callers:
/// - **`.manual` always fetches.** A user who clicks Refresh gets a fetch, even one
///   second after the last one. Every other trigger shares one staleness rule.
/// - **`.launch` is not special-cased.** `lastFetch == nil` is infinitely stale, so
///   a first launch fetches for free — and relaunching thirty seconds after
///   quitting does not burn a fetch. Fresh is fresh regardless of why we ask.
/// - **The boundary is inclusive** (`age >= interval`): a repeating timer firing
///   exactly on its period is the common case, and an exclusive comparison would
///   make a punctual timer decline. It also degrades `interval: 0` to "always
///   fetch", a sane reading.
/// - **A future `lastFetch` counts as stale.** Clock skew, an NTP correction, or
///   waking from sleep can leave a persisted timestamp ahead of `now`, making the
///   age negative. A naive `age >= interval` then declines *forever* — no amount
///   of waiting recovers it. A future timestamp is untrustworthy data; treating it
///   as stale is self-healing and costs one request.
public struct PollPolicy: Sendable {
    private let interval: TimeInterval

    public init(interval: TimeInterval) {
        self.interval = interval
    }

    /// The whole decision, pure. No clock, no state, no I/O.
    public func shouldFetch(trigger: PollTrigger, lastFetch: Date?, now: Date) -> Bool {
        if trigger == .manual { return true }
        guard let lastFetch else { return true }
        let age = now.timeIntervalSince(lastFetch)
        return age < 0 || age >= self.interval
    }
}
