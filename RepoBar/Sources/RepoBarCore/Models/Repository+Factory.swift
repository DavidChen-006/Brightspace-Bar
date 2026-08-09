import Foundation

extension Repository {
    static func from(
        item: RepoItem,
        openPulls: Int = 0,
        issues: Int? = nil,
        ciStatus: CIStatus = .unknown,
        ciRunCount: Int? = nil,
        latestRelease: Release? = nil,
        latestActivity: ActivityEvent? = nil,
        activityEvents: [ActivityEvent] = [],
        traffic: TrafficStats? = nil,
        heatmap: [HeatmapCell] = [],
        error: String? = nil,
        rateLimitedUntil: Date? = nil,
        detailCacheState: RepoDetailCacheState? = nil,
        discussionsEnabled: Bool? = nil
    ) -> Repository {
        Repository(
            id: item.id.description,
            name: item.name,
            owner: item.owner.login,
            description: item.description,
            language: item.language,
            topics: item.topics ?? [],
            isFork: item.fork,
            isArchived: item.archived,
            viewerCanRead: item.permissions?.hasReadAccess ?? true,
            sortOrder: nil,
            error: error,
            rateLimitedUntil: rateLimitedUntil,
            ciStatus: ciStatus,
            ciRunCount: ciRunCount,
            openIssues: issues ?? item.openIssuesCount,
            openPulls: openPulls,
            stars: item.stargazersCount,
            forks: item.forksCount,
            pushedAt: item.pushedAt,
            latestRelease: latestRelease,
            latestActivity: latestActivity,
            activityEvents: activityEvents,
            traffic: traffic,
            heatmap: heatmap,
            detailCacheState: detailCacheState,
            discussionsEnabled: discussionsEnabled ?? item.hasDiscussions
        )
    }

    static func placeholder(
        owner: String,
        name: String,
        error: String?,
        rateLimitedUntil: Date?
    ) -> Repository {
        Repository(
            id: "\(owner)/\(name)",
            name: name,
            owner: owner,
            sortOrder: nil,
            error: error,
            rateLimitedUntil: rateLimitedUntil,
            ciStatus: .unknown,
            ciRunCount: nil,
            openIssues: 0,
            openPulls: 0,
            stars: 0,
            forks: 0,
            pushedAt: nil,
            latestRelease: nil,
            latestActivity: nil,
            traffic: nil,
            heatmap: []
        )
    }
}
