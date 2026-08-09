import Foundation
@testable import RepoBarCore
import Testing

struct GraphQLRepoSummaryParsingTests {
    @Test
    func `repo summary uses latest stable release field`() throws {
        let data = Data("""
        {
          "data": {
            "repository": {
              "latestRelease": {
                "name": "Published Later",
                "tagName": "v2.0.0",
                "publishedAt": "2026-01-04T00:00:00Z",
                "createdAt": "2026-01-01T00:00:00Z",
                "url": "https://example.com/v2",
                "isDraft": false,
                "isPrerelease": false,
                "isLatest": true
              },
              "releases": {
                "nodes": [
                  {
                    "name": "Draft",
                    "tagName": "v3.0.0",
                    "publishedAt": null,
                    "createdAt": "2026-01-03T00:00:00Z",
                    "url": "https://example.com/v3",
                    "isDraft": true,
                    "isPrerelease": false,
                    "isLatest": false
                  },
                  {
                    "name": "Prerelease",
                    "tagName": "v2.1.0-beta",
                    "publishedAt": "2026-01-05T00:00:00Z",
                    "createdAt": "2026-01-05T00:00:00Z",
                    "url": "https://example.com/v2-beta",
                    "isDraft": false,
                    "isPrerelease": true,
                    "isLatest": false
                  },
                  {
                    "name": "Created Later",
                    "tagName": "v2.0.0-created",
                    "publishedAt": "2026-01-02T00:00:00Z",
                    "createdAt": "2026-01-02T00:00:00Z",
                    "url": "https://example.com/v2-created",
                    "isDraft": false,
                    "isPrerelease": false,
                    "isLatest": false
                  },
                  {
                    "name": "Published Later",
                    "tagName": "v2.0.0",
                    "publishedAt": "2026-01-04T00:00:00Z",
                    "createdAt": "2026-01-01T00:00:00Z",
                    "url": "https://example.com/v2",
                    "isDraft": false,
                    "isPrerelease": false,
                    "isLatest": true
                  },
                  {
                    "name": "Old",
                    "tagName": "v1.0.0",
                    "publishedAt": "2026-01-01T00:00:00Z",
                    "createdAt": "2026-01-01T00:00:00Z",
                    "url": "https://example.com/v1",
                    "isDraft": false,
                    "isPrerelease": false,
                    "isLatest": false
                  }
                ]
              },
              "issues": { "totalCount": 4 },
              "pullRequests": { "totalCount": 2 }
            }
          }
        }
        """.utf8)

        let summary = try GraphQLClient.decodeRepoSummary(from: data, owner: "owner", name: "repo")

        #expect(summary.openIssues == 4)
        #expect(summary.openPulls == 2)
        #expect(summary.release?.tag == "v2.0.0")
        let expectedDate = try graphQLSummaryISO8601Date("2026-01-04T00:00:00Z")
        #expect(summary.release?.publishedAt == expectedDate)
    }

    @Test
    func `repo summary is not bounded by newer prerelease nodes`() throws {
        let prereleases = (0 ..< 25)
            .map { index in
                """
                {
                  "name": "Prerelease \(index)",
                  "tagName": "v2.0.0-beta.\(index)",
                  "publishedAt": "2026-02-\(String(format: "%02d", index % 20 + 1))T00:00:00Z",
                  "createdAt": "2026-02-\(String(format: "%02d", index % 20 + 1))T00:00:00Z",
                  "url": "https://example.com/v2-beta-\(index)",
                  "isDraft": false,
                  "isPrerelease": true,
                  "isLatest": false
                }
                """
            }
            .joined(separator: ",")

        let data = Data("""
        {
          "data": {
            "repository": {
              "latestRelease": {
                "name": "Stable",
                "tagName": "v1.0.0",
                "publishedAt": "2026-01-01T00:00:00Z",
                "createdAt": "2026-01-01T00:00:00Z",
                "url": "https://example.com/v1",
                "isDraft": false,
                "isPrerelease": false,
                "isLatest": true
              },
              "releases": { "nodes": [\(prereleases)] },
              "issues": { "totalCount": 4 },
              "pullRequests": { "totalCount": 2 }
            }
          }
        }
        """.utf8)

        let summary = try GraphQLClient.decodeRepoSummary(from: data, owner: "owner", name: "repo")

        #expect(summary.release?.tag == "v1.0.0")
    }

    @Test
    func `repo summary preserves repositories with no stable release`() throws {
        let data = Data("""
        {
          "data": {
            "repository": {
              "latestRelease": null,
              "issues": { "totalCount": 4 },
              "pullRequests": { "totalCount": 2 }
            }
          }
        }
        """.utf8)

        let summary = try GraphQLClient.decodeRepoSummary(from: data, owner: "owner", name: "repo")

        #expect(summary.openIssues == 4)
        #expect(summary.openPulls == 2)
        #expect(summary.release == nil)
    }
}

private func graphQLSummaryISO8601Date(_ raw: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: raw))
}
