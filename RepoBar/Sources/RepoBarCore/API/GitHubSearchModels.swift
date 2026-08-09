import Foundation

struct SearchResponse: Decodable {
    let items: [RepoItem]
}

struct RepoItem: Decodable {
    let id: Int
    let name: String
    let fullName: String
    let description: String?
    let language: String?
    let topics: [String]?
    let fork: Bool
    let archived: Bool
    let hasDiscussions: Bool?
    let openIssuesCount: Int
    let stargazersCount: Int
    let forksCount: Int
    let pushedAt: Date?
    let permissions: RepoItemPermissions?
    let owner: Owner

    struct Owner: Decodable { let login: String }

    enum CodingKeys: String, CodingKey {
        case id, name, description, language, topics
        case fullName = "full_name"
        case fork
        case archived
        case hasDiscussions = "has_discussions"
        case openIssuesCount = "open_issues_count"
        case stargazersCount = "stargazers_count"
        case forksCount = "forks_count"
        case pushedAt = "pushed_at"
        case permissions
        case owner
    }
}

struct RepoItemPermissions: Decodable {
    let admin: Bool?
    let maintain: Bool?
    let push: Bool?
    let pull: Bool?

    var hasReadAccess: Bool {
        self.admin == true || self.maintain == true || self.push == true || self.pull == true
    }
}

struct SearchIssuesResponse: Decodable {
    let totalCount: Int

    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
    }
}

struct IssueReferenceSearchResponse: Decodable {
    let items: [IssueReferenceSearchItem]
}

struct IssueReferenceSearchItem: Decodable {
    let number: Int
    let title: String
    let body: String?
    let htmlUrl: URL
    let repositoryUrl: URL?
    let repository: RepositoryReference?
    let state: String
    let createdAt: Date?
    let updatedAt: Date
    let pullRequest: PullRequestMarker?
    let user: User?

    enum CodingKeys: String, CodingKey {
        case number, title, body, state, user
        case htmlUrl = "html_url"
        case repositoryUrl = "repository_url"
        case repository
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case pullRequest = "pull_request"
    }

    struct PullRequestMarker: Decodable {
        let mergedAt: Date?

        enum CodingKeys: String, CodingKey {
            case mergedAt = "merged_at"
        }
    }

    struct User: Decodable {
        let login: String
    }

    struct RepositoryReference: Decodable {
        let fullName: String

        enum CodingKeys: String, CodingKey {
            case fullName = "full_name"
        }
    }

    func match() -> GitHubReferenceMatch? {
        guard let repositoryFullName = self.repositoryFullName else { return nil }

        let query = GitHubReferenceQuery.repositoryIssueNumber(
            repositoryFullName: repositoryFullName,
            number: self.number
        )
        return GitHubReferenceMatch(
            query: query,
            title: self.title,
            url: self.htmlUrl,
            repositoryFullName: repositoryFullName,
            kind: self.pullRequest == nil ? .issue : .pullRequest,
            state: self.referenceState,
            createdAt: self.createdAt,
            updatedAt: self.updatedAt,
            bodyPreview: Self.bodyPreview(from: self.body),
            authorLogin: self.user?.login
        )
    }

    private var referenceState: GitHubReferenceState? {
        if self.pullRequest?.mergedAt != nil {
            return .merged
        }

        return GitHubReferenceState(rawValue: self.state.lowercased())
    }

    private var repositoryFullName: String? {
        if let fullName = self.repository?.fullName, fullName.isEmpty == false {
            return fullName
        }

        guard let repositoryUrl else { return nil }

        let parts = repositoryUrl.path.split(separator: "/").map(String.init)
        guard let repoIndex = parts.firstIndex(of: "repos"),
              parts.count > repoIndex + 2
        else { return nil }

        return "\(parts[repoIndex + 1])/\(parts[repoIndex + 2])"
    }

    private static func bodyPreview(from body: String?) -> String? {
        guard let body else { return nil }

        let collapsed = body
            .replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
        guard collapsed.isEmpty == false else { return nil }

        let limit = 240
        return collapsed.count > limit
            ? "\(collapsed.prefix(limit - 1))…"
            : collapsed
    }
}

struct PullRequestListItem: Decodable {
    let id: Int
}
