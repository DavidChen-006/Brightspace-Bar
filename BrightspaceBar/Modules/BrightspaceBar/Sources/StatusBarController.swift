import AppKit
import CourseMenu

/// The imperative shell. Owns the `NSStatusItem`, pulls models from the data
/// source, and hands them to `MenuAssembler`. Deliberately not imported by the
/// unit tests — a status item needs a real UI session, so this layer is covered
/// by the launch smoke test instead.
@MainActor
public final class StatusBarController {
    /// Fallback only — the shipped mark is `Resources/MotionP.pdf`. Kept so a
    /// build with a missing resource still puts *something* in the menu bar.
    private static let iconSymbolName = "book.closed"

    private let dataSource: any MenuDataSource
    private let opener: any URLOpening
    /// Persists a draft the student typed into an add-form, or nil for a build
    /// without the feature (the stub path). Injected as a contract-typed
    /// closure because this file may not import a storage module; the
    /// composition root owns what "persist" means.
    private let onAddItem: (@MainActor (AddItemDraft) -> Void)?
    /// Deletes one of the student's own items by id (Intent 4), or nil for a
    /// build without the feature. Injected like `onAddItem` and for the same
    /// reason: this file may not import a storage module.
    private let onDeleteItem: (@MainActor (UUID) -> Void)?
    private let statusItem: NSStatusItem
    private var shownModel: MenuModel?

    /// `lazy` so the `onCommand` closure can capture `self`, which an initializer
    /// stored property cannot.
    private lazy var assembler = MenuAssembler(
        opener: self.opener,
        onAddItem: { [weak self] draft in
            guard let self else { return }
            self.onAddItem?(draft)
            // Re-pull immediately: the data source reads manual items fresh on
            // every snapshot, so the next menu open shows the new item's square.
            Task { await self.reload() }
        },
        onDeleteItem: { [weak self] id in
            guard let self else { return }
            self.onDeleteItem?(id)
            // Same re-pull as an add: the next open shows the square lightened.
            Task { await self.reload() }
        }
    ) { [weak self] command in
        self?.handle(command)
    }

    public init(
        dataSource: any MenuDataSource,
        opener: any URLOpening,
        onAddItem: (@MainActor (AddItemDraft) -> Void)? = nil,
        onDeleteItem: (@MainActor (UUID) -> Void)? = nil
    ) {
        self.dataSource = dataSource
        self.opener = opener
        self.onAddItem = onAddItem
        self.onDeleteItem = onDeleteItem
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem.button?.image = Self.logoImage
        Self.warmUp()
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

    // MARK: - The MFA number

    /// Shows a verification number in place of the icon, or restores the icon
    /// when `code` is nil — which is how the caller says the challenge is over.
    ///
    /// A `String` and not a state enum: `IconState` lives in `CoursePipeline`
    /// and no view file may import a backend module, so the composition root is
    /// the one place that knows both words for this.
    ///
    /// Experiment 12 measured this exact path at 1–4 ms: the button is repainted
    /// in place and the status item is never torn down, which is what keeps it in
    /// its slot in the menu bar across the flip.
    public func show(code: String?) {
        guard let button = self.statusItem.button else { return }
        guard let code else {
            // Both title properties, or a previously set `attributedTitle`
            // survives as a ghost beside the restored icon (exp 12's gotcha).
            button.attributedTitle = NSAttributedString(string: "")
            button.title = ""
            button.image = Self.logoImage
            button.imagePosition = .imageOnly
            return
        }
        button.image = nil
        button.imagePosition = .noImage
        button.attributedTitle = Self.badgeTitle(code)
    }

    /// The number as the menu bar draws it: exp 12's treatment B, the one it
    /// recommended for this flow. Red in a menu bar is rare enough to mean
    /// *something is waiting on you*, and a number-matching prompt is genuinely
    /// blocking and times out, so this is the one moment where being loud is
    /// correct. The digits are monospaced so the item does not resize between
    /// codes like 11 and 88 — `.variableLength` means every status item to its
    /// left slides when it does.
    public static func badgeTitle(_ code: String) -> NSAttributedString {
        NSAttributedString(
            string: "🔐 \(code)",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .bold),
                .foregroundColor: NSColor.systemRed,
            ]
        )
    }

    /// Pays the font-resolution cost while nobody is watching. Exp 12 measured
    /// the FIRST attributed title at 19 ms and every later one under a
    /// millisecond; unwarmed, that 19 ms lands on the one paint that matters and
    /// makes a 2.6 ms transport look slow.
    private static func warmUp() {
        _ = Self.badgeTitle("88").size()
    }

    /// The Motion P, or the SF Symbol if the bundled asset ever goes missing.
    ///
    /// `isTemplate` is the whole trick and the reason this is a flat black
    /// silhouette rather than the gold-and-black logo: a template image is a
    /// stencil, so AppKit tints it black in Light Mode, white in Dark, and white
    /// again while the menu is open. A colored image would be drawn literally and
    /// go invisible against a dark menu bar the moment the menu is clicked.
    ///
    /// Vector PDF and not PNG so it stays sharp on every scale factor without
    /// shipping an @1x/@2x pair — the asset carries its own 23.8 × 12.6pt size,
    /// which is why nothing here resizes it. That size is deliberate: the mark is
    /// nearly twice as wide as it is tall, so matching the menu bar's usual ~16pt
    /// glyph height would make it dominate its neighbours by area.
    ///
    /// `Bundle.main` and NOT `Bundle.module`: SPM's generated accessor looks for
    /// its bundle beside `Contents/`, which is not a place a signed .app may keep
    /// one, and falls back to a hardcoded absolute .build path that exists only on
    /// the machine that compiled it. Scripts/run.sh copies the PDF into
    /// Contents/Resources instead, where Bundle.main finds it anywhere.
    ///
    /// `lazy`, not computed: this is read on every icon restore in
    /// `show(code:)`, and decoding the PDF each time is waste.
    private static let logoImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MotionP", withExtension: "pdf"),
              let image = NSImage(contentsOf: url)
        else {
            return NSImage(
                systemSymbolName: StatusBarController.iconSymbolName,
                accessibilityDescription: StatusBarController.iconDescription
            )
        }
        image.isTemplate = true
        image.accessibilityDescription = StatusBarController.iconDescription
        return image
    }()

    private static let iconDescription = "Brightspace courses"

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
