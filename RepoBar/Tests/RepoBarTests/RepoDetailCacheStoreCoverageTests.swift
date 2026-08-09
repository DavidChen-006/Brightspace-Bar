import Foundation
@testable import RepoBarCore
import Testing

struct RepoDetailCacheStoreCoverageTests {
    @Test
    func `save then load round trips from disk`() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RepoDetailCacheStoreCoverageTests.\(UUID().uuidString)", isDirectory: true)

        let store = RepoDetailCacheStore(baseURL: base)
        let apiHost = try #require(URL(string: "https://api.github.com"))
        var cache = RepoDetailCache()
        cache.openPulls = 7
        cache.openPullsFetchedAt = Date(timeIntervalSinceReferenceDate: 123)

        store.save(cache, apiHost: apiHost, owner: "me", name: "Repo")
        let loaded = store.load(apiHost: apiHost, owner: "me", name: "Repo")

        #expect(loaded?.openPulls == 7)
        #expect(loaded?.openPullsFetchedAt == Date(timeIntervalSinceReferenceDate: 123))
    }

    @Test
    func `load invalid JSON deletes cache file`() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RepoDetailCacheStoreCoverageTests.invalid.\(UUID().uuidString)", isDirectory: true)
        let apiHost = try #require(URL(string: "https://api.github.com"))
        let store = RepoDetailCacheStore(baseURL: base)

        let fileURL = base
            .appending(path: apiHost.host ?? "api.github.com")
            .appending(path: "me")
            .appending(path: "Repo.json")

        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL, options: .atomic)
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == true)

        #expect(store.load(apiHost: apiHost, owner: "me", name: "Repo") == nil)
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
    }

    @Test
    func `clear removes base directory`() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RepoDetailCacheStoreCoverageTests.clear.\(UUID().uuidString)", isDirectory: true)
        let store = RepoDetailCacheStore(baseURL: base)

        let apiHost = try #require(URL(string: "https://api.github.com"))
        let cache = RepoDetailCache(openPulls: 1)
        store.save(cache, apiHost: apiHost, owner: "me", name: "Repo")
        #expect(FileManager.default.fileExists(atPath: base.path) == true)

        store.clear()
        #expect(FileManager.default.fileExists(atPath: base.path) == false)
    }

    @Test
    func `load missing file returns nil`() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RepoDetailCacheStoreCoverageTests.missing.\(UUID().uuidString)", isDirectory: true)
        let store = RepoDetailCacheStore(baseURL: base)
        let apiHost = try #require(URL(string: "https://api.github.com"))
        #expect(store.load(apiHost: apiHost, owner: "me", name: "Repo") == nil)
    }

    @Test
    func `cache file uses fallback host when missing`() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RepoDetailCacheStoreCoverageTests.hostless.\(UUID().uuidString)", isDirectory: true)
        let store = RepoDetailCacheStore(baseURL: base)
        let apiHost = URL(fileURLWithPath: "/tmp")
        store.save(RepoDetailCache(openPulls: 1), apiHost: apiHost, owner: "me", name: "Repo")
        let expected = base
            .appending(path: "api.github.com")
            .appending(path: "me")
            .appending(path: "Repo.json")
        #expect(FileManager.default.fileExists(atPath: expected.path) == true)
    }

    @Test
    func `save gracefully handles write failures`() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RepoDetailCacheStoreCoverageTests.filebase.\(UUID().uuidString)")

        try Data("not a directory".utf8).write(to: base, options: .atomic)
        #expect(FileManager.default.fileExists(atPath: base.path) == true)

        let store = RepoDetailCacheStore(baseURL: base)
        let apiHost = try #require(URL(string: "https://api.github.com"))
        store.save(RepoDetailCache(openPulls: 1), apiHost: apiHost, owner: "me", name: "Repo")

        let expected = base
            .appending(path: apiHost.host ?? "api.github.com")
            .appending(path: "me")
            .appending(path: "Repo.json")
        #expect(FileManager.default.fileExists(atPath: expected.path) == false)
    }
}
