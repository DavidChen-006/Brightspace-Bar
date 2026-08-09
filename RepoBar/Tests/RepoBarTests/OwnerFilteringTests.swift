import Foundation
@testable import RepoBar
import RepoBarCore
import Testing

struct OwnerFilteringTests {
    @Test
    func `owner filter normalize trims lowercases dedupes and sorts`() {
        #expect(OwnerFilter.normalize([" Alice ", "bob", "ALICE", "", "  "]) == ["alice", "bob"])
    }

    @Test
    func `repository filter includes all when owner filter is empty`() {
        let repos = [
            Self.repo(owner: "alice", name: "A"),
            Self.repo(owner: "bob", name: "B"),
            Self.repo(owner: "charlie", name: "C")
        ]
        let filtered = RepositoryFilter.apply(
            repos,
            includeForks: true,
            includeArchived: true,
            ownerFilter: []
        )
        #expect(filtered.count == 3)
    }

    @Test
    func `repository filter treats whitespace only owner filter as empty`() {
        let repos = [
            Self.repo(owner: "alice", name: "A"),
            Self.repo(owner: "bob", name: "B")
        ]
        let filtered = RepositoryFilter.apply(
            repos,
            includeForks: true,
            includeArchived: true,
            ownerFilter: [" ", "\n\t"]
        )
        #expect(filtered.count == 2)
    }

    @Test
    func `repository filter includes only specified owner`() {
        let repos = [
            Self.repo(owner: "alice", name: "A"),
            Self.repo(owner: "bob", name: "B"),
            Self.repo(owner: "charlie", name: "C")
        ]
        let filtered = RepositoryFilter.apply(
            repos,
            includeForks: true,
            includeArchived: true,
            ownerFilter: ["alice"]
        )
        #expect(filtered.count == 1)
        #expect(filtered.first?.owner == "alice")
    }

    @Test
    func `repository filter includes multiple specified owners`() {
        let repos = [
            Self.repo(owner: "alice", name: "A"),
            Self.repo(owner: "bob", name: "B"),
            Self.repo(owner: "charlie", name: "C"),
            Self.repo(owner: "alice", name: "D")
        ]
        let filtered = RepositoryFilter.apply(
            repos,
            includeForks: true,
            includeArchived: true,
            ownerFilter: ["alice", "charlie"]
        )
        #expect(filtered.count == 3)
        #expect(filtered.map(\.owner).sorted() == ["alice", "alice", "charlie"])
    }

    @Test
    func `repository filter is case insensitive`() {
        let repos = [
            Self.repo(owner: "Alice", name: "A"),
            Self.repo(owner: "BOB", name: "B"),
            Self.repo(owner: "charlie", name: "C")
        ]
        let filtered = RepositoryFilter.apply(
            repos,
            includeForks: true,
            includeArchived: true,
            ownerFilter: ["alice", "bob"]
        )
        #expect(filtered.count == 2)
    }

    @Test
    func `repository filter trims owner filter entries`() {
        let repos = [
            Self.repo(owner: "alice", name: "A"),
            Self.repo(owner: "bob", name: "B")
        ]
        let filtered = RepositoryFilter.apply(
            repos,
            includeForks: true,
            includeArchived: true,
            ownerFilter: [" alice "]
        )
        #expect(filtered.count == 1)
        #expect(filtered.first?.owner == "alice")
    }

    @Test
    func `repository filter keeps pinned repos regardless of owner`() {
        let pinnedRepo = Self.repo(owner: "dotnet", name: "Pinned")
        let otherRepo = Self.repo(owner: "dotnet", name: "Other")
        let myRepo = Self.repo(owner: "me", name: "Mine")

        let filtered = RepositoryFilter.apply(
            [pinnedRepo, otherRepo, myRepo],
            includeForks: true,
            includeArchived: true,
            pinned: Set([pinnedRepo.fullName]),
            ownerFilter: ["me"]
        )
        #expect(filtered.count == 2)
        #expect(filtered.map(\.fullName).sorted() == [myRepo.fullName, pinnedRepo.fullName].sorted())
    }

    @Test
    func `select visible applies owner filter`() {
        let myRepo1 = Self.repo(owner: "me", name: "Repo1")
        let myRepo2 = Self.repo(owner: "me", name: "Repo2")
        let orgRepo1 = Self.repo(owner: "dotnet", name: "AspNetCore")
        let orgRepo2 = Self.repo(owner: "microsoft", name: "TypeScript")

        let visible = AppState.selectVisible(
            all: [myRepo1, orgRepo1, myRepo2, orgRepo2],
            options: AppState.VisibleSelectionOptions(
                pinned: [],
                hidden: [],
                includeForks: true,
                includeArchived: true,
                limit: 10,
                ownerFilter: ["me"]
            )
        )

        #expect(visible.count == 2)
        #expect(visible.map(\.owner).allSatisfy { $0 == "me" })
    }

    @Test
    func `repository pipeline applies owner filter`() {
        let repos = [
            Self.repo(owner: "alice", name: "A"),
            Self.repo(owner: "bob", name: "B"),
            Self.repo(owner: "charlie", name: "C")
        ]
        let query = RepositoryQuery(
            scope: .all,
            onlyWith: .none,
            includeForks: true,
            includeArchived: true,
            sortKey: .name,
            limit: nil,
            ageCutoff: nil,
            pinned: [],
            hidden: [],
            pinPriority: false,
            ownerFilter: ["alice", "bob"]
        )
        let filtered = RepositoryPipeline.apply(repos, query: query)
        #expect(filtered.count == 2)
        #expect(filtered.map(\.owner).sorted() == ["alice", "bob"])
    }

    @Test
    func `repository query normalizes owner filter for equality`() {
        let left = RepositoryQuery(ownerFilter: ["Alice", " bob ", "ALICE"])
        let right = RepositoryQuery(ownerFilter: ["bob", "alice"])
        #expect(left == right)
        #expect(left.ownerFilter == ["alice", "bob"])
    }
}

private extension OwnerFilteringTests {
    static func repo(owner: String, name: String) -> Repository {
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
