import Foundation
@testable import RepoBar
import RepoBarCore
import Testing

struct OnlyWithFilteringTests {
    @Test
    func `only with work includes issues or P rs`() {
        let repos = [
            Self.repo(name: "none", issues: 0, prs: 0),
            Self.repo(name: "issues", issues: 2, prs: 0),
            Self.repo(name: "prs", issues: 0, prs: 3)
        ]

        let filtered = RepositoryFilter.apply(
            repos,
            includeForks: true,
            includeArchived: true,
            onlyWith: RepositoryOnlyWith(requireIssues: true, requirePRs: true)
        )

        #expect(filtered.map(\.name) == ["issues", "prs"])
    }

    @Test
    func `only with keeps pinned repos even if no work`() {
        let pinned = Self.repo(owner: "me", name: "pinned", issues: 0, prs: 0)
        let other = Self.repo(owner: "me", name: "other", issues: 0, prs: 0)

        let filtered = RepositoryFilter.apply(
            [other, pinned],
            includeForks: true,
            includeArchived: true,
            pinned: Set([pinned.fullName]),
            onlyWith: RepositoryOnlyWith(requireIssues: true, requirePRs: true)
        )

        #expect(filtered.map(\.fullName) == [pinned.fullName])
    }

    @Test
    func `only with issues only`() {
        let repos = [
            Self.repo(name: "none", issues: 0, prs: 9),
            Self.repo(name: "issues", issues: 1, prs: 0)
        ]

        let filtered = RepositoryFilter.apply(
            repos,
            includeForks: true,
            includeArchived: true,
            onlyWith: RepositoryOnlyWith(requireIssues: true, requirePRs: false)
        )

        #expect(filtered.map(\.name) == ["issues"])
    }
}

private extension OnlyWithFilteringTests {
    static func repo(owner: String = "me", name: String, issues: Int, prs: Int) -> Repository {
        Repository(
            id: UUID().uuidString,
            name: name,
            owner: owner,
            isFork: false,
            isArchived: false,
            sortOrder: nil,
            error: nil,
            rateLimitedUntil: nil,
            ciStatus: .unknown,
            ciRunCount: nil,
            openIssues: issues,
            openPulls: prs,
            stars: 0,
            pushedAt: nil,
            latestRelease: nil,
            latestActivity: nil,
            traffic: nil,
            heatmap: []
        )
    }
}
