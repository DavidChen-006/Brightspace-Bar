import Foundation
import RepoBarCore
import Testing

struct RepositorySortCoverageTests {
    @Test
    func `sorts by name and falls back to activity then full name`() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let older = now.addingTimeInterval(-10)
        let newer = now.addingTimeInterval(10)

        let a = Repository(
            id: "1",
            name: "Alpha",
            owner: "me",
            sortOrder: nil,
            error: nil,
            rateLimitedUntil: nil,
            ciStatus: .unknown,
            openIssues: 0,
            openPulls: 0,
            pushedAt: newer,
            latestRelease: nil,
            latestActivity: nil,
            traffic: nil,
            heatmap: []
        )
        let b = Repository(
            id: "2",
            name: "beta",
            owner: "me",
            sortOrder: nil,
            error: nil,
            rateLimitedUntil: nil,
            ciStatus: .unknown,
            openIssues: 0,
            openPulls: 0,
            pushedAt: older,
            latestRelease: nil,
            latestActivity: nil,
            traffic: nil,
            heatmap: []
        )

        let byName = RepositorySort.sorted([b, a], sortKey: .name)
        #expect(byName.first?.name == "Alpha")

        let byActivity = RepositorySort.sorted([a, b], sortKey: .activity)
        #expect(byActivity.first?.pushedAt == newer)
    }

    @Test
    func `sorts by event line`() throws {
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000)
        let url = try #require(URL(string: "https://example.com"))
        let one = Repository(
            id: "1",
            name: "One",
            owner: "me",
            sortOrder: nil,
            error: nil,
            rateLimitedUntil: nil,
            ciStatus: .unknown,
            openIssues: 0,
            openPulls: 0,
            latestRelease: nil,
            latestActivity: ActivityEvent(title: "B event", actor: "a", date: now, url: url),
            traffic: nil,
            heatmap: []
        )
        let two = Repository(
            id: "2",
            name: "Two",
            owner: "me",
            sortOrder: nil,
            error: nil,
            rateLimitedUntil: nil,
            ciStatus: .unknown,
            openIssues: 0,
            openPulls: 0,
            latestRelease: nil,
            latestActivity: ActivityEvent(title: "A event", actor: "a", date: now, url: url),
            traffic: nil,
            heatmap: []
        )

        let sorted = RepositorySort.sorted([one, two], sortKey: .event)
        #expect(sorted.first?.name == "Two")
    }

    @Test
    func `sorts by counts cover issues pulls stars`() {
        let base = Repository(
            id: "1",
            name: "A",
            owner: "me",
            sortOrder: nil,
            error: nil,
            rateLimitedUntil: nil,
            ciStatus: .unknown,
            openIssues: 0,
            openPulls: 0,
            stars: 0,
            forks: 0,
            pushedAt: nil,
            latestRelease: nil,
            latestActivity: nil,
            traffic: nil,
            heatmap: []
        )
        let moreIssues = base.withOrder(nil)
        var repoIssues = moreIssues
        repoIssues.openIssues = 10

        let morePulls = base.withOrder(nil)
        var repoPulls = morePulls
        repoPulls.openPulls = 9

        let moreStars = base.withOrder(nil)
        var repoStars = moreStars
        repoStars.stars = 99

        #expect(RepositorySort.sorted([base, repoIssues], sortKey: .issues).first?.openIssues == 10)
        #expect(RepositorySort.sorted([base, repoPulls], sortKey: .pulls).first?.openPulls == 9)
        #expect(RepositorySort.sorted([base, repoStars], sortKey: .stars).first?.stars == 99)
    }

    @Test
    func `tie break falls back to full name`() throws {
        let a = try Repository(
            id: "1",
            name: "A",
            owner: "me",
            sortOrder: nil,
            error: nil,
            rateLimitedUntil: nil,
            ciStatus: .unknown,
            openIssues: 0,
            openPulls: 0,
            stars: 0,
            forks: 0,
            pushedAt: nil,
            latestRelease: nil,
            latestActivity: ActivityEvent(
                title: "Same",
                actor: "me",
                date: Date(timeIntervalSinceReferenceDate: 1),
                url: #require(URL(string: "https://example.com"))
            ),
            traffic: nil,
            heatmap: []
        )
        let b = Repository(
            id: "2",
            name: "B",
            owner: "me",
            sortOrder: nil,
            error: nil,
            rateLimitedUntil: nil,
            ciStatus: .unknown,
            openIssues: 0,
            openPulls: 0,
            stars: 0,
            forks: 0,
            pushedAt: nil,
            latestRelease: nil,
            latestActivity: a.latestActivity,
            traffic: nil,
            heatmap: []
        )

        #expect(RepositorySort.isOrderedBefore(a, b, sortKey: .event) == true)
        #expect(RepositorySort.isOrderedBefore(a, b, sortKey: .name) == true)
    }

    @Test
    func `is ordered before same repo returns false`() {
        let repo = Repository(
            id: "1",
            name: "A",
            owner: "me",
            sortOrder: nil,
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
        #expect(RepositorySort.isOrderedBefore(repo, repo, sortKey: .activity) == false)
        #expect(RepositorySort.isOrderedBefore(repo, repo, sortKey: .event) == false)
    }
}
