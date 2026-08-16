import Foundation

/// Which browser a course/assignment click opens in — the switch that plugs one
/// of two `URLOpening` implementations into the menu's click seam.
///
///   .system   → `WorkspaceURLOpener`   the user's default browser
///   .chromium → `ChromiumURLOpener`    the daemon's signed-in profile
///
/// The two are interchangeable behind `URLOpening`; this enum is the single
/// place that names them and the single place a control variable is read, so the
/// composition root asks for a target and never mentions a concrete opener.
public enum BrowserTarget: String, Sendable, CaseIterable {
    /// The user's default browser. Their real browsing environment, but on
    /// whatever Brightspace session it holds — possibly a login wall.
    case system
    /// The daemon's already-signed-in Chromium. Lands authenticated with no
    /// login, at the cost of a bare browser window.
    case chromium

    /// The shipped default. `.chromium`, because a click that never shows a
    /// login is the whole point of the all-Chromium design; `.system` is the
    /// opt-out.
    public static let productionDefault: BrowserTarget = .chromium

    /// The target the app runs with, resolved from `BSB_BROWSER_TARGET`
    /// ("system" | "chromium") and falling back to `productionDefault` when the
    /// variable is unset or unrecognized — an unknown value must not silently
    /// disable clicking, so it degrades to the shipped behaviour.
    public static func resolve(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> BrowserTarget {
        guard
            let raw = environment["BSB_BROWSER_TARGET"],
            let target = BrowserTarget(rawValue: raw)
        else {
            return productionDefault
        }
        return target
    }

    /// The opener this target names. Exhaustive with no `default`, so adding a
    /// third target is a compile error here rather than a click that silently
    /// falls through to the wrong browser.
    public func makeOpener() -> any URLOpening {
        switch self {
        case .system: WorkspaceURLOpener()
        case .chromium: ChromiumURLOpener()
        }
    }
}
