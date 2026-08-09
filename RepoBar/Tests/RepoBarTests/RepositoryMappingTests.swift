import Foundation
@testable import RepoBar
import RepoBarCore
import Testing

struct RepositoryMappingTests {
    @Test
    func `repo view model respects pinned order then alpha`() {
        let repos = [
            makeRepository(id: "1", name: "b", sortOrder: 2),
            makeRepository(id: "2", name: "a", sortOrder: 0),
            makeRepository(id: "3", name: "c")
        ]
        let viewModels = repos.map { RepositoryDisplayModel(repo: $0) }
        let sorted = TestableRepoGrid.sortedForTest(viewModels)
        let titles = sorted.map(\.title)
        #expect(titles == ["z/a", "z/b", "z/c"])
    }

    @Test
    func `traffic and errors propagate`() {
        let repo = Repository(
            id: "99",
            name: "repo",
            owner: "me",
            sortOrder: nil,
            error: "Rate limited",
            rateLimitedUntil: Date().addingTimeInterval(120),
            ciStatus: .pending,
            openIssues: 4,
            openPulls: 1,
            latestRelease: nil,
            latestActivity: nil,
            traffic: TrafficStats(uniqueVisitors: 10, uniqueCloners: 3),
            heatmap: []
        )
        let vm = RepositoryDisplayModel(repo: repo, now: Date())
        #expect(vm.error == "Rate limited")
        #expect(vm.rateLimitedUntil != nil)
        #expect(vm.trafficVisitors == 10)
        #expect(vm.trafficCloners == 3)
    }
}

private func makeRepository(id: String, name: String, sortOrder: Int? = nil) -> Repository {
    Repository(
        id: id,
        name: name,
        owner: "z",
        sortOrder: sortOrder,
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
}

/// Reuse helper from MenuContentViewModelTests
private enum TestableRepoGrid {
    static func sortedForTest(_ repos: [RepositoryDisplayModel]) -> [RepositoryDisplayModel] {
        repos.sorted { lhs, rhs in
            switch (lhs.sortOrder, rhs.sortOrder) {
            case let (left?, right?): left < right
            case (.none, .some): false
            case (.some, .none): true
            default: lhs.title < rhs.title
            }
        }
    }
}
