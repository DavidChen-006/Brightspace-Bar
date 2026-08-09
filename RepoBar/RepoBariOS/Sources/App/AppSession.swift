import Foundation
import Observation
import RepoBarCore

@Observable
final class AppSession {
    var account: AccountState = .loggedOut
    var repositories: [Repository] = []
    var repositoryFilter: RepositoryContentFilter = .all
    var settings = UserSettings()
    var lastError: String?
    var isRefreshing = false
    var diagnostics = DiagnosticsSummary.empty
    var rateLimitError: String?
    var heatmapRange: HeatmapRange = HeatmapFilter.range(span: .twelveMonths, now: Date(), alignToWeek: true)
    var contributionHeatmap: [HeatmapCell] = []
    var contributionUser: String?
    var contributionError: String?
    var globalActivityEvents: [ActivityEvent] = []
    var globalActivityError: String?
    var globalCommitEvents: [RepoCommitSummary] = []
    var globalCommitError: String?
    var referenceDraftText = ""
    var referenceMatches: [GitHubReferenceMatch] = []
    var referenceError: String?
    var isResolvingReferences = false
}

enum AppTab: Hashable {
    case repos
    case activity
    case status
    case settings
}

enum AccountState: Equatable {
    case loggedOut
    case loggingIn
    case loggedIn(UserIdentity)
}

enum RepositoryContentFilter: String, CaseIterable, Equatable, Identifiable {
    case all
    case pinned
    case issues
    case pulls

    var id: String { self.rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .pinned: "Pinned"
        case .issues: "Issues"
        case .pulls: "PRs"
        }
    }

    var scope: RepositoryScope {
        switch self {
        case .pinned: .pinned
        case .all, .issues, .pulls: .all
        }
    }

    var onlyWith: RepositoryOnlyWith {
        switch self {
        case .issues: RepositoryOnlyWith(requireIssues: true)
        case .pulls: RepositoryOnlyWith(requirePRs: true)
        case .all, .pinned: .none
        }
    }
}
