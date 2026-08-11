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
        self.menu(model.rows)
    }

    /// The one row-list → `NSMenu` builder, shared by the top level and by every
    /// submenu. Deliberately general rather than two specialised builders: a
    /// second copy is where `autoenablesItems` gets forgotten on one level and
    /// where the two levels drift apart in how they construct items.
    ///
    /// `leadingWith` carries the structural rows a submenu needs before its model
    /// rows, and is genuinely per-call — the top level has none.
    private func menu(_ rows: [MenuRow], leadingWith prefix: [NSMenuItem] = []) -> NSMenu {
        let menu = NSMenu()
        // Hover unity's delivery mechanism. A view-backed item is never told it
        // is highlighted — AppKit only tells the menu's delegate — so without
        // this every course row draws forever unhighlighted. Retained by the
        // menu itself because `NSMenu.delegate` is WEAK: a delegate merely
        // assigned here would deallocate before the menu was ever shown.
        let highlighter = MenuHighlightDelegate()
        menu.delegate = highlighter
        objc_setAssociatedObject(
            menu, &MenuHighlightDelegate.associationKey, highlighter, .OBJC_ASSOCIATION_RETAIN
        )
        // Load-bearing, and needed on submenus too. `action == nil` is what makes
        // inert rows inert, but with autoenabling on (the default) AppKit
        // recomputes `isEnabled` at display time — so section headers and the
        // "No assignments" line would light back up in the real app even though
        // headless tests, which never display the menu, stay green.
        menu.autoenablesItems = false
        for item in prefix {
            menu.addItem(item)
        }
        for row in rows {
            for item in self.items(for: row) {
                menu.addItem(item)
            }
        }
        return menu
    }

    /// Still a list, though only separators and single rows come out of it
    /// today: keeping the fan-out here is what keeps the loop above free of row
    /// kinds.
    private func items(for row: MenuRow) -> [NSMenuItem] {
        switch row {
        case .course(let course):
            let title = RowTitle.course(course)
            let item = self.linkItem(title: title, url: course.url)
            // Attached only when the model actually has submenu rows. An empty
            // NSMenu would render as a hover arrow onto a blank box *and* make
            // this item non-actionable — silently killing the plain click that
            // every course row shipping today depends on.
            item.submenu = self.submenu(for: course)
            // The course becomes ONE component: title and cells in a single
            // view, because AppKit highlights an item and not a pair of them.
            // Kept on EVERY course, graphed or not — a course rendered natively
            // among components would not merely look different, it would sit at
            // a different height. The item keeps its `title` even though the
            // view draws the text: it is how the rest of the suite, and
            // accessibility, find this row.
            item.view = MenuItemHostingView(
                title: title, cells: course.graph, showsChevron: item.submenu != nil
            )
            return [item]

        case .assignment(let assignment):
            return [self.linkItem(title: RowTitle.assignment(assignment), url: assignment.url)]

        case .command(let command):
            let item = NSMenuItem(
                title: RowTitle.command(command),
                action: #selector(MenuActionTarget.performCommand(_:)),
                keyEquivalent: ""
            )
            item.target = self.target
            item.representedObject = command
            return [item]

        case .sectionHeader(let text), .message(let text), .status(let text):
            // No action (can never be activated) and disabled (looks inert).
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return [item]

        case .separator:
            return [NSMenuItem.separator()]

        case .hairline:
            // Inert in every sense the design depends on: no title to read, no
            // action, and explicitly disabled so hover skips the row rather than
            // lighting an empty band between two courses. The line itself is the
            // view's; an ordinary disabled item would draw nothing at all.
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.view = HairlineRowView()
            return [item]
        }
    }

    /// A course's assignment submenu, or nil when the model gave it no rows.
    ///
    /// The course-home row is the one row this layer adds on its own, and it is
    /// not a policy choice: AppKit refuses to deliver a click to an item that owns
    /// a submenu, so `CourseRow.url` becomes unreachable the moment assignments
    /// appear. Re-exposing it here is what stops this feature from silently
    /// deleting the ability to open a course. Everything *else* in the submenu —
    /// order, the empty-state message, any staleness note — comes from the model.
    private func submenu(for course: CourseRow) -> NSMenu? {
        guard !course.submenu.isEmpty else { return nil }
        return self.menu(
            course.submenu,
            leadingWith: [
                self.linkItem(title: RowTitle.courseHome, url: course.url),
                .separator(),
            ]
        )
    }

    /// One builder for every row that opens a URL — course, assignment, and the
    /// course-home escape hatch. They differ only in their title and destination,
    /// so they share a single construction path and a single action.
    private func linkItem(title: String, url: URL) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(MenuActionTarget.openLink(_:)),
            keyEquivalent: ""
        )
        item.target = self.target
        // Click identity travels *with the item*, never resolved from an index.
        // Non-course rows interleave among courses, so NSMenu item index ≠ course
        // index — and a submenu adds a second level of indexing on top. Resolving
        // a click positionally is where every off-by-one lives, and at two levels
        // the wrong answer is a plausible-looking page belonging to another course.
        item.representedObject = url
        return item
    }
}

