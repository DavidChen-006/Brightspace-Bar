import AppKit
import Foundation
import Synchronization
import Testing

import BrightspaceBar
import CourseMenu

// ─────────────────────────────────────────────────────────────────────────────
// Test harness for the menu suite. Two pieces: a recording `URLOpening`, and the
// one correct way to simulate a click in a headless test process.
// ─────────────────────────────────────────────────────────────────────────────

/// Records every URL the menu tries to open, in order.
///
/// Isolation note, since `URLOpening` is `Sendable`: the protocol requirement
/// `func open(_ url: URL)` is **synchronous and non-isolated**, so an `actor` cannot
/// satisfy it — an actor's methods would have to be `async`. The correct answer is a
/// `final class` whose only stored property is a `Mutex`, which makes the class
/// genuinely, *checked* `Sendable`. Deliberately not `@unchecked Sendable`: that
/// would ask the compiler to take lock discipline on faith, and `Mutex` means we
/// don't have to.
final class FakeURLOpener: URLOpening, Sendable {
    private let storage = Mutex<[URL]>([])

    /// Every URL opened, oldest first.
    var opened: [URL] { self.storage.withLock { $0 } }

    /// Convenience for the common "exactly one URL, and it was this one" assertion.
    var openedCount: Int { self.storage.withLock { $0.count } }

    func open(_ url: URL) {
        self.storage.withLock { $0.append(url) }
    }
}

/// Records `MenuCommand`s dispatched through `MenuAssembler`'s `onCommand` callback.
///
/// Same isolation reasoning as `FakeURLOpener`, except `onCommand` is `@MainActor`, so
/// this only ever mutates on the main actor. It is still expressed with a `Mutex` so
/// the type is `Sendable` without qualification and can be captured by the escaping
/// closure without ceremony.
final class CommandRecorder: Sendable {
    private let storage = Mutex<[MenuCommand]>([])

    var received: [MenuCommand] { self.storage.withLock { $0 } }
    var count: Int { self.storage.withLock { $0.count } }

    func record(_ command: MenuCommand) {
        self.storage.withLock { $0.append(command) }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Clicking, headless
// ─────────────────────────────────────────────────────────────────────────────

/// Simulates the user choosing a menu item.
///
/// **Do not use `NSMenu.performActionForItem(at:)` here.** Measured in this test
/// process: `NSApp` is nil, and `performActionForItem` then *silently does nothing* —
/// no error, no dispatch, no crash. Any test built on it would pass vacuously, which
/// is the worst possible failure mode for a click test. (Touching
/// `NSApplication.shared` does make it work, but instantiating a global application
/// object as a side effect of a unit test is not a trade worth making.)
///
/// A direct Objective-C message send to the item's target needs no `NSApplication`
/// and exercises the same wiring the real menu uses: the target, the action, and the
/// item passed as `sender` — which is how the implementation recovers *which* row was
/// chosen.
///
/// Fails the test if the item is not actionable, so a "click" on an inert row can
/// never be mistaken for a click that did nothing.
@MainActor
func click(_ item: NSMenuItem, _ sourceLocation: SourceLocation = #_sourceLocation) throws {
    let action = try #require(
        item.action,
        "menu item '\(item.title)' has no action, so it cannot be clicked",
        sourceLocation: sourceLocation
    )
    let target = try #require(
        item.target as? NSObject,
        "menu item '\(item.title)' has no NSObject target, so its action cannot be dispatched",
        sourceLocation: sourceLocation
    )
    _ = target.perform(action, with: item)
}

/// Finds a row by the exact title the user would read.
///
/// Deliberately title-based rather than index- or `representedObject`-based: it is what
/// a person actually does (read the label, click it), it keeps these tests free of any
/// assumption about how the implementation stores row identity, and it means an
/// index-mapping bug cannot be hidden by a test that looks up rows the same broken way
/// the code does.
@MainActor
func item(titled title: String, in menu: NSMenu, _ sourceLocation: SourceLocation = #_sourceLocation) throws -> NSMenuItem {
    try #require(
        menu.items.first { $0.title == title },
        "no menu item titled '\(title)'. Titles present: \(menu.items.map(\.title))",
        sourceLocation: sourceLocation
    )
}
