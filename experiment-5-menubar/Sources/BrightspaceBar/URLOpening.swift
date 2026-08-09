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

/// The real thing: hands the URL to the user's default browser.
public struct WorkspaceURLOpener: URLOpening {
    public init() {}

    public func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
