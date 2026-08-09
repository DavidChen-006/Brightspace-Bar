import Foundation
@testable import RepoBarCore
import Testing

struct RepositoryFactoryTests {
    @Test
    func `from maps repo item fields`() throws {
        let json = """
        {
          "id": 42,
          "name": "RepoBar",
          "full_name": "steipete/RepoBar",
          "description": "A macOS GitHub menu bar app",
          "language": "Swift",
          "topics": ["macos", "github"],
          "fork": true,
          "archived": true,
          "open_issues_count": 7,
          "stargazers_count": 99,
          "forks_count": 12,
          "pushed_at": "2025-01-01T00:00:00Z",
          "permissions": { "admin": false, "maintain": true, "push": false, "pull": true },
          "owner": { "login": "steipete" }
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let item = try decoder.decode(RepoItem.self, from: Data(json.utf8))

        let repo = try Repository.from(
            item: item,
            openPulls: 3,
            issues: 5,
            ciStatus: .passing,
            ciRunCount: 11,
            latestRelease: Release(name: "v1", tag: "v1.0", publishedAt: Date(), url: #require(URL(string: "https://example.com"))),
            latestActivity: ActivityEvent(title: "t", actor: "a", date: Date(), url: #require(URL(string: "https://example.com"))),
            activityEvents: [],
            traffic: TrafficStats(uniqueVisitors: 1, uniqueCloners: 2),
            heatmap: [HeatmapCell(date: Date(), count: 4)],
            error: "err",
            rateLimitedUntil: Date(timeIntervalSinceReferenceDate: 123),
            detailCacheState: nil
        )

        #expect(repo.id == "42")
        #expect(repo.name == "RepoBar")
        #expect(repo.owner == "steipete")
        #expect(repo.description == "A macOS GitHub menu bar app")
        #expect(repo.language == "Swift")
        #expect(repo.topics == ["macos", "github"])
        #expect(repo.isFork == true)
        #expect(repo.isArchived == true)
        #expect(repo.viewerCanRead == true)
        #expect(repo.openIssues == 5)
        #expect(repo.openPulls == 3)
        #expect(repo.stars == 99)
        #expect(repo.forks == 12)
        #expect(repo.ciStatus == .passing)
        #expect(repo.ciRunCount == 11)
        #expect(repo.error == "err")
        #expect(repo.rateLimitedUntil == Date(timeIntervalSinceReferenceDate: 123))
        #expect(repo.traffic == TrafficStats(uniqueVisitors: 1, uniqueCloners: 2))
        #expect(repo.heatmap.count == 1)
    }

    @Test
    func `placeholder builds minimal repo`() {
        let limitedUntil = Date(timeIntervalSinceReferenceDate: 999)
        let repo = Repository.placeholder(owner: "me", name: "Repo", error: "oops", rateLimitedUntil: limitedUntil)

        #expect(repo.id == "me/Repo")
        #expect(repo.fullName == "me/Repo")
        #expect(repo.error == "oops")
        #expect(repo.rateLimitedUntil == limitedUntil)
        #expect(repo.openIssues == 0)
        #expect(repo.openPulls == 0)
        #expect(repo.stars == 0)
        #expect(repo.forks == 0)
        #expect(repo.heatmap.isEmpty)
    }
}
