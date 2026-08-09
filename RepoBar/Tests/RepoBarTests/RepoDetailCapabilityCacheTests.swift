import Foundation
@testable import RepoBarCore
import Testing

struct RepoDetailCapabilityCacheTests {
    @Test
    func `discussions capability respects TTL`() throws {
        let baseURL = FileManager.default.temporaryDirectory.appending(path: "repobar-capability-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let diskStore = RepoDetailCacheStore(fileManager: .default, baseURL: baseURL)
        var store = RepoDetailStore(diskStore: diskStore)
        let apiHost = try #require(URL(string: "https://api.github.com"))
        let now = Date(timeIntervalSinceReferenceDate: 123_456)

        _ = store.updateDiscussionsEnabled(
            apiHost: apiHost,
            owner: "steipete",
            name: "RepoBar",
            enabled: false,
            checkedAt: now
        )

        let cached = store.discussionsEnabled(
            apiHost: apiHost,
            owner: "steipete",
            name: "RepoBar",
            now: now,
            ttl: 60
        )
        #expect(cached == false)

        let stale = store.discussionsEnabled(
            apiHost: apiHost,
            owner: "steipete",
            name: "RepoBar",
            now: now.addingTimeInterval(61),
            ttl: 60
        )
        #expect(stale == nil)
    }

    @Test
    func `discussions capability persists across stores`() throws {
        let baseURL = FileManager.default.temporaryDirectory.appending(path: "repobar-capability-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let diskStore = RepoDetailCacheStore(fileManager: .default, baseURL: baseURL)
        let apiHost = try #require(URL(string: "https://api.github.com"))
        let now = Date(timeIntervalSinceReferenceDate: 222_222)

        var writer = RepoDetailStore(diskStore: diskStore)
        _ = writer.updateDiscussionsEnabled(
            apiHost: apiHost,
            owner: "steipete",
            name: "RepoBar",
            enabled: true,
            checkedAt: now
        )

        var reader = RepoDetailStore(diskStore: diskStore)
        let cached = reader.discussionsEnabled(
            apiHost: apiHost,
            owner: "steipete",
            name: "RepoBar",
            now: now,
            ttl: 3600
        )
        #expect(cached == true)
    }
}
