import Foundation

public struct RepositoryStats: Codable, Equatable, Sendable {
    public var openIssues: Int
    public var openPulls: Int
    public var stars: Int
    public var forks: Int
    public var pushedAt: Date?

    public init(
        openIssues: Int,
        openPulls: Int,
        stars: Int = 0,
        forks: Int = 0,
        pushedAt: Date? = nil
    ) {
        self.openIssues = openIssues
        self.openPulls = openPulls
        self.stars = stars
        self.forks = forks
        self.pushedAt = pushedAt
    }
}
