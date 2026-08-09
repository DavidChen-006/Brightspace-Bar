import Foundation

public struct Repository: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let owner: String
    public let description: String?
    public let language: String?
    public let topics: [String]
    public let isFork: Bool
    public let isArchived: Bool
    public let viewerCanRead: Bool
    public let sortOrder: Int?
    public var error: String?
    public var rateLimitedUntil: Date?
    public var ciStatus: CIStatus
    public var ciRunCount: Int?
    public var stats: RepositoryStats
    public var latestRelease: Release?
    public var latestActivity: ActivityEvent?
    public var activityEvents: [ActivityEvent]
    public var traffic: TrafficStats?
    public var heatmap: [HeatmapCell]
    public var detailCacheState: RepoDetailCacheState?
    public var discussionsEnabled: Bool?

    public init(
        id: String,
        name: String,
        owner: String,
        description: String? = nil,
        language: String? = nil,
        topics: [String] = [],
        isFork: Bool = false,
        isArchived: Bool = false,
        viewerCanRead: Bool = true,
        sortOrder: Int?,
        error: String?,
        rateLimitedUntil: Date?,
        ciStatus: CIStatus,
        ciRunCount: Int? = nil,
        openIssues: Int,
        openPulls: Int,
        stars: Int = 0,
        forks: Int = 0,
        pushedAt: Date? = nil,
        latestRelease: Release?,
        latestActivity: ActivityEvent?,
        activityEvents: [ActivityEvent] = [],
        traffic: TrafficStats?,
        heatmap: [HeatmapCell],
        detailCacheState: RepoDetailCacheState? = nil,
        discussionsEnabled: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.owner = owner
        self.description = description
        self.language = language
        self.topics = topics
        self.isFork = isFork
        self.isArchived = isArchived
        self.viewerCanRead = viewerCanRead
        self.sortOrder = sortOrder
        self.error = error
        self.rateLimitedUntil = rateLimitedUntil
        self.ciStatus = ciStatus
        self.ciRunCount = ciRunCount
        self.stats = RepositoryStats(
            openIssues: openIssues,
            openPulls: openPulls,
            stars: stars,
            forks: forks,
            pushedAt: pushedAt
        )
        self.latestRelease = latestRelease
        self.latestActivity = latestActivity
        self.activityEvents = activityEvents
        self.traffic = traffic
        self.heatmap = heatmap
        self.detailCacheState = detailCacheState
        self.discussionsEnabled = discussionsEnabled
    }

    public var fullName: String {
        "\(self.owner)/\(self.name)"
    }

    public func withOrder(_ order: Int?) -> Repository {
        Repository(
            id: self.id,
            name: self.name,
            owner: self.owner,
            description: self.description,
            language: self.language,
            topics: self.topics,
            isFork: self.isFork,
            isArchived: self.isArchived,
            viewerCanRead: self.viewerCanRead,
            sortOrder: order,
            error: self.error,
            rateLimitedUntil: self.rateLimitedUntil,
            ciStatus: self.ciStatus,
            ciRunCount: self.ciRunCount,
            openIssues: self.stats.openIssues,
            openPulls: self.stats.openPulls,
            stars: self.stats.stars,
            forks: self.stats.forks,
            pushedAt: self.stats.pushedAt,
            latestRelease: self.latestRelease,
            latestActivity: self.latestActivity,
            activityEvents: self.activityEvents,
            traffic: self.traffic,
            heatmap: self.heatmap,
            detailCacheState: self.detailCacheState,
            discussionsEnabled: self.discussionsEnabled
        )
    }

    public var openIssues: Int {
        get { self.stats.openIssues }
        set { self.stats.openIssues = newValue }
    }

    public var openPulls: Int {
        get { self.stats.openPulls }
        set { self.stats.openPulls = newValue }
    }

    public var stars: Int {
        get { self.stats.stars }
        set { self.stats.stars = newValue }
    }

    public var forks: Int {
        get { self.stats.forks }
        set { self.stats.forks = newValue }
    }

    public var pushedAt: Date? {
        get { self.stats.pushedAt }
        set { self.stats.pushedAt = newValue }
    }
}

public enum CIStatus: Codable, Equatable, Sendable {
    case passing
    case failing
    case pending
    case unknown
}

public struct Release: Codable, Equatable, Sendable {
    public let name: String
    public let tag: String
    public let publishedAt: Date
    public let url: URL

    public init(name: String, tag: String, publishedAt: Date, url: URL) {
        self.name = name
        self.tag = tag
        self.publishedAt = publishedAt
        self.url = url
    }
}

public struct TrafficStats: Codable, Equatable, Sendable {
    public let uniqueVisitors: Int
    public let uniqueCloners: Int

    public init(uniqueVisitors: Int, uniqueCloners: Int) {
        self.uniqueVisitors = uniqueVisitors
        self.uniqueCloners = uniqueCloners
    }
}

public struct ActivityEvent: Codable, Equatable, Sendable {
    public let title: String
    public let actor: String
    public let actorAvatarURL: URL?
    public let date: Date
    public let url: URL
    public let eventType: String?
    public let metadata: ActivityMetadata?

    public init(
        title: String,
        actor: String,
        actorAvatarURL: URL? = nil,
        date: Date,
        url: URL,
        eventType: String? = nil,
        metadata: ActivityMetadata? = nil
    ) {
        self.title = title
        self.actor = actor
        self.actorAvatarURL = actorAvatarURL
        self.date = date
        self.url = url
        self.eventType = eventType
        self.metadata = metadata
    }

    public var eventTypeEnum: ActivityEventType? {
        ActivityEventType.parse(self.eventType)
    }
}

public struct HeatmapCell: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let date: Date
    public let count: Int

    public init(id: UUID = UUID(), date: Date, count: Int) {
        self.id = id
        self.date = date
        self.count = count
    }
}

public struct CIStatusDetails: Codable, Sendable {
    public let status: CIStatus
    public let runCount: Int?

    public init(status: CIStatus, runCount: Int?) {
        self.status = status
        self.runCount = runCount
    }
}
