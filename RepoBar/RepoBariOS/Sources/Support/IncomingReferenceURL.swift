import Foundation

enum IncomingReferenceURL {
    static let scheme = "repobar"
    static let resolveHost = "resolve"

    static func text(from url: URL) -> String? {
        guard url.scheme?.localizedCaseInsensitiveCompare(scheme) == .orderedSame,
              url.host?.localizedCaseInsensitiveCompare(resolveHost) == .orderedSame,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return nil
        }

        let value = components.queryItems?.first { item in
            item.name == "text" || item.name == "url" || item.name == "reference"
        }?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return value?.isEmpty == false ? value : nil
    }

    static func makeURL(text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = resolveHost
        components.queryItems = [URLQueryItem(name: "text", value: trimmed)]
        return components.url
    }
}
