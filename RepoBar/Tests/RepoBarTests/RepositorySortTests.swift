import Foundation
@testable import RepoBarCore
import Testing

struct RepositorySortTests {
    @Test
    func `sorted by issues falls back to activity`() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let newer = now.addingTimeInterval(-60)
        let older = now.addingTimeInterval(-3600)

        let repoA = Self.repo(name: "A", issues: 5, pulls: 0, stars: 0, pushedAt: newer)
        let repoB = Self.repo(name: "B", issues: 5, pulls: 0, stars: 0, pushedAt: older)

        let sorted = RepositorySort.sorted([repoB, repoA], sortKey: .issues)
        #expect(sorted.map(\.name) == ["A", "B"])
    }

    @Test
    func `sorted by name is case insensitive`() {
        let repoA = Self.repo(owner: "a", name: "Repo", issues: 0, pulls: 0, stars: 0, pushedAt: nil)
        let repoB = Self.repo(owner: "B", name: "repo", issues: 0, pulls: 0, stars: 0, pushedAt: nil)

        let sorted = RepositorySort.sorted([repoB, repoA], sortKey: .name)
        #expect(sorted.map(\.fullName) == ["a/Repo", "B/repo"])
    }

    @Test
    func `sorted by event uses activity line with push fallback`() throws {
        let withActivity = try Self.repo(
            name: "A",
            issues: 0,
            pulls: 0,
            stars: 0,
            pushedAt: nil,
            activity: ActivityEvent(
                title: "Fix",
                actor: "alice",
                date: Date(timeIntervalSinceReferenceDate: 10),
                url: #require(URL(string: "https://example.com"))
            )
        )
        let withPushFallback = Self.repo(name: "B", issues: 0, pulls: 0, stars: 0, pushedAt: Date(), activity: nil)

        let sorted = RepositorySort.sorted([withPushFallback, withActivity], sortKey: .event)
        #expect(sorted.first?.name == "A")
    }

    @Test
    func `activity date picks most recent of activity and push`() throws {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let pushedAt = now.addingTimeInterval(-100)
        let activityAt = now.addingTimeInterval(-10)

        let repo = try Self.repo(
            name: "Repo",
            issues: 0,
            pulls: 0,
            stars: 0,
            pushedAt: pushedAt,
            activity: ActivityEvent(
                title: "PR",
                actor: "bob",
                date: activityAt,
                url: #require(URL(string: "https://example.com"))
            )
        )
        #expect(repo.activityDate == activityAt)
    }

    @Test
    func `activity line falls back to push`() {
        let repo = Self.repo(name: "Repo", issues: 0, pulls: 0, stars: 0, pushedAt: Date(), activity: nil)
        #expect(repo.activityLine(fallbackToPush: true) == "push")
        #expect(repo.activityLine(fallbackToPush: false) == nil)
    }
}

private extension RepositorySortTests {
    static func repo(
        owner: String = "steipete",
        name: String,
        issues: Int,
        pulls: Int,
        stars: Int,
        pushedAt: Date?,
        activity: ActivityEvent? = nil
    ) -> Repository {
        Repository(
            id: UUID().uuidString,
            name: name,
            owner: owner,
            sortOrder: nil,
            error: nil,
            rateLimitedUntil: nil,
            ciStatus: .unknown,
            ciRunCount: nil,
            openIssues: issues,
            openPulls: pulls,
            stars: stars,
            pushedAt: pushedAt,
            latestRelease: nil,
            latestActivity: activity,
            traffic: nil,
            heatmap: []
        )
    }
}
