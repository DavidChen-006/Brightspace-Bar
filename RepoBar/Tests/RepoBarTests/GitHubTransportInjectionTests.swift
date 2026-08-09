import Foundation
@testable import RepoBarCore
import Testing

struct GitHubTransportInjectionTests {
    @Test
    func `graphql configuration reaches injected transport before request`() async throws {
        let transport = RecordingHTTPTransport { request in
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
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
        let client = GraphQLClient(
            responseCache: nil,
            dataLoader: HTTPDataLoader { request in
                try await transport.data(for: request)
            }
        )
        try await client.setEndpoint(apiHost: #require(URL(string: "https://ghe.example.com/api/v3")))
        await client.setTokenProvider { "account-token" }

        let summary = try await client.repoSummary(owner: "owner", name: "repo")
        let requests = await transport.requests
        let request = try #require(requests.first)

        #expect(summary.openIssues == 4)
        #expect(summary.openPulls == 2)
        #expect(request.url?.absoluteString == "https://ghe.example.com/api/graphql")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "bearer account-token")
        #expect(request.httpMethod == "POST")
    }

    @Test
    func `unauthenticated reference lookup uses injected transport`() async throws {
        let transport = RecordingHTTPTransport { request in
            let data = Data("""
            {
              "title": "Injected lookup",
              "body": "Body",
              "html_url": "https://github.com/owner/repo/issues/42",
              "state": "open",
              "created_at": "2026-01-01T00:00:00Z",
              "updated_at": "2026-01-02T00:00:00Z",
              "user": { "login": "alice" }
            }
            """.utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
        let api = GitHubRestAPI(
            apiHost: { URL(string: "https://api.github.com")! },
            tokenProvider: { "" },
            requestRunner: GitHubRequestRunner(etagCache: ETagCache()),
            diag: .shared,
            responseDiskCache: nil,
            dataLoader: HTTPDataLoader { request in
                try await transport.data(for: request)
            }
        )
        let query = GitHubReferenceQuery.repositoryIssueNumber(
            repositoryFullName: "owner/repo",
            number: 42
        )

        let match = await api.liveReferenceMatch(query: query)
        let requests = await transport.requests
        let request = try #require(requests.first)

        #expect(match?.title == "Injected lookup")
        #expect(match?.repositoryFullName == "owner/repo")
        #expect(request.url?.path == "/repos/owner/repo/issues/42")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "RepoBar")
    }
}

private actor RecordingHTTPTransport {
    typealias Handler = @Sendable (URLRequest) throws -> (Data, URLResponse)

    private let handler: Handler
    private(set) var requests: [URLRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        self.requests.append(request)
        return try self.handler(request)
    }
}
