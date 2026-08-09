import Foundation
@testable import RepoBar
import RepoBarCore
import Testing

struct ArchivedFilteringTests {
    @Test
    func `repository filter excludes archived by default`() {
        let repos = [
            Self.repo(name: "A", isArchived: false),
            Self.repo(name: "B", isArchived: true),
            Self.repo(name: "C", isArchived: false)
        ]
        let filtered = RepositoryFilter.apply(repos, includeForks: true, includeArchived: false)
        #expect(filtered.map(\.name) == ["A", "C"])
    }

    @Test
    func `repository filter keeps pinned archived repos`() {
        let pinnedArchived = Self.repo(owner: "me", name: "PinnedArchived", isArchived: true)
        let otherArchived = Self.repo(owner: "me", name: "OtherArchived", isArchived: true)
        let normal = Self.repo(owner: "me", name: "Normal", isArchived: false)

        let filtered = RepositoryFilter.apply(
            [pinnedArchived, otherArchived, normal],
            includeForks: true,
            includeArchived: false,
            pinned: Set([pinnedArchived.fullName])
        )
        #expect(filtered.map(\.fullName) == [pinnedArchived.fullName, normal.fullName])
    }

    @Test
    func `select visible hides unpinned archived but keeps pinned archived`() {
        let pinnedArchived = Self.repo(owner: "me", name: "PinnedArchived", isArchived: true)
        let otherArchived = Self.repo(owner: "me", name: "OtherArchived", isArchived: true)
        let normal = Self.repo(owner: "me", name: "Normal", isArchived: false)

        let visible = AppState.selectVisible(
            all: [otherArchived, normal, pinnedArchived],
            options: AppState.VisibleSelectionOptions(
                pinned: [pinnedArchived.fullName],
                hidden: [],
                includeForks: true,
                includeArchived: false,
                limit: 10,
                ownerFilter: []
            )
        )

        #expect(visible.map(\.fullName) == [pinnedArchived.fullName, normal.fullName])
    }
}

private extension ArchivedFilteringTests {
    static func repo(owner: String = "me", name: String, isArchived: Bool) -> Repository {
        Repository(
            id: UUID().uuidString,
            name: name,
            owner: owner,
            isFork: false,
            isArchived: isArchived,
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
