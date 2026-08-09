import Foundation
import Observation
import RepoBarCore

@MainActor
@Observable
final class RepoDetailModel {
    private enum DetailSection: String {
        case pulls = "Pull Requests"
        case issues = "Issues"
        case releases = "Releases"
        case workflows = "Workflow Runs"
        case commits = "Commits"
        case discussions = "Discussions"
        case tags = "Tags"
        case branches = "Branches"
        case contributors = "Contributors"
    }

    let repo: Repository
    private let github: GitHubClient
    private let logger = RepoBarLogging.logger("repo-detail")
    var isLoading = false
    var pulls: [RepoPullRequestSummary] = []
    var issues: [RepoIssueSummary] = []
    var releases: [RepoReleaseSummary] = []
    var workflows: [RepoWorkflowRunSummary] = []
    var commits: RepoCommitList?
    var discussions: [RepoDiscussionSummary] = []
    var tags: [RepoTagSummary] = []
    var branches: [RepoBranchSummary] = []
    var contributors: [RepoContributorSummary] = []
    var error: String?

    init(repo: Repository, github: GitHubClient) {
        self.repo = repo
        self.github = github
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        logger.info("Repo detail refresh started for \(repo.fullName)")
        defer { isLoading = false }

        async let pullsResult: Result<[RepoPullRequestSummary], Error> = capture { [self] in
            try await github.recentPullRequests(owner: repo.owner, name: repo.name, limit: AppLimits.RecentLists.limit)
        }
        async let issuesResult: Result<[RepoIssueSummary], Error> = capture { [self] in
            try await github.recentIssues(owner: repo.owner, name: repo.name, limit: AppLimits.RecentLists.limit)
        }
        async let releasesResult: Result<[RepoReleaseSummary], Error> = capture { [self] in
            try await github.recentReleases(owner: repo.owner, name: repo.name, limit: AppLimits.RecentLists.limit)
        }
        async let workflowsResult: Result<[RepoWorkflowRunSummary], Error> = capture { [self] in
            try await github.recentWorkflowRuns(owner: repo.owner, name: repo.name, limit: AppLimits.RecentLists.limit)
        }
        async let commitsResult: Result<RepoCommitList, Error> = capture { [self] in
            try await github.recentCommits(owner: repo.owner, name: repo.name, limit: AppLimits.RepoCommits.totalLimit)
        }
        async let discussionsResult: Result<[RepoDiscussionSummary], Error> = capture { [self] in
            try await github.recentDiscussions(owner: repo.owner, name: repo.name, limit: AppLimits.RecentLists.limit)
        }
        async let tagsResult: Result<[RepoTagSummary], Error> = capture { [self] in
            try await github.recentTags(owner: repo.owner, name: repo.name, limit: AppLimits.RecentLists.limit)
        }
        async let branchesResult: Result<[RepoBranchSummary], Error> = capture { [self] in
            try await github.recentBranches(owner: repo.owner, name: repo.name, limit: AppLimits.RecentLists.limit)
        }
        async let contributorsResult: Result<[RepoContributorSummary], Error> = capture { [self] in
            try await github.topContributors(owner: repo.owner, name: repo.name, limit: AppLimits.RecentLists.limit)
        }

        switch await pullsResult {
        case let .success(value): pulls = value
        case let .failure(error): self.record(error, section: .pulls)
        }
        switch await issuesResult {
        case let .success(value): issues = value
        case let .failure(error): self.record(error, section: .issues)
        }
        switch await releasesResult {
        case let .success(value): releases = value
        case let .failure(error): self.record(error, section: .releases)
        }
        switch await workflowsResult {
        case let .success(value): workflows = value
        case let .failure(error): self.record(error, section: .workflows)
        }
        switch await commitsResult {
        case let .success(value): commits = value
        case let .failure(error): self.record(error, section: .commits)
        }
        switch await discussionsResult {
        case let .success(value): discussions = value
        case let .failure(error): self.record(error, section: .discussions)
        }
        switch await tagsResult {
        case let .success(value): tags = value
        case let .failure(error): self.record(error, section: .tags)
        }
        switch await branchesResult {
        case let .success(value): branches = value
        case let .failure(error): self.record(error, section: .branches)
        }
        switch await contributorsResult {
        case let .success(value): contributors = value
        case let .failure(error): self.record(error, section: .contributors)
        }

        if let error {
            logger.info("Repo detail refresh completed with error for \(repo.fullName): \(error)")
        } else {
            logger.info("Repo detail refresh completed for \(repo.fullName)")
        }
    }

