import Foundation
@testable import RepoBar
@testable import RepoBarCore
import Testing

struct PATAuthenticatorTests {
    @Test
    @MainActor
    func `validate PAT success`() async throws {
        let service = "com.steipete.repobar.auth.tests.\(UUID().uuidString)"
        let store = TokenStore(service: service)
        defer { store.clear() }

        let session = URLSession(configuration: Self.sessionConfiguration())
        let handlerID = UUID().uuidString
        Self.MockURLProtocol.register(handlerID: handlerID) { request in
            #expect(request.url?.path == "/user")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_testtoken")

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = Data("""
            {"login":"testuser"}
            """.utf8)
            return (data, response)
        }
        defer { Self.MockURLProtocol.unregister(handlerID: handlerID) }

        let authenticator = PATAuthenticator(
            tokenStore: store,
            session: Self.taggedSession(session, handlerID: handlerID)
        )

        let user = try await authenticator.authenticate(
            pat: "ghp_testtoken",
            host: #require(URL(string: "https://github.com"))
        )

        #expect(user.username == "testuser")
        #expect(user.host.absoluteString == "https://github.com")
        #expect(try store.loadPAT() == "ghp_testtoken")
    }

    @Test
    @MainActor
    func `validate PAT invalid token`() async throws {
        let service = "com.steipete.repobar.auth.tests.\(UUID().uuidString)"
        let store = TokenStore(service: service)
        defer { store.clear() }

        let session = URLSession(configuration: Self.sessionConfiguration())
        let handlerID = UUID().uuidString
        Self.MockURLProtocol.register(handlerID: handlerID) { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }
        defer { Self.MockURLProtocol.unregister(handlerID: handlerID) }

        let authenticator = PATAuthenticator(
            tokenStore: store,
            session: Self.taggedSession(session, handlerID: handlerID)
        )

        do {
            _ = try await authenticator.authenticate(
                pat: "invalid_token",
                host: #require(URL(string: "https://github.com"))
            )
            Issue.record("Expected invalidToken error")
        } catch let error as PATAuthError {
            guard case .invalidToken = error else {
                Issue.record("Expected PATAuthError.invalidToken, got \(error)")
                return
            }
        }

        #expect(try store.loadPAT() == nil)
    }

    @Test
    @MainActor
    func `validate PAT forbidden`() async throws {
        let service = "com.steipete.repobar.auth.tests.\(UUID().uuidString)"
        let store = TokenStore(service: service)
        defer { store.clear() }

        let session = URLSession(configuration: Self.sessionConfiguration())
        let handlerID = UUID().uuidString
        Self.MockURLProtocol.register(handlerID: handlerID) { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }
        defer { Self.MockURLProtocol.unregister(handlerID: handlerID) }

        let authenticator = PATAuthenticator(
            tokenStore: store,
            session: Self.taggedSession(session, handlerID: handlerID)
        )

        do {
            _ = try await authenticator.authenticate(
                pat: "token_without_scopes",
                host: #require(URL(string: "https://github.com"))
            )
            Issue.record("Expected forbidden error")
        } catch let error as PATAuthError {
            guard case .forbidden = error else {
                Issue.record("Expected PATAuthError.forbidden, got \(error)")
                return
            }
        }

        #expect(try store.loadPAT() == nil)
    }

    @Test
    @MainActor
    func `logout clears PAT`() async throws {
        let service = "com.steipete.repobar.auth.tests.\(UUID().uuidString)"
        let store = TokenStore(service: service)
        defer { store.clear() }

        try store.savePAT("ghp_testtoken")

        let authenticator = PATAuthenticator(tokenStore: store)

        // Load the PAT first
        let loadedBefore = authenticator.loadPAT()
        #expect(loadedBefore == "ghp_testtoken")

        await authenticator.logout()

        let loadedAfter = authenticator.loadPAT()
        #expect(loadedAfter == nil)
    }

    @Test
    @MainActor
    func `load PAT returns nil when not stored`() {
        let service = "com.steipete.repobar.auth.tests.\(UUID().uuidString)"
        let store = TokenStore(service: service)
        defer { store.clear() }

        let authenticator = PATAuthenticator(tokenStore: store)

        let loaded = authenticator.loadPAT()
        #expect(loaded == nil)
    }

    @Test
    @MainActor
    func `enterprise host uses API path`() async throws {
        let service = "com.steipete.repobar.auth.tests.\(UUID().uuidString)"
        let store = TokenStore(service: service)
        defer { store.clear() }

        let session = URLSession(configuration: Self.sessionConfiguration())
        let handlerID = UUID().uuidString
        Self.MockURLProtocol.register(handlerID: handlerID) { request in
            // Enterprise should use /api/v3/user path
            #expect(request.url?.path == "/api/v3/user")

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = Data("""
            {"login":"enterpriseuser"}
            """.utf8)
            return (data, response)
        }
        defer { Self.MockURLProtocol.unregister(handlerID: handlerID) }

        let authenticator = PATAuthenticator(
            tokenStore: store,
            session: Self.taggedSession(session, handlerID: handlerID)
        )

        let user = try await authenticator.authenticate(
            pat: "ghp_enterprisetoken",
            host: #require(URL(string: "https://ghe.example.com"))
        )

        #expect(user.username == "enterpriseuser")
    }
}

private extension PATAuthenticatorTests {
    static func sessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return config
    }

    static func taggedSession(_: URLSession, handlerID: String) -> URLSession {
        // Create a new session with the handler ID embedded
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.httpAdditionalHeaders = ["X-Handler-ID": handlerID]
        return URLSession(configuration: config)
    }

    // swiftlint:disable static_over_final_class
    final class MockURLProtocol: URLProtocol {
        private static let handlersLock = NSLock()
        private nonisolated(unsafe) static var handlers: [String: @Sendable (URLRequest) throws -> (Data, URLResponse)] = [:]

        static func register(
            handlerID: String,
            handler: @escaping @Sendable (URLRequest) throws -> (Data, URLResponse)
        ) {
            self.handlersLock.lock()
            self.handlers[handlerID] = handler
            self.handlersLock.unlock()
        }

        static func unregister(handlerID: String) {
            self.handlersLock.lock()
            self.handlers[handlerID] = nil
            self.handlersLock.unlock()
        }

        override class func canInit(with request: URLRequest) -> Bool {
            request.value(forHTTPHeaderField: "X-Handler-ID") != nil
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard
                let handlerID = request.value(forHTTPHeaderField: "X-Handler-ID"),
                let handler = Self.handler(for: handlerID)
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }

            do {
                let (data, response) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}

        private static func handler(for handlerID: String) -> (@Sendable (URLRequest) throws -> (Data, URLResponse))? {
            self.handlersLock.lock()
            defer { handlersLock.unlock() }
            return self.handlers[handlerID]
        }
    }
    // swiftlint:enable static_over_final_class
}
