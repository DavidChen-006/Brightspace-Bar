import AppKit
import Foundation

/// Opening a URL is a side effect. Inject it so clicks are assertable in tests.
///
/// The requirement is synchronous and non-isolated on purpose: an NSMenuItem action
/// fires synchronously on the main thread, and an `async` seam here would force the
/// menu code to detach a task just to hand a URL to the browser.
public protocol URLOpening: Sendable {
    func open(_ url: URL)
}

/// The `.system` target: hands the URL to the user's default browser.
///
/// The click lands wherever the user's real browser is — bookmarks, extensions,
/// passwords intact — but on whatever Brightspace session that browser happens
/// to hold, which may be none (a fresh login wall). This is the classic
/// behaviour, kept behind the `BrowserTarget` switch.
public struct WorkspaceURLOpener: URLOpening {
    public init() {}

    public func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

/// The `.chromium` target: opens the URL in the daemon's already-signed-in
/// persistent Chromium profile, so it lands authenticated with no browser login.
///
/// It spawns `node <openCLI> <url>`; `browser-open.mjs` wraps the link in
/// Purdue's SAML initiate-login and opens the profile the login ladder keeps
/// warm. The spawn is fire-and-forget: the child owns the browser window, and a
/// failure to launch (the profile momentarily in use) costs this click, never
/// the app.
public struct ChromiumURLOpener: URLOpening {
    private let openCLI: String

    /// - Parameter openCLI: the `browser-open.mjs` entry point. Defaults to the
    ///   sibling `session-capture` package, overridable with `BSB_OPEN_CLI`
    ///   exactly as the daemon path is — so a moved checkout or a test points
    ///   elsewhere without a rebuild.
    public init(openCLI: String = ChromiumURLOpener.defaultCLI) {
        self.openCLI = openCLI
    }

    public static var defaultCLI: String {
        ProcessInfo.processInfo.environment["BSB_OPEN_CLI"]
            ?? NSHomeDirectory() + "/Developer/BrightspaceBar/session-capture/src/browser-open.mjs"
    }

    public func open(_ url: URL) {
        let process = Process()
        // Through `/usr/bin/env` so `node` is found on PATH, matching how the
        // app spawns the refresh daemon.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", self.openCLI, url.absoluteString]
        // Launched from Finder/`open`, the app inherits launchd's bare PATH,
        // which has no Homebrew — and `/usr/bin/env node` then finds nothing
        // and the click dies silently. Same augmentation as `DaemonRunner`.
        var environment = ProcessInfo.processInfo.environment
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for extra in ["/opt/homebrew/bin", "/usr/local/bin"]
        where !path.split(separator: ":").contains(Substring(extra)) {
            environment["PATH"] = (environment["PATH"] ?? path) + ":" + extra
        }
        process.environment = environment
        try? process.run()
    }
}
