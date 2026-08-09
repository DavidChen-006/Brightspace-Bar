import Commander
import Foundation
@testable import repobarcli
import RepoBarCore
import Testing

struct AccountResolverTests {
    private func makeSettings(_ accounts: [Account], active: String? = nil) -> UserSettings {
        var settings = UserSettings()
        settings.accounts = accounts
        settings.activeAccountID = active
        return settings
    }

    private var alice: Account {
        Account(username: "alice", host: URL(string: "https://github.com")!, authMethod: .oauth)
    }

    private var bob: Account {
        Account(username: "bob", host: URL(string: "https://ghe.example.com")!, authMethod: .pat)
    }

    @Test
    func `resolves explicit account id`() throws {
        let settings = self.makeSettings([self.alice, self.bob])
        let resolved = try AccountResolver.resolve("github.com#alice", settings: settings)
        #expect(resolved.id == "github.com#alice")
    }

    @Test
    func `resolves username at host shorthand`() throws {
        let settings = self.makeSettings([self.alice, self.bob])
        let resolved = try AccountResolver.resolve("bob@ghe.example.com", settings: settings)
        #expect(resolved.id == "ghe.example.com#bob")
    }

    @Test
    func `resolves shorthand case-insensitively`() throws {
        let settings = self.makeSettings([self.alice])
        let resolved = try AccountResolver.resolve("Alice@GITHUB.com", settings: settings)
        #expect(resolved.id == "github.com#alice")
    }

    @Test
    func `defaults to active account when input nil`() throws {
        let settings = self.makeSettings([self.alice, self.bob], active: self.bob.id)
        let resolved = try AccountResolver.resolve(nil, settings: settings)
        #expect(resolved.id == self.bob.id)
    }

    @Test
    func `falls back to sole account when active id is nil`() throws {
        let settings = self.makeSettings([self.alice])
        let resolved = try AccountResolver.resolve(nil, settings: settings)
        #expect(resolved.id == self.alice.id)
    }

    @Test
    func `throws when no accounts configured`() throws {
        let settings = self.makeSettings([])
        #expect(throws: ValidationError.self) {
            _ = try AccountResolver.resolve(nil, settings: settings)
        }
    }

    @Test
    func `throws when multiple accounts but no active set`() throws {
        let settings = self.makeSettings([self.alice, self.bob])
        #expect(throws: ValidationError.self) {
            _ = try AccountResolver.resolve(nil, settings: settings)
        }
    }

    @Test
    func `throws for unknown account`() throws {
        let settings = self.makeSettings([self.alice])
        #expect(throws: ValidationError.self) {
            _ = try AccountResolver.resolve("github.com#stranger", settings: settings)
        }
    }
}
