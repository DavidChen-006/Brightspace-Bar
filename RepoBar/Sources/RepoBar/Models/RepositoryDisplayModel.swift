import Foundation
import RepoBarCore

struct RepositoryDisplayModel: Identifiable, Equatable {
    struct Stat: Identifiable, Equatable {
        let id: String
        let label: String?
        let value: Int
        let systemImage: String
    }

    let source: Repository
    let id: String
    let title: String
    let releaseLine: String?
    let lastPushAge: String?
    let ciStatus: CIStatus
    let ciRunCount: Int?
    let issues: Int
    let pulls: Int
    let stats: [Stat]
    let trafficVisitors: Int?
    let trafficCloners: Int?
    let stars: Int
    let forks: Int
    let activityLine: String?
    let activityURL: URL?
    let activityEvents: [ActivityEvent]
    let latestActivityAge: String?
    let heatmap: [HeatmapCell]
    let sortOrder: Int?
    let error: String?
    let rateLimitedUntil: Date?
    let localStatus: LocalRepoStatus?

    init(repo: Repository, localStatus: LocalRepoStatus? = nil, now: Date = Date()) {
        self.source = repo
        self.id = repo.id
        self.title = repo.fullName
        self.ciStatus = repo.ciStatus
        self.ciRunCount = repo.ciRunCount
        self.issues = repo.stats.openIssues
        self.pulls = repo.stats.openPulls
        self.trafficVisitors = repo.traffic?.uniqueVisitors
        self.trafficCloners = repo.traffic?.uniqueCloners
        self.stars = repo.stats.stars
        self.forks = repo.stats.forks
        self.heatmap = repo.heatmap
        self.sortOrder = repo.sortOrder
        self.error = repo.error
        self.rateLimitedUntil = repo.rateLimitedUntil
        self.localStatus = localStatus

        if let release = repo.latestRelease {
            self.releaseLine = ReleaseFormatter.menuLine(for: release, now: now)
        } else {
            self.releaseLine = nil
        }

        if let pushedAt = repo.stats.pushedAt {
            self.lastPushAge = RelativeFormatter.string(from: pushedAt, relativeTo: now)
        } else {
            self.lastPushAge = nil
        }

        self.activityLine = repo.activityLine
        self.activityURL = repo.activityURL
        if repo.activityEvents.isEmpty, let latest = repo.latestActivity {
            self.activityEvents = [latest]
        } else {
            self.activityEvents = repo.activityEvents
        }
        if let activityDate = repo.latestActivity?.date ?? self.activityEvents.first?.date {
            self.latestActivityAge = RelativeFormatter.string(from: activityDate, relativeTo: now)
        } else {
            self.latestActivityAge = nil
        }

        self.stats = [
            Stat(id: "issues", label: "Issues", value: repo.stats.openIssues, systemImage: "exclamationmark.circle"),
            Stat(id: "prs", label: "PRs", value: repo.stats.openPulls, systemImage: "arrow.triangle.branch"),
            Stat(id: "stars", label: nil, value: repo.stats.stars, systemImage: "star"),
            Stat(id: "forks", label: "Forks", value: repo.stats.forks, systemImage: "tuningfork")
        ]
    }

    init(localStatus: LocalRepoStatus, now _: Date = Date()) {
        let placeholderRepo = Repository(
            id: "local:\(localStatus.path.path)",
            name: localStatus.name,
            owner: "",
            sortOrder: nil,
            error: nil,
            rateLimitedUntil: nil,
            ciStatus: .unknown,
            openIssues: 0,
            openPulls: 0,
            latestRelease: nil,
            latestActivity: nil,
            traffic: nil,
            heatmap: []
        )
        self.source = placeholderRepo
        self.id = placeholderRepo.id
        self.title = localStatus.displayName
        self.ciStatus = .unknown
        self.ciRunCount = nil
        self.issues = 0
        self.pulls = 0
        self.trafficVisitors = nil
        self.trafficCloners = nil
        self.stars = 0
        self.forks = 0
        self.heatmap = []
        self.sortOrder = nil
        self.error = nil
        self.rateLimitedUntil = nil
        self.localStatus = localStatus
        self.releaseLine = nil
        self.lastPushAge = nil
        self.activityLine = nil
        self.activityURL = nil
        self.activityEvents = []
        self.latestActivityAge = nil
        self.stats = []
    }

    var isLocalOnly: Bool {
        self.source.owner.isEmpty && self.id.hasPrefix("local:")
    }
}
