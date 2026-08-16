import Foundation

/// Pure formatting core: `StatusStamp` + `now` → display string. No AppKit, no
/// clock — `now` is a parameter, so every rule here is pinned by plain-value
/// tests in `StatusTextTests`.
///
/// This function used to live inside `MenuTranslation` (backend side), which is
/// what baked the string into the model at build time. It lives in the contract
/// module now because the GUI is the one that knows when the menu is actually
/// being looked at — it calls this with a fresh `now` on every `menuWillOpen`.
public enum StatusText {

    public static func title(for stamp: StatusStamp, now: Date) -> String {
        switch stamp {
        case .nextRefresh(let next):
            return self.nextRefresh(next, now: now)
        }
    }

    /// Countdown line. Minutes are *rounded* (RepoBar's rule), so the text is
    /// never more than 30 seconds of a lie in either direction; sub-minute and
    /// past deadlines fold into "Refreshes soon" — a deadline in the past is a
    /// timer about to fire (or a Mac waking from sleep), never an error to show.
    static func nextRefresh(_ next: Date, now: Date) -> String {
        let remaining = next.timeIntervalSince(now)
        if remaining < 60 { return "Refreshes soon" }
        let m = max(1, Int((remaining / 60).rounded()))
        return "Refreshes in \(m) minute\(m == 1 ? "" : "s")"
    }
}
