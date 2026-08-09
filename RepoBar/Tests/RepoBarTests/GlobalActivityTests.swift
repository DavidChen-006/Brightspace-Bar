import Foundation
@testable import RepoBarCore
import Testing

struct GlobalActivityTests {
    @Test
    func `repo event activity event from repo builds event`() throws {
        let data = Data("""
        {
          "type": "PushEvent",
          "actor": { "login": "steipete", "avatar_url": "https://example.com/avatar.png" },
          "repo": { "name": "steipete/RepoBar", "url": "https://api.github.com/repos/steipete/RepoBar" },
          "payload": { "head": "abc123" },
          "created_at": "2024-01-01T00:00:00Z"
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(RepoEvent.self, from: data)
        let webHost = try #require(URL(string: "https://github.com"))

        let activity = event.activityEventFromRepo(webHost: webHost)

        #expect(activity != nil)
        #expect(activity?.actor == "steipete")
        #expect(activity?.eventType == "PushEvent")
        #expect(activity?.url.absoluteString.contains("https://github.com/steipete/RepoBar/commit/abc123") == true)
    }

    @Test
    func `repo event activity event from repo falls back to repo URL`() throws {
        let data = Data("""
        {
          "type": "PushEvent",
          "actor": { "login": "steipete", "avatar_url": "https://example.com/avatar.png" },
          "repo": { "name": "RepoBar", "url": "https://api.github.com/repos/steipete/RepoBar" },
          "payload": { "head": "abc123" },
          "created_at": "2024-01-01T00:00:00Z"
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(RepoEvent.self, from: data)
        let webHost = try #require(URL(string: "https://github.com"))

        let activity = event.activityEventFromRepo(webHost: webHost)

        #expect(activity != nil)
        #expect(activity?.url.absoluteString.contains("https://github.com/steipete/RepoBar/commit/abc123") == true)
    }

    @Test
    func `commit summaries use enterprise host`() throws {
        let data = Data("""
        {
          "type": "PushEvent",
          "actor": { "login": "steipete", "avatar_url": "https://example.com/avatar.png" },
          "repo": { "name": "acme/Widgets", "url": "https://ghe.example.com/api/v3/repos/acme/Widgets" },
          "payload": {
            "commits": [
              {
                "sha": "def456",
                "message": "Ship it",
                "author": { "name": "Octo" },
                "timestamp": "2024-01-02T00:00:00Z"
              }
            ]
          },
          "created_at": "2024-01-02T00:00:00Z"
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(RepoEvent.self, from: data)
        let webHost = try #require(URL(string: "https://ghe.example.com"))

        let commits = event.commitSummaries(webHost: webHost)

        #expect(commits.count == 1)
        #expect(commits.first?.url.absoluteString == "https://ghe.example.com/acme/Widgets/commit/def456")
    }

    @Test
    func `global activity scope labels`() {
        #expect(GlobalActivityScope.allActivity.label == "All activity")
        #expect(GlobalActivityScope.myActivity.label == "My activity")
    }

    @Test
    func `repository events include latest activity fallback`() throws {
        let url = try #require(URL(string: "https://github.com/steipete/RepoBar/commit/abc"))
        let latest = ActivityEvent(
            title: "Push",
            actor: "steipete",
            date: Date(timeIntervalSinceReferenceDate: 100),
            url: url,
            eventType: "PushEvent"
        )
        let repo = Repository(
            id: "1",
            name: "RepoBar",
            owner: "steipete",
            sortOrder: nil,
            error: nil,
            rateLimitedUntil: nil,
            ciStatus: .unknown,
            openIssues: 0,
            openPulls: 0,
            latestRelease: nil,
            latestActivity: latest,
            activityEvents: [],
            traffic: nil,
            heatmap: []
        )

        let events = GlobalActivityMerger.repositoryEvents(from: [repo])

        #expect(events == [latest])
    }

    @Test
    func `repo activity snapshot sorts events by date before limiting`() throws {
        let older = RepoEvent(
            type: "PullRequestEvent",
            actor: EventActor(login: "octo", avatarUrl: nil),
            repo: nil,
            payload: EventPayload(
                action: "closed",
                comment: nil,
                issue: nil,
                pullRequest: EventPullRequest(title: nil, number: 1, merged: false, htmlUrl: nil)
            ),
            createdAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let newer = RepoEvent(
            type: "PullRequestEvent",
            actor: EventActor(login: "bot", avatarUrl: nil),
            repo: nil,
            payload: EventPayload(
                action: "labeled",
                comment: nil,
                issue: nil,
                pullRequest: EventPullRequest(title: nil, number: 2, merged: false, htmlUrl: nil)
            ),
            createdAt: Date(timeIntervalSinceReferenceDate: 200)
        )
        let webHost = try #require(URL(string: "https://github.com"))

        let snapshot = GitHubRestAPI.activitySnapshot(
            from: [older, newer],
            owner: "steipete",
            name: "RepoBar",
            webHost: webHost,
            limit: 2
        )

        #expect(snapshot.events.map(\.actor) == ["bot", "octo"])
        #expect(snapshot.latest?.actor == "bot")
    }

    @Test
    func `cached repo activity snapshot sorts events and recomputes latest`() throws {
        let url = try #require(URL(string: "https://github.com/steipete/RepoBar"))
        let older = ActivityEvent(
            title: "old",
            actor: "octo",
            date: Date(timeIntervalSinceReferenceDate: 100),
            url: url,
            eventType: "PullRequestEvent"
        )
        let newer = ActivityEvent(
            title: "new",
            actor: "bot",
            date: Date(timeIntervalSinceReferenceDate: 200),
            url: url,
            eventType: "PullRequestEvent"
        )

        let snapshot = RepoDetailCoordinator.cachedActivitySnapshot(latest: older, events: [older, newer])

        #expect(snapshot.events.map(\.actor) == ["bot", "octo"])
        #expect(snapshot.latest == newer)
    }

    @Test
    func `global activity merge dedupes and keeps newest actor scoped events`() throws {
        let firstURL = try #require(URL(string: "https://github.com/steipete/RepoBar/commit/abc"))
        let secondURL = try #require(URL(string: "https://github.com/steipete/RepoBar/pull/1"))
        let first = ActivityEvent(title: "Push", actor: "steipete", date: Date(timeIntervalSinceReferenceDate: 100), url: firstURL)
        let second = ActivityEvent(title: "Pull Request", actor: "steipete", date: Date(timeIntervalSinceReferenceDate: 200), url: secondURL)
        let other = ActivityEvent(title: "Push", actor: "bot", date: Date(timeIntervalSinceReferenceDate: 300), url: firstURL)

        let events = GlobalActivityMerger.merge(
            userEvents: [first],
            repoEvents: [other, second, first],
            scope: .myActivity,
            username: "steipete",
            limit: 10
        )

        #expect(events == [second, first])
    }
}
