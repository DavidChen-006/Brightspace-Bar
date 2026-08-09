import Foundation
@testable import RepoBarCore
import Testing

struct GitHubRequestRunnerTests {
    @Test
    func `injected transport reuses cached body for not modified response`() async throws {
        let url = try #require(URL(string: "https://api.github.com/repos/owner/repo/releases"))
        let transport = StubHTTPTransport(responses: [
            Self.response(url: url, status: 200, headers: ["ETag": "\"release-v1\""], body: "cached-body"),
            Self.response(url: url, status: 304, body: "")
        ])
        let runner = GitHubRequestRunner(
            etagCache: ETagCache(),
            dataLoader: HTTPDataLoader { request in
                try await transport.data(for: request)
            }
        )

        let first = try await runner.get(url: url, token: "token")
        let second = try await runner.get(url: url, token: "token")
        let requests = await transport.requests

        #expect(String(data: first.0, encoding: .utf8) == "cached-body")
        #expect(String(data: second.0, encoding: .utf8) == "cached-body")
        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(requests[1].value(forHTTPHeaderField: "If-None-Match") == "\"release-v1\"")
    }

    @Test
    func `injected transport records stats cooldown`() async throws {
        let url = try #require(URL(string: "https://api.github.com/repos/owner/repo/stats/commit_activity"))
        let transport = StubHTTPTransport(responses: [
            Self.response(url: url, status: 202, headers: ["Retry-After": "120"], body: "")
        ])
        let runner = GitHubRequestRunner(
            etagCache: ETagCache(),
            dataLoader: HTTPDataLoader { request in
                try await transport.data(for: request)
            }
        )

        do {
            _ = try await runner.get(url: url, token: "token")
            Issue.record("Expected service unavailable error")
        } catch let error as GitHubAPIError {
            guard case let .serviceUnavailable(retryAfter, message) = error else {
                Issue.record("Expected serviceUnavailable, got \(error)")
                return
            }

            #expect(retryAfter != nil)
            #expect(message.contains("generating repository stats"))
        }

        let diagnostics = await runner.diagnosticsSnapshot()
        #expect(diagnostics.endpointCooldowns.first?.endpoint == "commit activity")
    }

    @Test
    func `injected transport distinguishes permission failure from rate limit`() async throws {
        let permissionURL = try #require(URL(string: "https://api.github.com/repos/owner/repo/traffic/views"))
        let limitedURL = try #require(URL(string: "https://api.github.com/repos/owner/repo/issues"))
        let reset = Int(Date().addingTimeInterval(300).timeIntervalSince1970)
        let transport = StubHTTPTransport(responses: [
            Self.response(
                url: permissionURL,
                status: 403,
                headers: ["X-RateLimit-Remaining": "42"],
                body: #"{"message":"Resource not accessible"}"#
            ),
            Self.response(
                url: limitedURL,
                status: 403,
                headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "\(reset)"],
                body: #"{"message":"API rate limit exceeded"}"#
            )
        ])
        let runner = GitHubRequestRunner(
            etagCache: ETagCache(),
            dataLoader: HTTPDataLoader { request in
                try await transport.data(for: request)
            }
        )

        do {
            _ = try await runner.get(url: permissionURL, token: "token")
            Issue.record("Expected permission failure")
        } catch let GitHubAPIError.badStatus(code, message) {
            #expect(code == 403)
            #expect(message?.contains("Resource not accessible") == true)
        }

