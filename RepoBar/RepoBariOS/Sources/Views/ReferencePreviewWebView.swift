import SwiftUI
import WebKit

struct ReferencePreviewWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context _: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsBackForwardNavigationGestures = true
        return webView
    }

    func updateUIView(_ webView: WKWebView, context _: Context) {
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }
}
