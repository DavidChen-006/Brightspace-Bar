import Foundation

public struct RepoContentItem: Identifiable, Hashable, Sendable, Decodable {
    public let name: String
    public let path: String
    public let type: RepoContentType
    public let size: Int?
    public let url: URL
    public let htmlURL: URL?
    public let downloadURL: URL?

    public var id: String {
        self.path
    }

    public init(
        name: String,
        path: String,
        type: RepoContentType,
        size: Int?,
        url: URL,
        htmlURL: URL?,
        downloadURL: URL?
    ) {
        self.name = name
        self.path = path
        self.type = type
        self.size = size
        self.url = url
        self.htmlURL = htmlURL
        self.downloadURL = downloadURL
    }

    public var isDirectory: Bool {
        self.type == .dir
    }

    enum CodingKeys: String, CodingKey {
        case name
        case path
        case type
        case size
        case url
        case htmlURL = "html_url"
        case downloadURL = "download_url"
    }
}

public enum RepoContentType: String, Sendable, Decodable {
    case file
    case dir
    case symlink
    case submodule
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RepoContentType(rawValue: raw) ?? .unknown
    }
}
