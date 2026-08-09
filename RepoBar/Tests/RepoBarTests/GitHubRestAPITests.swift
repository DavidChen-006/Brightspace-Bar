import Foundation
@testable import RepoBarCore
import Testing

struct GitHubRestAPITests {
    @Test
    func `user repos query items include org and visibility`() {
        let items = GitHubRestAPI.userReposQueryItems()
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })

        #expect(items.count == 4)
        #expect(values["sort"] == "pushed")
        #expect(values["direction"] == "desc")
        #expect(values["affiliation"] == "owner,collaborator,organization_member")
        #expect(values["visibility"] == "all")
    }

    @Test
    func `repo not visible message mentions private org installation`() {
        let message = GitHubRestAPI.repoNotVisibleMessage(owner: "acme", name: "private-repo")

        #expect(message.contains("acme/private-repo"))
        #expect(message.contains("private organization repositories"))
        #expect(message.contains("RepoBar GitHub App"))
        #expect(message.contains("PAT"))
    }

    @Test
    func `open pull request count treats missing pulls endpoint as unknown`() throws {
        let url = try #require(URL(string: "https://api.github.com/repos/acme/docs/pulls"))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 404,
            httpVersion: nil,
            headerFields: nil
        ))

        let count = try GitHubRestAPI.openPullRequestCount(from: Data("{}".utf8), response: response)

        #expect(count == nil)
    }

    @Test
    func `latest release endpoint 404 means no stable release`() throws {
        let url = try #require(URL(string: "https://api.github.com/repos/acme/docs/releases/latest"))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 404,
            httpVersion: nil,
            headerFields: ["ETag": "\"missing-stable\""]
        ))

        let release = try GitHubRestAPI.latestRelease(from: Data(#"{"message":"Not Found"}"#.utf8), response: response)

        #expect(release == nil)
    }

    @Test
    func `latest release endpoint decodes published date`() throws {
        let url = try #require(URL(string: "https://api.github.com/repos/acme/docs/releases/latest"))
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let data = Data("""
        {
          "name": "Stable",
          "tag_name": "v1.0.0",
          "published_at": "2026-01-04T12:30:00Z",
          "created_at": "2026-01-01T00:00:00Z",
          "draft": false,
          "prerelease": false,
          "html_url": "https://github.com/acme/docs/releases/tag/v1.0.0"
        }
        """.utf8)

        let decoded = try GitHubRestAPI.latestRelease(from: data, response: response)
        let release = try #require(decoded)
        let expected = try iso8601Date("2026-01-04T12:30:00Z")

        #expect(release.tag == "v1.0.0")
        #expect(release.publishedAt == expected)
    }

    @Test
    func `latest release endpoint falls back to created date`() throws {
        let url = try #require(URL(string: "https://api.github.com/repos/acme/docs/releases/latest"))
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let data = Data("""
        {
          "name": "Stable",
          "tag_name": "v1.0.0",
          "published_at": null,
          "created_at": "2026-01-01T00:00:00Z",
          "draft": false,
          "prerelease": false,
          "html_url": "https://github.com/acme/docs/releases/tag/v1.0.0"
        }
        """.utf8)

        let decoded = try GitHubRestAPI.latestRelease(from: data, response: response)
        let release = try #require(decoded)
        let expected = try iso8601Date("2026-01-01T00:00:00Z")

        #expect(release.publishedAt == expected)
    }

    @Test
    func `self hosted runner urls request full pages`() throws {
        let baseURL = try #require(URL(string: "https://api.github.com"))
        let orgURL = GitHubRestAPI.selfHostedRunnersURL(baseURL: baseURL, owner: "acme", repo: nil, page: 2)
        let repoURL = GitHubRestAPI.selfHostedRunnersURL(baseURL: baseURL, owner: "acme", repo: "widget", page: 1)

        #expect(orgURL.path == "/orgs/acme/actions/runners")
        #expect(orgURL.query == "per_page=100&page=2")
        #expect(repoURL.path == "/repos/acme/widget/actions/runners")
        #expect(repoURL.query == "per_page=100&page=1")
    }

    @Test
    func `queued workflow status scan includes approval and concurrency waits`() {
        #expect(GitHubRestAPI.queuedWorkflowRunStatuses == ["queued", "waiting", "pending"])
    }

    @Test
    func `recent issue page keeps raw count while filtering pull requests`() throws {
        let data = Data("""
        [
          {
            "number": 10,
            "title": "PR shaped item",
            "html_url": "https://github.com/owner/repo/pull/10",
            "updated_at": "2026-05-03T16:10:00Z",
            "comments": 1,
            "user": {"login": "bot", "avatar_url": null},
            "labels": [],
            "assignees": [],
            "pull_request": {"url": "https://api.github.com/repos/owner/repo/pulls/10"}
          },
          {
            "number": 11,
            "title": "Actual issue",
            "html_url": "https://github.com/owner/repo/issues/11",
            "updated_at": "2026-05-03T16:11:00Z",
            "comments": 2,
            "user": {"login": "peter", "avatar_url": null},
            "labels": [{"name": "bug", "color": "d73a4a"}],
            "assignees": []
          }
        ]
        """.utf8)

        let page = try GitHubRecentDecoders.decodeRecentIssuePage(from: data)

        #expect(page.rawCount == 2)
        #expect(page.issues.map(\.number) == [11])
        #expect(page.issues.first?.title == "Actual issue")
    }

    @Test
    func `issue reference list item decodes repository object`() throws {
        let data = Data("""
        [
          {
            "number": 42,
            "title": "Subscribed fix",
            "body": "Useful details",
            "html_url": "https://github.com/acme/widget/pull/42",
            "repository": {"full_name": "acme/widget"},
            "state": "open",
            "created_at": "2026-05-03T16:00:00Z",
            "updated_at": "2026-05-03T16:11:00Z",
            "user": {"login": "peter"},
            "pull_request": {"url": "https://api.github.com/repos/acme/widget/pulls/42"}
          }
        ]
        """.utf8)

        let item = try #require(GitHubDecoding.decode([IssueReferenceSearchItem].self, from: data).first)
        let match = try #require(item.match())

        #expect(match.repositoryFullName == "acme/widget")
        #expect(match.query.displayText == "acme/widget#42")
        #expect(match.kind == .pullRequest)
        #expect(match.state == .open)
        #expect(match.authorLogin == "peter")
    }

    @Test
    func `issue reference search preserves merged pull request state`() throws {
        let data = Data("""
        [
          {
            "number": 43,
            "title": "Merged fix",
            "body": null,
            "html_url": "https://github.com/acme/widget/pull/43",
            "repository": {"full_name": "acme/widget"},
            "state": "closed",
            "created_at": "2026-05-03T16:00:00Z",
            "updated_at": "2026-05-03T16:11:00Z",
            "user": {"login": "peter"},
            "pull_request": {
              "url": "https://api.github.com/repos/acme/widget/pulls/43",
              "merged_at": "2026-05-03T16:10:00Z"
            }
          }
        ]
        """.utf8)

        let item = try #require(GitHubDecoding.decode([IssueReferenceSearchItem].self, from: data).first)
        let match = try #require(item.match())

        #expect(match.kind == .pullRequest)
        #expect(match.state == .merged)
    }
}

private func iso8601Date(_ raw: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: raw))
}
