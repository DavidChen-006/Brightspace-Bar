import Foundation
@testable import RepoBarCore
import Testing

struct RepoDetailStoreTests {
    @Test
    func `cache policy marks fresh and stale`() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let cache = RepoDetailCache(
            openPulls: 1,
            openPullsFetchedAt: now.addingTimeInterval(-7200),
            ciDetails: nil,
            ciFetchedAt: now.addingTimeInterval(-600),
            latestActivity: nil,
            activityEvents: nil,
            activityFetchedAt: nil,
            traffic: nil,
            trafficFetchedAt: nil,
            heatmap: nil,
            heatmapFetchedAt: nil,
            latestRelease: nil,
            releaseFetchedAt: nil
        )
        let policy = RepoDetailCachePolicy(
            openPullsTTL: 3600,
            ciTTL: 3600,
            activityTTL: 3600,
            trafficTTL: 3600,
            heatmapTTL: 3600,
            releaseTTL: 3600
        )

        let state = policy.state(for: cache, now: now)
        #expect(state.openPulls == .stale)
        #expect(state.ci == .fresh)
        #expect(state.activity == .missing)
    }

    @Test
    func `default heatmap policy keeps stats stale ok for a day`() {
        #expect(RepoDetailCacheConstants.heatmapTTL == 24 * 60 * 60)
    }

    @Test
    func `store uses memory after disk removal`() throws {
        let baseURL = FileManager.default.temporaryDirectory.appending(path: "repobar-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let diskStore = RepoDetailCacheStore(fileManager: .default, baseURL: baseURL)
        var store = RepoDetailStore(diskStore: diskStore)
        let apiHost = try #require(URL(string: "https://api.github.com"))
        let cache = RepoDetailCache(openPulls: 5)

        store.save(cache, apiHost: apiHost, owner: "steipete", name: "RepoBar")

        let cacheFile = baseURL
            .appending(path: "api.github.com")
            .appending(path: "steipete")
            .appending(path: "RepoBar.json")
        try? FileManager.default.removeItem(at: cacheFile)

        let loaded = store.load(apiHost: apiHost, owner: "steipete", name: "RepoBar")
        #expect(loaded.openPulls == 5)
    }

    @Test
    func `clear drops memory and disk`() throws {
        let baseURL = FileManager.default.temporaryDirectory.appending(path: "repobar-cache-clear-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let diskStore = RepoDetailCacheStore(fileManager: .default, baseURL: baseURL)
        var store = RepoDetailStore(diskStore: diskStore)
        let apiHost = try #require(URL(string: "https://api.github.com"))

        store.save(RepoDetailCache(openPulls: 2), apiHost: apiHost, owner: "me", name: "Repo")
        #expect(store.load(apiHost: apiHost, owner: "me", name: "Repo").openPulls == 2)

        store.clear()
        #expect(store.load(apiHost: apiHost, owner: "me", name: "Repo").openPulls == nil)
        #expect(FileManager.default.fileExists(atPath: baseURL.path) == false)
    }

    @Test
    func `load uses disk when memory empty`() {
        let baseURL = FileManager.default.temporaryDirectory.appending(path: "repobar-cache-disk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let diskStore = RepoDetailCacheStore(fileManager: .default, baseURL: baseURL)
        let apiHost = URL(fileURLWithPath: "/tmp") // hostless; exercises cacheKey host fallback

        var first = RepoDetailStore(diskStore: diskStore)
        first.save(RepoDetailCache(openPulls: 9), apiHost: apiHost, owner: "me", name: "Repo")

        var second = RepoDetailStore(diskStore: diskStore)
        let loaded = second.load(apiHost: apiHost, owner: "me", name: "Repo")
        #expect(loaded.openPulls == 9)
    }
}