        do {
            _ = try await runner.get(url: limitedURL, token: "token")
            Issue.record("Expected rate limit failure")
        } catch let GitHubAPIError.rateLimited(_, message) {
            #expect(message.contains("rate limit"))
        }
    }

    @Test
    func `etag requests bypass URLSession local cache`() throws {
        let url = try #require(URL(string: "https://api.github.com/repos/owner/repo/releases"))

        let request = GitHubRequestRunner.makeRequest(url: url, token: "token", useETag: true)
        let uncachedRequest = GitHubRequestRunner.makeRequest(url: url, token: "token", useETag: false)

        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(uncachedRequest.cachePolicy == .useProtocolCachePolicy)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
    }

    @Test
    func `etag body cache stores only successful responses`() {
        #expect(GitHubRequestRunner.shouldCacheETagResponse(statusCode: 200))
        #expect(GitHubRequestRunner.shouldCacheETagResponse(statusCode: 304) == false)
        #expect(GitHubRequestRunner.shouldCacheETagResponse(statusCode: 404) == false)
    }

    @Test
    func `cooldown message names endpoint`() async throws {
        let url = try #require(URL(string: "https://api.github.com/repos/owner/repo/stats/commit_activity"))
        let backoff = BackoffTracker()
        let retryAfter = Date().addingTimeInterval(30)
        await backoff.setCooldown(url: url, until: retryAfter)
        let runner = GitHubRequestRunner(etagCache: ETagCache(), backoff: backoff)

        do {
            _ = try await runner.get(url: url, token: "token")
            Issue.record("Expected cooldown error")
        } catch let error as GitHubAPIError {
            #expect(error.displayMessage.hasPrefix("GitHub endpoint cooldown (commit activity); retry in "))
            #expect(error.displayMessage.contains("until in") == false)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `cooldown message identifies actions endpoint`() throws {
        let url = try #require(URL(string: "https://api.github.com/repos/owner/repo/actions/runs?per_page=20"))
        let retryAfter = Date(timeIntervalSinceReferenceDate: 60)
        let now = Date(timeIntervalSinceReferenceDate: 30)

        let message = GitHubRequestRunner.cooldownMessage(for: url, until: retryAfter, now: now)

        #expect(message == "GitHub endpoint cooldown (Actions runs); retry in 30 sec.")
    }

    @Test
    func `bad status message includes GitHub response detail`() {
        let data = Data("""
        {
          "message": "Validation Failed",
          "errors": [
            { "resource": "Search", "field": "q", "code": "invalid", "message": "Search query is too broad." }
          ]
        }
        """.utf8)

        let message = GitHubRequestRunner.statusMessage(for: 422, data: data)

        #expect(message == "GitHub returned 422: Validation Failed: Search query is too broad.")
    }

    @Test
    func `bad status message keeps fallback for non github body`() {
        let data = Data("nope".utf8)

        let message = GitHubRequestRunner.statusMessage(for: 422, data: data)

        #expect(message == "GitHub returned 422: client error.")
    }

    @Test
    func `diagnostics expose endpoint cooldowns`() async throws {
        let url = try #require(URL(string: "https://api.github.com/repos/owner/repo/stats/commit_activity"))
        let backoff = BackoffTracker()
        let retryAfter = Date().addingTimeInterval(30)
        await backoff.setCooldown(url: url, until: retryAfter)
        let runner = GitHubRequestRunner(backoff: backoff)

        let diagnostics = await runner.diagnosticsSnapshot()

        #expect(diagnostics.backoffEntries == 1)
        #expect(diagnostics.endpointCooldowns.count == 1)
        #expect(diagnostics.endpointCooldowns.first?.endpoint == "commit activity")
        #expect(diagnostics.endpointCooldowns.first?.repository == "owner/repo")
    }

    @Test
    func `log path redacts query values`() throws {
        let url = try #require(URL(string: "https://api.github.com/search/issues?q=repo:owner/private+secret&per_page=50"))

        let path = GitHubRequestRunner.logPath(for: url)

        #expect(path == "/search/issues?q=<redacted>&per_page=<redacted>")
        #expect(path.contains("owner/private") == false)
        #expect(path.contains("secret") == false)
    }

    private static func response(
        url: URL,
        status: Int,
        headers: [String: String] = [:],
        body: String
    ) -> StubHTTPTransport.Response {
        StubHTTPTransport.Response(
            data: Data(body.utf8),
            response: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        )
    }
}

private actor StubHTTPTransport {
    struct Response {
        let data: Data
        let response: HTTPURLResponse
    }

    private var pendingResponses: [Response]
    private(set) var requests: [URLRequest] = []

    init(responses: [Response]) {
        self.pendingResponses = responses
    }

    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        self.requests.append(request)
        guard self.pendingResponses.isEmpty == false else {
            throw URLError(.badServerResponse)
        }

        let response = self.pendingResponses.removeFirst()
        return (response.data, response.response)
    }
}
