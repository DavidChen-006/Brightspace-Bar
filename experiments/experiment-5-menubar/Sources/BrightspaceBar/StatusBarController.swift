import AppKit
import CourseMenu

/// The imperative shell. Owns the `NSStatusItem`, pulls models from the data
/// source, and hands them to `MenuAssembler`. Deliberately not imported by the
/// unit tests — a status item needs a real UI session, so this layer is covered
/// by the launch smoke test instead.
@MainActor
public final class StatusBarController {
    private static let iconSymbolName = "book.closed"

    private let dataSource: any MenuDataSource
    private let opener: any URLOpening
    private let statusItem: NSStatusItem
    private var shownModel: MenuModel?

    /// `lazy` so the `onCommand` closure can capture `self`, which an initializer
    /// stored property cannot.
    private lazy var assembler = MenuAssembler(opener: self.opener) { [weak self] command in
        self?.handle(command)
    }

    public init(dataSource: any MenuDataSource, opener: any URLOpening) {
        self.dataSource = dataSource
        self.opener = opener
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem.button?.image = NSImage(
            systemSymbolName: Self.iconSymbolName,
            accessibilityDescription: "Brightspace courses"
        )
        // Placeholder immediately — the icon must never carry an empty menu —
        // then whatever the data source already knows, without blocking launch.
        self.show(.placeholder)
        Task { self.show(await self.dataSource.currentMenu()) }
    }

    /// Re-pull from the data source and repaint.
    ///
    /// Exists because the composition root drives the launch fetch (it owns the
    /// poller, and `.launch` must not go through `refresh()`, which is `.manual`).
    /// After that fetch lands, the menu has to be told.
    public func reload() async {
        self.show(await self.dataSource.currentMenu())
    }

    private func show(_ model: MenuModel) {
        // `MenuModel` is `Equatable` precisely so an unchanged menu is not rebuilt.
        guard model != self.shownModel else { return }
        self.shownModel = model
        self.statusItem.menu = self.assembler.assemble(model)
    }

    private func handle(_ command: MenuCommand) {
        switch command {
        case .refresh:
            // `refresh()` may do I/O, so it runs off the click. It never throws:
            // the data source keeps last good data and says so in a status row.
            Task { self.show(await self.dataSource.refresh()) }
        case .quit:
            NSApp.terminate(nil)
        }
    }
}
