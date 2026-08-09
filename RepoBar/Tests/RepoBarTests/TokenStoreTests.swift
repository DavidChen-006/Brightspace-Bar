import Foundation
@testable import RepoBarCore
import Testing

struct TokenStoreTests {
    @Test
    func `debug default storage does not use keychain`() throws {
        let service = "com.steipete.repobar.auth.tests.\(UUID().uuidString)"
        let store = TokenStore(service: service, accessGroup: "com.steipete.repobar.shared")
        defer { store.clear() }

        let tokens = OAuthTokens(
            accessToken: "token-\(UUID().uuidString)",
            refreshToken: "refresh-\(UUID().uuidString)",
            expiresAt: Date().addingTimeInterval(3600)
        )

        try store.save(tokens: tokens)
        let loaded = try store.load()
        #expect(loaded == tokens)
    }

    @Test
    func `file storage does not use keychain`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("repobar-token-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = "com.steipete.repobar.auth.tests.\(UUID().uuidString)"
        let store = TokenStore(service: service, storage: .file(directory))
        let tokens = OAuthTokens(
            accessToken: "debug-token",
            refreshToken: "debug-refresh",
            expiresAt: Date().addingTimeInterval(60)
        )

        try store.save(tokens: tokens)
        #expect(try store.load() == tokens)

        store.clear()
        #expect(try store.load() == nil)
    }

    // MARK: - Phase 1: Account-Scoped APIs (file storage)

    @Test
    func `file storage round trips account scoped oauth tokens`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("repobar-token-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TokenStore(
            service: "com.steipete.repobar.auth.tests.\(UUID().uuidString)",
            storage: .file(directory)
        )

        let tokensA = OAuthTokens(accessToken: "atok-a", refreshToken: "rtok-a", expiresAt: nil)
        let tokensB = OAuthTokens(accessToken: "atok-b", refreshToken: "rtok-b", expiresAt: nil)

        try store.save(tokens: tokensA, accountID: "alpha")
        try store.save(tokens: tokensB, accountID: "beta")

