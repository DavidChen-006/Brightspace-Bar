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

    public init(opener: any URLOpening, onCommand: @escaping @MainActor (MenuCommand) -> Void) {
        self.target = MenuActionTarget(opener: opener, onCommand: onCommand)
    }

    /// Builds a fresh menu with fresh items every call. Never reuses an
    /// `NSMenuItem` between menus: an item belongs to exactly one `NSMenu`, and
    /// reuse would silently detach it from the previously built menu.
    public func assemble(_ model: MenuModel) -> NSMenu {
        let menu = NSMenu()
        // Load-bearing. `action == nil` is what makes inert rows inert, but with
        // autoenabling on (the default) AppKit recomputes `isEnabled` at display
        // time — so section headers would light back up in the real app even
        // though headless tests, which never display the menu, stay green.
        menu.autoenablesItems = false
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

        case .sectionHeader(let text), .message(let text), .status(let text):
            // No action (can never be activated) and disabled (looks inert).
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
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
