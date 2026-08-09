import Foundation
@testable import RepoBarCore
import Testing

struct ETagCacheTests {
    @Test
    func `save and retrieve`() async throws {
        let cache = ETagCache()
        let url = try #require(URL(string: "https://example.com/a"))

        await cache.save(url: url, etag: nil, data: Data("x".utf8))
        #expect(await cache.count() == 0)

        await cache.save(url: url, etag: "etag-1", data: Data("payload".utf8))
        #expect(await cache.count() == 1)

        let hit = await cache.cached(for: url)
        #expect(hit?.etag == "etag-1")
        #expect(hit?.data == Data("payload".utf8))
    }

    @Test
    func `evicts oldest entry when capacity is reached`() async throws {
        let cache = ETagCache(maxEntries: 2)
        let firstURL = try #require(URL(string: "https://example.com/a"))
        let secondURL = try #require(URL(string: "https://example.com/b"))
        let thirdURL = try #require(URL(string: "https://example.com/c"))

        await cache.save(url: firstURL, etag: "etag-a", data: Data("a".utf8))
        await cache.save(url: secondURL, etag: "etag-b", data: Data("b".utf8))
        _ = await cache.cached(for: firstURL)
        await cache.save(url: thirdURL, etag: "etag-c", data: Data("c".utf8))

        #expect(await cache.count() == 2)
        #expect(await cache.cached(for: firstURL)?.etag == "etag-a")
        #expect(await cache.cached(for: secondURL) == nil)
        #expect(await cache.cached(for: thirdURL)?.etag == "etag-c")
    }

    @Test
    func `rate limit expires and clears`() async {
        let cache = ETagCache()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let until = now.addingTimeInterval(10)

        await cache.setRateLimitReset(date: until)
        #expect(await cache.isRateLimited(now: now))

        #expect(await cache.isRateLimited(now: now.addingTimeInterval(11)) == false)
        #expect(await cache.rateLimitUntil(now: now.addingTimeInterval(11)) == nil)
    }

    @Test
    func `clear drops entries and rate limit`() async throws {
        let cache = ETagCache()
        let url = try #require(URL(string: "https://example.com/a"))
        await cache.save(url: url, etag: "etag-1", data: Data("payload".utf8))
        await cache.setRateLimitReset(date: Date().addingTimeInterval(60))

        await cache.clear()
        #expect(await cache.count() == 0)
        #expect(await cache.isRateLimited() == false)
    }
}
