import AppKit
import SwiftUI

@MainActor
struct MenuItemViewFactory {
    func makeItem(
        for content: some View,
        enabled: Bool,
        highlightable: Bool = false,
        showsSubmenuIndicator: Bool? = nil,
        submenu: NSMenu? = nil,
        target: AnyObject? = nil,
        action: Selector? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = enabled

        if highlightable {
            let highlightState = MenuItemHighlightState()
            let indicator = showsSubmenuIndicator ?? (submenu != nil)
            item.view = MenuItemHostingView(
                rootView: Self.highlightableRoot(
                    content,
                    highlightState: highlightState,
                    showsSubmenuIndicator: indicator
                ),
                highlightState: highlightState
            )
        } else {
            item.view = MenuItemHostingView(rootView: Self.plainRoot(content))
        }

        item.submenu = submenu
        if let target, let action {
            item.target = target
            item.action = action
        }
        return item
    }

    func updateItem(
        _ item: NSMenuItem,
        with content: some View,
        highlightable: Bool,
        showsSubmenuIndicator: Bool? = nil
    ) {
        guard let hostingView = item.view as? MenuItemHostingView else {
            item.view = self.makeItem(
                for: content,
                enabled: item.isEnabled,
                highlightable: highlightable,
                showsSubmenuIndicator: showsSubmenuIndicator
            ).view
            return
        }

        let indicator = showsSubmenuIndicator ?? (item.submenu != nil)
        if highlightable {
            hostingView.updateHighlightableRootView(
                AnyView(content),
                showsSubmenuIndicator: indicator
            )
        } else {
            hostingView.updateRootView(Self.plainRoot(content))
        }
    }

    private static func plainRoot(_ content: some View) -> AnyView {
        AnyView(
            content
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        )
    }

    private static func highlightableRoot(
        _ content: some View,
        highlightState: MenuItemHighlightState,
        showsSubmenuIndicator: Bool
    ) -> AnyView {
        AnyView(
            MenuItemContainerView(
                highlightState: highlightState,
                showsSubmenuIndicator: showsSubmenuIndicator
            ) {
                content
            }
        )
    }
}
