import Foundation
import RepoBarCore

enum IssueNavigatorKindFilter: String, CaseIterable, Identifiable {
    case all
    case issues
    case pullRequests

    var id: String {
        self.rawValue
    }

    var title: String {
        switch self {
        case .all: "Issues + PRs"
        case .issues: "Issues"
        case .pullRequests: "Pull Requests"
        }
    }

    var includeIssues: Bool {
        self != .pullRequests
    }

    var includePullRequests: Bool {
        self != .issues
    }

    func matches(_ kind: GitHubReferenceKind) -> Bool {
        switch self {
        case .all:
            true
        case .issues:
            kind == .issue
        case .pullRequests:
            kind == .pullRequest
        }
    }
}

struct IssueNavigatorScope: Identifiable, Hashable {
    let fullName: String?
    let title: String

    var id: String {
        self.fullName ?? "__all"
    }

    static let all = IssueNavigatorScope(fullName: nil, title: "All Repositories")
}

extension GitHubReferenceMatch {
    var issueNavigatorHeaderTitle: String {
        self.isResolved ? self.title : self.query.displayText
    }

    var issueNavigatorTitle: String {
        guard self.isResolved else { return self.query.displayText }

        return switch self.query {
        case let .issueNumber(number),
             let .repositoryNameIssueNumber(_, number),
             let .repositoryIssueNumber(_, number):
            "#\(number) \(self.title)"
        case let .commitHash(hash),
             let .repositoryCommitHash(_, hash):
            "\(String(hash.prefix(10))) \(self.title)"
        case let .repositoryWorkflowRun(_, runID):
            "Run \(runID) \(self.title)"
        }
    }
}

extension [GitHubReferenceMatch] {
    func issueNavigatorOrderPreservingDeduped() -> [GitHubReferenceMatch] {
        var seen: Set<URL> = []
        return self.filter { seen.insert($0.url).inserted }
    }
}
