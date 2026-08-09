import Foundation
@testable import RepoBarCore
import Testing

struct SettingsStoreTests {
    @Test
    func `save and load`() throws {
        let suiteName = "repobar.settings.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        #expect(store.load() == UserSettings())

        var settings = UserSettings()
        settings.repoList.displayLimit = 9
        settings.repoList.pinnedRepositories = ["steipete/RepoBar", "steipete/clawdis"]
        settings.repoList.hiddenRepositories = ["steipete/agent-scripts"]
        settings.enterpriseHost = makeURL("https://ghe.example.com")
        settings.debugPaneEnabled = true

        store.save(settings)
        #expect(store.load() == settings)
    }

    @Test
    func `save and load persists local projects bookmark`() throws {
        let suiteName = "repobar.settings.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        var settings = UserSettings()
        settings.localProjects.rootPath = "~/Projects"
        settings.localProjects.rootBookmarkData = Data([0x01, 0x02, 0x03, 0x04])

        store.save(settings)
        let loaded = store.load()
        #expect(loaded.localProjects.rootPath == "~/Projects")
        #expect(loaded.localProjects.rootBookmarkData == Data([0x01, 0x02, 0x03, 0x04]))
    }
}

private func makeURL(_ string: String) -> URL {
    URL(string: string)!
}
