import Foundation

public struct ActivityMetadata: Codable, Equatable, Sendable {
    public let actor: String
    public let action: String?
    public let target: String?
    public let url: URL?

    public init(actor: String, action: String?, target: String?, url: URL?) {
        self.actor = actor
        self.action = action
        self.target = target
        self.url = url
    }

    public var label: String {
        switch (self.action, self.target) {
        case let (action?, target?) where target.hasPrefix("→"):
            "\(action) \(target)"
        case let (action?, target?) where target.hasPrefix("#"):
            "\(action) \(target)"
        case let (action?, target?):
            "\(action): \(target)"
        case let (action?, nil):
            action
        case let (nil, target?):
            target
        default:
            ""
        }
    }

    public var deepLink: URL? {
        self.url
    }
}
