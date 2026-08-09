import Foundation
@testable import RepoBarCore
import Testing

struct AccountModelTests {
    @Test
    func `derives stable id for github_com`() throws {
        let host = try #require(URL(string: "https://github.com"))
        #expect(Account.deriveID(host: host, username: "Alice") == "github.com#alice")
        #expect(Account.deriveID(host: host, username: "alice") == "github.com#alice")
    }

    @Test
    func `derives stable id for enterprise host`() throws {
        let host = try #require(URL(string: "https://GHE.Example.com"))
        #expect(Account.deriveID(host: host, username: "Bob") == "ghe.example.com#bob")
    }

    @Test
    func `derives distinct ids for enterprise host ports`() throws {
        let defaultPort = try #require(URL(string: "https://ghe.example.com"))
        let customPort = try #require(URL(string: "https://ghe.example.com:8443"))
        #expect(Account.deriveID(host: defaultPort, username: "Bob") == "ghe.example.com#bob")
        #expect(Account.deriveID(host: customPort, username: "Bob") == "ghe.example.com:8443#bob")
    }

    @Test
    func `derives api host for github_com and enterprise`() throws {
        let github = try #require(URL(string: "https://github.com"))
        #expect(Account.deriveAPIHost(for: github).absoluteString == "https://api.github.com")

        let enterprise = try #require(URL(string: "https://ghe.example.com"))
        #expect(Account.deriveAPIHost(for: enterprise).absoluteString == "https://ghe.example.com/api/v3")
    }

    @Test
    func `convenience initializer derives id and api host`() throws {
        let account = try Account(
            username: "alice",
            host: #require(URL(string: "https://github.com")),
            authMethod: .oauth
        )
        #expect(account.id == "github.com#alice")
        #expect(account.apiHost.absoluteString == "https://api.github.com")
        #expect(account.usernameAtHost == "alice @ github.com")
    }

    @Test
    func `convenience initializer respects custom display name`() throws {
        let account = try Account(
            username: "alice",
            host: #require(URL(string: "https://github.com")),
            authMethod: .pat,
            displayName: "Work"
        )
        #expect(account.displayName == "Work")
    }

    @Test
    func `codable round trip preserves fields`() throws {
        let account = try Account(
            username: "alice",
            host: #require(URL(string: "https://ghe.example.com")),
            authMethod: .oauth,
            loopbackPort: 1234,
            clientID: "client-xyz",
            displayName: "Alice @ GHE"
        )
        let data = try JSONEncoder().encode(account)
        let decoded = try JSONDecoder().decode(Account.self, from: data)
        #expect(decoded == account)
    }
}

struct AccountSelectionTests {
    @Test
    func `default selection is all`() {
        let selection = AccountSelection.all
        #expect(selection.isVisible("any") == true)
        #expect(selection.visibleIDs == nil)
    }

    @Test
    func `only selection filters by id`() {
        let selection = AccountSelection.only(["github.com#alice"])
        #expect(selection.isVisible("github.com#alice") == true)
        #expect(selection.isVisible("github.com#bob") == false)
        #expect(selection.visibleIDs == ["github.com#alice"])
    }

    @Test
    func `codable round trip for all`() throws {
        let data = try JSONEncoder().encode(AccountSelection.all)
        let decoded = try JSONDecoder().decode(AccountSelection.self, from: data)
        #expect(decoded == .all)
    }

    @Test
    func `codable round trip for only`() throws {
        let selection = AccountSelection.only(["github.com#alice", "ghe.example.com#bob"])
        let data = try JSONEncoder().encode(selection)
        let decoded = try JSONDecoder().decode(AccountSelection.self, from: data)
        #expect(decoded == selection)
    }
}

struct AccountScopedRepositoryListsTests {
    @Test
    func `defaults are empty`() {
        let lists = AccountScopedRepositoryLists()
        #expect(lists.isEmpty)
        #expect(lists.pinned(for: "github.com#alice").isEmpty)
        #expect(lists.hidden(for: "github.com#alice").isEmpty)
    }

    @Test
    func `set and read per account`() {
        var lists = AccountScopedRepositoryLists()
        lists.setPinned(["a/b"], for: "github.com#alice")
        lists.setHidden(["c/d"], for: "github.com#alice")
        #expect(lists.pinned(for: "github.com#alice") == ["a/b"])
        #expect(lists.hidden(for: "github.com#alice") == ["c/d"])
        #expect(lists.isEmpty == false)
    }

    @Test
    func `legacy fallback used when account entry is empty`() {
        let lists = AccountScopedRepositoryLists()
        #expect(lists.pinned(for: "github.com#alice", legacy: ["legacy/repo"]) == ["legacy/repo"])
        #expect(lists.hidden(for: "github.com#alice", legacy: ["legacy/repo"]) == ["legacy/repo"])
    }

    @Test
    func `per-account entry shadows legacy`() {
        var lists = AccountScopedRepositoryLists()
        lists.setPinned(["scoped/repo"], for: "github.com#alice")
        #expect(lists.pinned(for: "github.com#alice", legacy: ["legacy/repo"]) == ["scoped/repo"])
    }

    @Test
    func `normalize trims and deduplicates case-insensitively`() {
        var lists = AccountScopedRepositoryLists()
        lists.setPinned([" a/b ", "A/B", "c/d", ""], for: "github.com#alice")
        #expect(lists.pinned(for: "github.com#alice") == ["a/b", "c/d"])
    }
}
