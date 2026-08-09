import AppKit
import RepoBarCore
import WebKit

@MainActor
final class GitHubReferenceBrowserMenuItemView: NSView {
    private enum Metrics {
        static let width: CGFloat = 740
        static let headerHeight: CGFloat = 44
        static let minimumHeight: CGFloat = 680
        static let maximumHeight: CGFloat = 980
        static let initialScrollOffset = 220
        static let visibleScreenHeightMultiplier: CGFloat = 0.62
    }

    private let url: URL
    private let displayText: String
    private var webView: WKWebView?
    private var backButton: NSButton?
    private let preferredSize: NSSize
    private var hasLoaded = false

    override var intrinsicContentSize: NSSize {
        self.preferredSize
    }

    init(match: GitHubReferenceMatch) {
        self.url = match.url
        self.displayText = match.query.displayText
        self.preferredSize = Self.preferredSize()
        super.init(frame: NSRect(origin: .zero, size: self.preferredSize))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard self.window != nil else {
            self.tearDownWebView()
            return
        }

        self.loadIfNeeded()
    }

    private func installWebView(_ webView: WKWebView) {
        self.subviews.forEach { $0.removeFromSuperview() }

        let header = self.makeHeaderView()
        header.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        self.addSubview(header)
        self.addSubview(webView)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            header.topAnchor.constraint(equalTo: self.topAnchor),
            header.heightAnchor.constraint(equalToConstant: Metrics.headerHeight),
            webView.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            webView.topAnchor.constraint(equalTo: header.bottomAnchor),
            webView.bottomAnchor.constraint(equalTo: self.bottomAnchor)
        ])
    }

    private func tearDownWebView() {
        guard let webView else { return }

        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        self.subviews.forEach { $0.removeFromSuperview() }
        self.webView = nil
        self.backButton = nil
        self.hasLoaded = false
    }

    private func makeHeaderView() -> NSView {
        let container = NSVisualEffectView()
        container.material = .headerView
        container.blendingMode = .withinWindow
        container.state = .active

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let back = self.headerButton(title: "Back", symbolName: "chevron.left", action: #selector(self.goBack))
        back.isEnabled = false
        self.backButton = back

        let title = NSTextField(labelWithString: self.displayText)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        title.textColor = .secondaryLabelColor
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let copy = self.headerButton(title: "Copy", symbolName: "doc.on.doc", action: #selector(self.copyURL))
        let open = self.headerButton(title: "Open", symbolName: "safari", action: #selector(self.openInBrowser))

        stack.addArrangedSubview(back)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(spacer)
        stack.addArrangedSubview(copy)
        stack.addArrangedSubview(open)
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        return container
    }

    private func headerButton(title: String, symbolName: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
        return button
    }

    private func loadIfNeeded() {
        guard !self.hasLoaded, let webView = self.ensureWebView() else { return }

        self.hasLoaded = true
        webView.load(URLRequest(url: self.url))
    }

    func preload() {
        self.loadIfNeeded()
    }

    func unload() {
        self.tearDownWebView()
    }

    private func ensureWebView() -> WKWebView? {
        if let webView {
            return webView
        }
        guard Self.shouldCreateWebView else { return nil }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView = webView
        self.installWebView(webView)
        return webView
    }

    private static var shouldCreateWebView: Bool {
        ProcessInfo.processInfo.environment["CI"] != "true" &&
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    }

    private static func preferredSize(screen: NSScreen? = NSScreen.main) -> NSSize {
        let visibleHeight = screen?.visibleFrame.height ?? Metrics.minimumHeight
        let desiredHeight = visibleHeight * Metrics.visibleScreenHeightMultiplier
        let height = min(max(desiredHeight, Metrics.minimumHeight), Metrics.maximumHeight)
        return NSSize(width: Metrics.width, height: height.rounded(.down))
    }

    private func applyInitialScrollOffset() {
        guard let webView = self.webView else { return }

        let script = "if (window.scrollY < 80) window.scrollTo(0, \(Metrics.initialScrollOffset));"
        webView.evaluateJavaScript(script)
    }

    private func updateBackButton() {
        self.backButton?.isEnabled = self.webView?.canGoBack == true
    }

    @objc private func goBack() {
        self.webView?.goBack()
        self.updateBackButton()
    }

    @objc private func copyURL() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString((self.webView?.url ?? self.url).absoluteString, forType: .string)
    }

    @objc private func openInBrowser() {
        NSWorkspace.shared.open(self.webView?.url ?? self.url)
    }
}

extension GitHubReferenceBrowserMenuItemView: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didCommit _: WKNavigation) {
        Task { @MainActor [weak self] in
            guard let self, self.webView === webView else { return }

            self.updateBackButton()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish _: WKNavigation) {
        Task { @MainActor [weak self] in
            guard let self, self.webView === webView else { return }

            self.updateBackButton()
            self.applyInitialScrollOffset()
            try? await Task.sleep(for: .milliseconds(350))
            self.applyInitialScrollOffset()
        }
    }
}

extension GitHubReferenceBrowserMenuItemView: WKUIDelegate {}