        #expect(try store.loadTokens(accountID: "alpha") == tokensA)
        #expect(try store.loadTokens(accountID: "beta") == tokensB)
        #expect(try store.loadTokens(accountID: "missing") == nil)
    }

    @Test
    func `file storage round trips account scoped client credentials`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("repobar-token-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TokenStore(
            service: "com.steipete.repobar.auth.tests.\(UUID().uuidString)",
            storage: .file(directory)
        )

        let credsA = OAuthClientCredentials(clientID: "cid-a", clientSecret: "sec-a")
        let credsB = OAuthClientCredentials(clientID: "cid-b", clientSecret: "sec-b")

        try store.save(clientCredentials: credsA, accountID: "alpha")
        try store.save(clientCredentials: credsB, accountID: "beta")

        #expect(try store.loadClientCredentials(accountID: "alpha") == credsA)
        #expect(try store.loadClientCredentials(accountID: "beta") == credsB)
        #expect(try store.loadClientCredentials(accountID: "missing") == nil)
    }

    @Test
    func `file storage round trips account scoped PAT`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("repobar-token-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TokenStore(
            service: "com.steipete.repobar.auth.tests.\(UUID().uuidString)",
            storage: .file(directory)
        )

        try store.savePAT("ghp_alpha", accountID: "alpha")
        try store.savePAT("ghp_beta", accountID: "beta")

        #expect(try store.loadPAT(accountID: "alpha") == "ghp_alpha")
        #expect(try store.loadPAT(accountID: "beta") == "ghp_beta")
        #expect(try store.loadPAT(accountID: "missing") == nil)
    }

    @Test
    func `file storage clear by accountID removes only that account`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("repobar-token-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TokenStore(
            service: "com.steipete.repobar.auth.tests.\(UUID().uuidString)",
            storage: .file(directory)
        )

        let tokensA = OAuthTokens(accessToken: "atok-a", refreshToken: "rtok-a", expiresAt: nil)
        let tokensB = OAuthTokens(accessToken: "atok-b", refreshToken: "rtok-b", expiresAt: nil)
        let credsA = OAuthClientCredentials(clientID: "cid-a", clientSecret: "sec-a")

        try store.save(tokens: tokensA, accountID: "alpha")
        try store.save(clientCredentials: credsA, accountID: "alpha")
        try store.savePAT("ghp_alpha", accountID: "alpha")
        try store.save(tokens: tokensB, accountID: "beta")

        store.clear(accountID: "alpha")

        #expect(try store.loadTokens(accountID: "alpha") == nil)
        #expect(try store.loadClientCredentials(accountID: "alpha") == nil)
        #expect(try store.loadPAT(accountID: "alpha") == nil)
        #expect(try store.loadTokens(accountID: "beta") == tokensB)
    }

    @Test
    func `file storage preserves legacy wrappers alongside account scoped entries`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("repobar-token-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TokenStore(
            service: "com.steipete.repobar.auth.tests.\(UUID().uuidString)",
            storage: .file(directory)
        )

        let legacyTokens = OAuthTokens(accessToken: "legacy", refreshToken: "legacy-r", expiresAt: nil)
        let scopedTokens = OAuthTokens(accessToken: "scoped", refreshToken: "scoped-r", expiresAt: nil)

        try store.save(tokens: legacyTokens)
        try store.save(tokens: scopedTokens, accountID: "alpha")

        #expect(try store.load() == legacyTokens)
        #expect(try store.loadTokens(accountID: "alpha") == scopedTokens)

        try store.savePAT("legacy-pat")
        try store.savePAT("scoped-pat", accountID: "alpha")

        #expect(try store.loadPAT() == "legacy-pat")
        #expect(try store.loadPAT(accountID: "alpha") == "scoped-pat")
    }

    @Test
    func `file storage allAccountIDs lists saved accounts and ignores legacy entries`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("repobar-token-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TokenStore(
            service: "com.steipete.repobar.auth.tests.\(UUID().uuidString)",
            storage: .file(directory)
        )

        // Legacy entries should be filtered out of allAccountIDs.
        try store.save(tokens: OAuthTokens(accessToken: "x", refreshToken: "y", expiresAt: nil))
        try store.savePAT("legacy")

        // Account-scoped entries across all three kinds.
        try store.save(
            tokens: OAuthTokens(accessToken: "a", refreshToken: "ar", expiresAt: nil),
            accountID: "alpha"
        )
        try store.save(
            clientCredentials: OAuthClientCredentials(clientID: "cid", clientSecret: "sec"),
            accountID: "beta"
        )
        try store.savePAT("ghp_gamma", accountID: "gamma")

        let ids = try store.allAccountIDs()
        #expect(ids == ["alpha", "beta", "gamma"])
    }

    @Test
    func `file storage allAccountIDs dedupes accounts with multiple kinds`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("repobar-token-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TokenStore(
            service: "com.steipete.repobar.auth.tests.\(UUID().uuidString)",
            storage: .file(directory)
        )

        try store.save(
            tokens: OAuthTokens(accessToken: "a", refreshToken: "ar", expiresAt: nil),
            accountID: "alpha"
        )
        try store.save(
            clientCredentials: OAuthClientCredentials(clientID: "cid", clientSecret: "sec"),
            accountID: "alpha"
        )
        try store.savePAT("ghp_alpha", accountID: "alpha")

        #expect(try store.allAccountIDs() == ["alpha"])
    }

    @Test
    func `file storage preserves original accountID with punctuation`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("repobar-token-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TokenStore(
            service: "com.steipete.repobar.auth.tests.\(UUID().uuidString)",
            storage: .file(directory)
        )

        let accountID = "github.com#felipe-work"
        let tokens = OAuthTokens(accessToken: "atok", refreshToken: "rtok", expiresAt: nil)
        let creds = OAuthClientCredentials(clientID: "cid", clientSecret: "sec")

        try store.save(tokens: tokens, accountID: accountID)
        try store.save(clientCredentials: creds, accountID: accountID)
        try store.savePAT("ghp_x", accountID: accountID)

        #expect(try store.loadTokens(accountID: accountID) == tokens)
        #expect(try store.loadClientCredentials(accountID: accountID) == creds)
        #expect(try store.loadPAT(accountID: accountID) == "ghp_x")

        // The exact original string (including '#') must be returned, not a
        // sanitized/mangled form derived from filenames.
        #expect(try store.allAccountIDs() == [accountID])
    }

    @Test
    func `file storage clear by accountID removes punctuated ID from index`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("repobar-token-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TokenStore(
            service: "com.steipete.repobar.auth.tests.\(UUID().uuidString)",
            storage: .file(directory)
        )

        let accountID = "github.com#felipe-work"
        try store.save(
            tokens: OAuthTokens(accessToken: "a", refreshToken: "b", expiresAt: nil),
            accountID: accountID
        )
        #expect(try store.allAccountIDs() == [accountID])

        store.clear(accountID: accountID)
        #expect(try store.allAccountIDs().isEmpty)
    }

    @Test
    func `file storage account scoped keys do not collide after filename encoding`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("repobar-token-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TokenStore(
            service: "com.steipete.repobar.auth.tests.\(UUID().uuidString)",
            storage: .file(directory)
        )
        let colonID = "ghe.example.com:8443#alice"
        let dashID = "ghe.example.com-8443#alice"
        let colonTokens = OAuthTokens(accessToken: "colon", refreshToken: "colon-r", expiresAt: nil)
        let dashTokens = OAuthTokens(accessToken: "dash", refreshToken: "dash-r", expiresAt: nil)

        try store.save(tokens: colonTokens, accountID: colonID)
        try store.save(tokens: dashTokens, accountID: dashID)

        #expect(try store.loadTokens(accountID: colonID) == colonTokens)
        #expect(try store.loadTokens(accountID: dashID) == dashTokens)
        #expect(try Set(store.allAccountIDs()) == [colonID, dashID])
    }

    @Test
    func `file storage reads and clears legacy sanitized filenames`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("repobar-token-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = TokenStore(service: "repobar-tests", storage: .file(directory))
        let tokens = OAuthTokens(accessToken: "legacy", refreshToken: "legacy-r", expiresAt: nil)
        let legacyURL = directory.appendingPathComponent("repobar-tests-default.json")
        try JSONEncoder().encode(tokens).write(to: legacyURL)

        #expect(try store.load() == tokens)
        store.clear()
        #expect(try store.load() == nil)
        #expect(FileManager.default.fileExists(atPath: legacyURL.path) == false)
    }

    @Test
    func `file storage legacy wrappers do not register fixed keys in account index`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("repobar-token-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TokenStore(
            service: "com.steipete.repobar.auth.tests.\(UUID().uuidString)",
            storage: .file(directory)
        )

        try store.save(tokens: OAuthTokens(accessToken: "x", refreshToken: "y", expiresAt: nil))
        try store.save(clientCredentials: OAuthClientCredentials(clientID: "c", clientSecret: "s"))
        try store.savePAT("legacy-pat")

        #expect(try store.allAccountIDs().isEmpty)
    }

    @Test
    func `file storage mirrors scoped oauth credentials to legacy fixed keys`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("repobar-token-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TokenStore(
            service: "com.steipete.repobar.auth.tests.\(UUID().uuidString)",
            storage: .file(directory)
        )
        let tokens = OAuthTokens(accessToken: "active", refreshToken: "refresh", expiresAt: nil)
        let credentials = OAuthClientCredentials(clientID: "cid", clientSecret: "secret")

        try store.savePAT("stale-pat")
        try store.save(tokens: tokens, accountID: "github.com#alice")
        try store.save(clientCredentials: credentials, accountID: "github.com#alice")

        #expect(store.mirrorAccountCredentialsToLegacy(accountID: "github.com#alice", authMethod: .oauth))
        #expect(try store.load() == tokens)
        #expect(try store.loadClientCredentials() == credentials)
        #expect(try store.loadPAT() == nil)
    }

    @Test
    func `file storage mirrors scoped PAT to legacy fixed key and clears stale oauth`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("repobar-token-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TokenStore(
            service: "com.steipete.repobar.auth.tests.\(UUID().uuidString)",
            storage: .file(directory)
        )
        let staleTokens = OAuthTokens(accessToken: "stale", refreshToken: "stale-r", expiresAt: nil)

        try store.save(tokens: staleTokens)
        try store.save(clientCredentials: OAuthClientCredentials(clientID: "old", clientSecret: "old-secret"))
        try store.savePAT("active-pat", accountID: "github.com#alice")

        #expect(store.mirrorAccountCredentialsToLegacy(accountID: "github.com#alice", authMethod: .pat))
        #expect(try store.load() == nil)
        #expect(try store.loadClientCredentials() == nil)
        #expect(try store.loadPAT() == "active-pat")
    }

    @Test
    func `file storage allAccountIDs returns empty when directory missing`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("repobar-token-store-\(UUID().uuidString)", isDirectory: true)
        // Do not create the directory.
        let store = TokenStore(
            service: "com.steipete.repobar.auth.tests.\(UUID().uuidString)",
            storage: .file(directory)
        )

        #expect(try store.allAccountIDs().isEmpty)
    }
}