    private func capture<T>(_ work: @escaping () async throws -> T) async -> Result<T, Error> {
        do { return try await .success(work()) } catch { return .failure(error) }
    }

    private func record(_ error: Error, section: DetailSection) {
        let typeName = String(reflecting: type(of: error))
        let nsError = error as NSError
        logger.warning(
            "Repo detail \(section.rawValue) failed for \(repo.fullName) domain=\(nsError.domain) code=\(nsError.code) type=\(typeName) message=\(error.userFacingMessage)"
        )
        guard let message = self.message(for: error, section: section) else { return }
        if self.error == nil {
            self.error = message
        }
    }

    private func message(for error: Error, section: DetailSection) -> String? {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            switch code {
            case .fileDoesNotExist, .resourceUnavailable:
                return "Repository data unavailable. It may have been renamed, deleted, or you no longer have access. Try refreshing or signing in again."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Cannot reach GitHub host. Check your network or Enterprise URL."
            default:
                break
            }
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError {
            return "Repository data unavailable. It may have been renamed, deleted, or you no longer have access. Try refreshing or signing in again."
        }

        if let ghError = error as? GitHubAPIError {
            switch ghError {
            case let .badStatus(code, _):
                // Discussions endpoints return 404/410 when the feature is disabled; treat as empty instead of error.
                if section == .discussions, code == 404 || code == 410 {
                    return nil
                }
                return self.badStatusMessage(code: code, section: section)
            case let .rateLimited(until, message):
                if let until {
                    return "\(section.rawValue) rate limited. Retry \(RelativeFormatter.string(from: until, relativeTo: Date()))."
                }
                return "\(section.rawValue) rate limited. \(message)"
            case let .serviceUnavailable(retryAfter, message):
                if let retryAfter {
                    return "\(section.rawValue) temporarily unavailable. Retry \(RelativeFormatter.string(from: retryAfter, relativeTo: Date()))."
                }
                return "\(section.rawValue) temporarily unavailable. \(message)"
            case .invalidHost:
                return "GitHub host is invalid. Check the Enterprise URL in Settings."
            case .invalidPEM:
                return "GitHub key is invalid. Check your credentials."
            }
        }

        if let urlError = error as? URLError, urlError.code == .fileDoesNotExist {
            return self.badStatusMessage(code: 404, section: section)
        }

        let lowercased = error.userFacingMessage.lowercased()
        if lowercased.contains("no longer exists") || lowercased.contains("no longer available") {
            return "Repository data unavailable. It may have been renamed, deleted, or you no longer have access. Try refreshing or signing in again."
        }
        if lowercased.contains("not found") {
            return self.badStatusMessage(code: 404, section: section)
        }

        return "\(section.rawValue) failed. \(error.userFacingMessage)"
    }

    private func badStatusMessage(code: Int, section: DetailSection) -> String {
        switch code {
        case 401, 403:
            return "\(section.rawValue) unavailable. Check GitHub access, token scopes, and sign-in status."
        case 404:
            switch section {
            case .releases:
                return "No releases published yet."
            case .discussions:
                return "Discussions are disabled for this repository."
            case .workflows:
                return "GitHub Actions data is unavailable for this repository."
            default:
                return "Repository data unavailable. It may be renamed, deleted, or you no longer have access. Try refreshing or signing in again."
            }
        default:
            return "\(section.rawValue) failed (HTTP \(code)). \(HTTPURLResponse.localizedString(forStatusCode: code))."
        }
    }
}
