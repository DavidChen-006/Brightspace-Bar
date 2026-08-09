import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .systemBackground
        self.loadSharedText { [weak self] text in
            self?.finish(with: text)
        }
    }

    private func loadSharedText(completion: @escaping @MainActor @Sendable (String?) -> Void) {
        let providers = (self.extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        guard providers.isEmpty == false else {
            completion(nil)
            return
        }

        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                let value = (item as? URL)?.absoluteString ?? item as? String
                Self.complete(on: completion, with: value)
            }
            return
        }

        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                Self.complete(on: completion, with: item as? String)
            }
            return
        }

        completion(nil)
    }

    nonisolated private static func complete(
        on completion: @escaping @MainActor @Sendable (String?) -> Void,
        with value: String?
    ) {
        let normalized = Self.normalize(value)
        Task { @MainActor in
            completion(normalized)
        }
    }

    nonisolated private static func normalize(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func finish(with text: String?) {
        guard let text, let url = Self.resolveURL(for: text) else {
            self.extensionContext?.completeRequest(returningItems: nil)
            return
        }

        self.extensionContext?.open(url) { [weak self] _ in
            Task { @MainActor in
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        }
    }

    private static func resolveURL(for text: String) -> URL? {
        var components = URLComponents()
        components.scheme = "repobar"
        components.host = "resolve"
        components.queryItems = [URLQueryItem(name: "text", value: text)]
        return components.url
    }
}
