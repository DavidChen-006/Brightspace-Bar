import Foundation
import RepoBarCore

struct RepositoryCardModel: Identifiable, Equatable {
    let source: Repository
    let id: String
    let title: String
    let owner: String
    let ciStatus: CIStatus
    let ciRunCount: Int?
    let issues: Int
    let pulls: Int
    let stars: Int
    let forks: Int
    let trafficVisitors: Int?
    let trafficCloners: Int?
    let releaseLine: String?
    let activityLine: String?
    let activityURL: URL?
    let latestActivityAge: String?
    let heatmap: [HeatmapCell]
    let error: String?
    let rateLimitedUntil: Date?

    init(repo: Repository, now: Date = Date()) {
        self.source = repo
        self.id = repo.id
        self.title = repo.fullName
        self.owner = repo.owner
        self.ciStatus = repo.ciStatus
        self.ciRunCount = repo.ciRunCount
        self.issues = repo.stats.openIssues
        self.pulls = repo.stats.openPulls
        self.stars = repo.stats.stars
        self.forks = repo.stats.forks
        self.trafficVisitors = repo.traffic?.uniqueVisitors
        self.trafficCloners = repo.traffic?.uniqueCloners
        self.heatmap = repo.heatmap
        self.error = repo.error
        self.rateLimitedUntil = repo.rateLimitedUntil

        if let release = repo.latestRelease {
            self.releaseLine = ReleaseFormatter.menuLine(for: release, now: now)
        } else {
            self.releaseLine = nil
        }

        self.activityLine = repo.activityLine
        self.activityURL = repo.activityURL
        if let activityDate = repo.latestActivity?.date ?? repo.activityEvents.first?.date {
            self.latestActivityAge = RelativeFormatter.string(from: activityDate, relativeTo: now)
        } else {
            self.latestActivityAge = nil
        }
    }
}
