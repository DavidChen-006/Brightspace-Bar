import AppKit
import SwiftUI

struct IssueNavigatorSplitView<Sidebar: View, Detail: View>: NSViewRepresentable {
    let sidebarMinWidth: CGFloat
    let sidebarIdealWidth: CGFloat
    let sidebarMaxWidth: CGFloat
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let detail: () -> Detail

    func makeCoordinator() -> Coordinator {
        Coordinator(
            sidebarMinWidth: self.sidebarMinWidth,
            sidebarIdealWidth: self.sidebarIdealWidth,
            sidebarMaxWidth: self.sidebarMaxWidth
        )
    }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = IssueNavigatorNSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = context.coordinator

        let sidebarHost = NSHostingView(rootView: self.sidebar())
        sidebarHost.translatesAutoresizingMaskIntoConstraints = false
        sidebarHost.wantsLayer = false
        let detailHost = NSHostingView(rootView: self.detail())
        detailHost.translatesAutoresizingMaskIntoConstraints = false
        detailHost.wantsLayer = false

        context.coordinator.sidebarHost = sidebarHost
        context.coordinator.detailHost = detailHost

        splitView.addArrangedSubview(sidebarHost)
        splitView.addArrangedSubview(detailHost)
        sidebarHost.widthAnchor.constraint(greaterThanOrEqualToConstant: self.sidebarMinWidth).isActive = true
        sidebarHost.widthAnchor.constraint(lessThanOrEqualToConstant: self.sidebarMaxWidth).isActive = true
        detailHost.widthAnchor.constraint(greaterThanOrEqualToConstant: 560).isActive = true
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(240), forSubviewAt: 0)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(230), forSubviewAt: 1)

        DispatchQueue.main.async {
            splitView.setPosition(self.sidebarIdealWidth, ofDividerAt: 0)
        }

        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        context.coordinator.sidebarMinWidth = self.sidebarMinWidth
        context.coordinator.sidebarIdealWidth = self.sidebarIdealWidth
        context.coordinator.sidebarMaxWidth = self.sidebarMaxWidth
        context.coordinator.sidebarHost?.rootView = self.sidebar()
        context.coordinator.detailHost?.rootView = self.detail()

        if splitView.frame.width > 0, splitView.subviews.first?.frame.width == 0 {
            splitView.setPosition(self.sidebarIdealWidth, ofDividerAt: 0)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        var sidebarMinWidth: CGFloat
        var sidebarIdealWidth: CGFloat
        var sidebarMaxWidth: CGFloat
        var sidebarHost: NSHostingView<Sidebar>?
        var detailHost: NSHostingView<Detail>?

        init(sidebarMinWidth: CGFloat, sidebarIdealWidth: CGFloat, sidebarMaxWidth: CGFloat) {
            self.sidebarMinWidth = sidebarMinWidth
            self.sidebarIdealWidth = sidebarIdealWidth
            self.sidebarMaxWidth = sidebarMaxWidth
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainSplitPosition proposedPosition: CGFloat,
            ofSubviewAt _: Int
        ) -> CGFloat {
            let maximum = min(self.sidebarMaxWidth, splitView.bounds.width - 560 - splitView.dividerThickness)
            return min(max(proposedPosition, self.sidebarMinWidth), maximum)
        }
    }
}

final class IssueNavigatorNSSplitView: NSSplitView {
    override var dividerThickness: CGFloat {
        1
    }

    override func drawDivider(in rect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.45).setFill()
        rect.fill()
    }
}

struct IssueNavigatorSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: self.$text, onSubmit: self.onSubmit)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = self.placeholder
        field.controlSize = .regular
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular), weight: .regular)
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = true
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = self.$text
        context.coordinator.onSubmit = self.onSubmit
        if field.stringValue != self.text {
            field.stringValue = self.text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }

            self.text.wrappedValue = field.stringValue
        }

        func control(
            _: NSControl,
            textView _: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }

            self.onSubmit()
            return true
        }
    }
}

struct IssueNavigatorScopePopUp: NSViewRepresentable {
    @Binding var selection: IssueNavigatorScope
    let scopes: [IssueNavigatorScope]

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: self.$selection, scopes: self.scopes)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.controlSize = .regular
        popup.target = context.coordinator
        popup.action = #selector(Coordinator.select(_:))
        context.coordinator.configure(popup)
        return popup
    }

    func updateNSView(_ popup: NSPopUpButton, context: Context) {
        context.coordinator.selection = self.$selection
        context.coordinator.scopes = self.scopes
        context.coordinator.configure(popup)
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<IssueNavigatorScope>
        var scopes: [IssueNavigatorScope]

        init(selection: Binding<IssueNavigatorScope>, scopes: [IssueNavigatorScope]) {
            self.selection = selection
            self.scopes = scopes
        }

        func configure(_ popup: NSPopUpButton) {
            let representedIDs = popup.itemArray.compactMap { $0.representedObject as? String }
            let scopeIDs = self.scopes.map(\.id)
            if representedIDs != scopeIDs {
                popup.removeAllItems()
                for scope in self.scopes {
                    popup.addItem(withTitle: scope.title)
                    popup.lastItem?.representedObject = scope.id
                }
            }
            if let index = self.scopes.firstIndex(of: self.selection.wrappedValue) {
                popup.selectItem(at: index)
            }
        }

        @objc func select(_ popup: NSPopUpButton) {
            let index = popup.indexOfSelectedItem
            guard self.scopes.indices.contains(index) else { return }

            self.selection.wrappedValue = self.scopes[index]
        }
    }
}

struct IssueNavigatorKindSegmentedControl: NSViewRepresentable {
    @Binding var selection: IssueNavigatorKindFilter

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: self.$selection)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: IssueNavigatorKindFilter.allCases.map(\.title),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.select(_:))
        )
        control.controlSize = .regular
        control.segmentStyle = .rounded
        context.coordinator.configure(control)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = self.$selection
        context.coordinator.configure(control)
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<IssueNavigatorKindFilter>

        init(selection: Binding<IssueNavigatorKindFilter>) {
            self.selection = selection
        }

        func configure(_ control: NSSegmentedControl) {
            let cases = IssueNavigatorKindFilter.allCases
            control.segmentCount = cases.count
            for (index, filter) in cases.enumerated() {
                control.setLabel(filter.title, forSegment: index)
                control.setWidth(0, forSegment: index)
            }
            control.selectedSegment = cases.firstIndex(of: self.selection.wrappedValue) ?? 0
        }

        @objc func select(_ control: NSSegmentedControl) {
            let index = control.selectedSegment
            let cases = IssueNavigatorKindFilter.allCases
            guard cases.indices.contains(index) else { return }

            self.selection.wrappedValue = cases[index]
        }
    }
}

struct IssueNavigatorBrowserPreview: NSViewRepresentable {
    let url: URL
    let store: IssueNavigatorBrowserStore

    func makeNSView(context _: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: NSView, context _: Context) {
        let webView = self.store.webView(for: self.url)
        guard webView.superview !== container else {
            webView.frame = container.bounds
            return
        }

        container.subviews.forEach { $0.removeFromSuperview() }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    static func dismantleNSView(_ container: NSView, coordinator _: ()) {
        for subview in container.subviews {
            subview.removeFromSuperview()
        }
    }
}