/// Pure formatting core: row content in, display string out. No AppKit.
///
/// Pinned display format:
///
///     course, subtitle present     │ "CS 17600 — Data Engineering"
///     course, subtitle nil         │ "Purdue Civics Knowledge Test"
///     assignment, subtitle present │ "Report on your PURC Experience. — Due Mar 1"
///     assignment, subtitle nil     │ "Untitled"
///     .refresh                     │ "Refresh"
///     .quit                        │ "Quit"
///
/// Separator is SPACE + EM DASH (U+2014) + SPACE throughout.
///
/// Note the deliberate INVERSION between the two row kinds. A course leads with
/// its code, because students identify a class by its code and the short codes
/// form a rough left column. An assignment leads with its NAME, because the name
/// is the identity you scan for and the date is metadata — and because leading
/// with the date would leave a ragged column, given that every assignment in the
/// currently reachable courses has no due date at all.
enum RowTitle {
    static let subtitleSeparator = " — "

    /// The submenu's escape hatch, restoring the click AppKit takes away from a
    /// course that owns a submenu.
    static let courseHome = "Open Course Home"

    static func course(_ row: CourseRow) -> String {
        guard let subtitle = row.subtitle else { return row.title }
        return subtitle + Self.subtitleSeparator + row.title
    }

    /// `subtitle` is rendered VERBATIM. The view must never format `dueDate`
    /// itself: date formatting is policy — locale, time zone, "tomorrow" versus a
    /// date — and policy belongs in the pure backend layer that already decided
    /// what this row should say.
    static func assignment(_ row: AssignmentRow) -> String {
        guard let subtitle = row.subtitle else { return row.title }
        return row.title + Self.subtitleSeparator + subtitle
    }

    static func command(_ command: MenuCommand) -> String {
        switch command {
        case .refresh: "Refresh"
        case .quit: "Quit"
        }
    }
}

/// Turns AppKit's one highlight signal into the flag every component draws from.
///
/// It sets the flag on EVERY component, not just the hovered one: `willHighlight`
/// fires once per change, so a delegate that only lights the new row leaves every
/// row the pointer passed over still lit. `item` is nil when the pointer leaves
/// the rows entirely, and is a native row (a command) when it lands on one —
/// both mean "no component is highlighted", which is what `item === row` says
/// without a special case.
@MainActor
private final class MenuHighlightDelegate: NSObject, NSMenuDelegate {
    /// Address-as-key for the association that keeps this object alive.
    nonisolated(unsafe) static var associationKey = 0

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for row in menu.items {
            guard let component = row.view as? MenuItemHostingView else { continue }
            component.isHighlightedForMenu = (row === item)
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

    /// Serves every URL-opening row — course, assignment, course-home — because it
    /// only ever needed the destination the item carries, never the row's kind.
    @objc func openLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        self.opener.open(url)
    }

    @objc func performCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? MenuCommand else { return }
        self.onCommand(command)
    }
}
