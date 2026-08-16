import AppKit
import CourseMenu

// ─────────────────────────────────────────────────────────────────────────────
// MenuModel → NSMenu. The translation layer between the value-typed contract and
// AppKit. Owns no status item and no app lifecycle — `NSStatusItem` needs a real
// UI session, and keeping it out of here is what lets the unit suite run
// headless. The status item lives in `StatusBarController`.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
public struct MenuAssembler {
    /// Retained here because `NSMenuItem.target` is a *weak* reference: if nothing
    /// else held this object, every item's target would silently become nil and
    /// clicks would do nothing. One target serves every item; the clicked item's
    /// `representedObject` says which row was chosen.
    private let target: MenuActionTarget
    /// Injectable clock for the status titles; production is `Date.init`. A
    /// closure, not a value — the whole point is that it is re-read at open time.
    private let now: () -> Date

    public init(
        opener: any URLOpening,
        now: @escaping () -> Date = Date.init,
        onCommand: @escaping @MainActor (MenuCommand) -> Void
    ) {
        self.target = MenuActionTarget(opener: opener, onCommand: onCommand)
        self.now = now
    }

    /// Builds a fresh menu with fresh items every call. Never reuses an
    /// `NSMenuItem` between menus: an item belongs to exactly one `NSMenu`, and
    /// reuse would silently detach it from the previously built menu.
    public func assemble(_ model: MenuModel) -> NSMenu {
        // `AssembledMenu`, not `NSMenu`: `NSMenu.delegate` is WEAK, so the menu
        // must strongly anchor its own freshness delegate or the wiring silently
        // dissolves with whatever else happened to retain it. (Measured: the
        // first cut parked the delegate on the assembler and every freshness
        // test found `menu.delegate == nil`.)
        let menu = AssembledMenu()
        // Load-bearing. `action == nil` is what makes inert rows inert, but with
        // autoenabling on (the default) AppKit recomputes `isEnabled` at display
        // time — so section headers would light back up in the real app even
        // though headless tests, which never display the menu, stay green.
        menu.autoenablesItems = false
        // The freshness pass: re-titles the status rows in `menuWillOpen`, which
        // AppKit calls synchronously BEFORE the menu is drawn — so the times are
        // correct at the moment of opening with no race and no ticking timer.
        let freshness = MenuFreshnessDelegate(now: self.now)
        menu.freshness = freshness
        menu.delegate = freshness
        for row in model.rows {
            menu.addItem(self.item(for: row))
        }
        return menu
    }

    private func item(for row: MenuRow) -> NSMenuItem {
        switch row {
        case .course(let course):
            let item = NSMenuItem(
                title: RowTitle.course(course),
                action: #selector(MenuActionTarget.openCourse(_:)),
                keyEquivalent: ""
            )
            item.target = self.target
            // Click identity travels *with the item*. Non-course rows interleave
            // among courses, so NSMenu item index ≠ course index — resolving the
            // click from an index is where every off-by-one lives.
            item.representedObject = course.url
            return item

        case .command(let command):
            let item = NSMenuItem(
                title: RowTitle.command(command),
                action: #selector(MenuActionTarget.performCommand(_:)),
                keyEquivalent: ""
            )
            item.target = self.target
            item.representedObject = command
            return item

        case .sectionHeader(let text), .message(let text):
            // No action (can never be activated) and disabled (looks inert).
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item

        case .status(let stamp):
            // Inert like the above, but the *stamp* travels with the item — that
            // is what lets `MenuFreshnessDelegate` recompute the title from the
            // dates on every open. The title set here is only the first paint.
            let item = NSMenuItem(
                title: StatusText.title(for: stamp, now: self.now()),
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            item.representedObject = StatusStampBox(stamp)
            return item

        case .separator:
            return NSMenuItem.separator()
        }
    }
}

/// Pure formatting core: row content in, display string out. No AppKit.
///
/// Pinned display format:
///
///     subtitle present │ "CS 17600 — Data Engineering"    (SPACE EM-DASH SPACE)
///     subtitle nil     │ "Purdue Civics Knowledge Test"   (bare title, no dash)
///     .refresh         │ "Refresh"
///     .quit            │ "Quit"
///
/// Code first because students identify a class by its code, so leading with it
/// makes the dropdown scannable and the short codes form a rough left column.
enum RowTitle {
    static let subtitleSeparator = " — "

    static func course(_ row: CourseRow) -> String {
        guard let subtitle = row.subtitle else { return row.title }
        return subtitle + Self.subtitleSeparator + row.title
    }

    static func command(_ command: MenuCommand) -> String {
        switch command {
        case .refresh: "Refresh"
        case .quit: "Quit"
        }
    }
}

/// An `NSMenu` that keeps its own freshness delegate alive. `NSMenu.delegate`
/// is a weak reference; without this strong anchor the delegate's lifetime
/// would silently depend on whoever happens to retain the assembler.
@MainActor
final class AssembledMenu: NSMenu {
    var freshness: MenuFreshnessDelegate?
}

/// Reference wrapper so a value-typed `StatusStamp` can ride in
/// `representedObject` (which is `Any?` but bridges values through opaque
/// boxes that `as?` cannot recover reliably across module boundaries).
final class StatusStampBox: NSObject {
    let stamp: StatusStamp
    init(_ stamp: StatusStamp) { self.stamp = stamp }
}

/// The experiment's third change: the mechanism that keeps time rows honest.
///
/// `menuWillOpen(_:)` is delivered synchronously, before AppKit draws the menu,
/// so titles set here are what the user sees — no async hop, no race against
/// display, no per-second timer ticking a menu nobody is looking at. This is
/// RepoBar's `menuWillOpen` rebuild, narrowed: only the stamped rows are
/// touched, because only they depend on `now` — everything else was already
/// correct, and `MenuModel`'s Equatable skip-rebuild stays effective.
@MainActor
final class MenuFreshnessDelegate: NSObject, NSMenuDelegate {
    private let now: () -> Date

    init(now: @escaping () -> Date) {
        self.now = now
    }

    func menuWillOpen(_ menu: NSMenu) {
        let now = self.now()
        for item in menu.items {
            guard let box = item.representedObject as? StatusStampBox else { continue }
            item.title = StatusText.title(for: box.stamp, now: now)
        }
    }
}

/// The one Objective-C object in the module: target/action needs an `NSObject`
/// with `@objc` selectors reachable via `perform(_:with:)`. It recovers the
/// clicked row from the sender's `representedObject` and dispatches the injected
/// side effect — nothing here decides anything.
@MainActor
private final class MenuActionTarget: NSObject {
    private let opener: any URLOpening
    private let onCommand: @MainActor (MenuCommand) -> Void

    init(opener: any URLOpening, onCommand: @escaping @MainActor (MenuCommand) -> Void) {
        self.opener = opener
        self.onCommand = onCommand
    }

    @objc func openCourse(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        self.opener.open(url)
    }

    @objc func performCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? MenuCommand else { return }
        self.onCommand(command)
    }
}
