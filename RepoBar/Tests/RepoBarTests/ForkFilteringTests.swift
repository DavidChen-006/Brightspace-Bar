import Foundation
@testable import RepoBar
import RepoBarCore
import Testing

struct ForkFilteringTests {
    @Test
    func `repository filter excludes forks by default`() {
        let repos = [
            Self.repo(name: "A", isFork: false),
            Self.repo(name: "B", isFork: true),
            Self.repo(name: "C", isFork: false)
        ]
        let filtered = RepositoryFilter.apply(repos, includeForks: false, includeArchived: false)
        #expect(filtered.map(\.name) == ["A", "C"])
    }

    @Test
    func `repository filter keeps pinned forks`() {
        let pinnedFork = Self.repo(owner: "me", name: "PinnedFork", isFork: true)
        let otherFork = Self.repo(owner: "me", name: "OtherFork", isFork: true)
        let normal = Self.repo(owner: "me", name: "Normal", isFork: false)

        let filtered = RepositoryFilter.apply(
            [pinnedFork, otherFork, normal],
            includeForks: false,
            includeArchived: false,
            pinned: Set([pinnedFork.fullName])
        )
        #expect(filtered.map(\.fullName) == [pinnedFork.fullName, normal.fullName])
    }

    @Test
    func `select visible hides unpinned forks but keeps pinned forks`() {
        let pinnedFork = Self.repo(owner: "me", name: "PinnedFork", isFork: true)
        let otherFork = Self.repo(owner: "me", name: "OtherFork", isFork: true)
        let normal = Self.repo(owner: "me", name: "Normal", isFork: false)

        let visible = AppState.selectVisible(
            all: [otherFork, normal, pinnedFork],
            options: AppState.VisibleSelectionOptions(
                pinned: [pinnedFork.fullName],
                hidden: [],
                includeForks: false,
                includeArchived: false,
                limit: 10,
                ownerFilter: []
            )
        )

        #expect(visible.map(\.fullName) == [pinnedFork.fullName, normal.fullName])
    }
}

private extension ForkFilteringTests {
    static func repo(owner: String = "me", name: String, isFork: Bool) -> Repository {
        Repository(
            id: UUID().uuidString,
            name: name,
            owner: owner,
            isFork: isFork,
            sortOrder: nil,
            error: nil,
            rateLimitedUntil: nil,
            ciStatus: .unknown,
            ciRunCount: nil,
            openIssues: 0,
            openPulls: 0,
            stars: 0,
            pushedAt: nil,
            latestRelease: nil,
            latestActivity: nil,
            traffic: nil,
            heatmap: []
        )
    }
}
