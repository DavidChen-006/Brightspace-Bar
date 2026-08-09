import Foundation

/// Simple in-memory ETag cache keyed by URL string.
actor ETagCache {
    private static let defaultMaxEntries = 512

    private let maxEntries: Int
    private let persistentStore: HTTPResponseDiskCache?
    private var store: [String: (etag: String, data: Data)] = [:]
    private var entryOrder: [String] = []
    private var rateLimitedUntil: Date?

    init(maxEntries: Int = ETagCache.defaultMaxEntries, persistentStore: HTTPResponseDiskCache? = nil) {
        self.maxEntries = max(0, maxEntries)
        self.persistentStore = persistentStore
    }

    static func persistent(maxEntries: Int = ETagCache.defaultMaxEntries) -> ETagCache {
        ETagCache(maxEntries: maxEntries, persistentStore: HTTPResponseDiskCache.standard())
    }

    static func persistent(accountID: String?, maxEntries: Int = ETagCache.defaultMaxEntries) -> ETagCache {
        ETagCache(maxEntries: maxEntries, persistentStore: HTTPResponseDiskCache.scoped(accountID: accountID))
    }

    func cached(for url: URL) -> (etag: String, data: Data)? {
        let key = url.absoluteString
        if let cached = self.store[key] {
            self.touch(key)
            return cached
        }

        guard let cached = self.persistentStore?.cached(url: url) else { return nil }

        let value = (cached.etag, cached.data)
        self.store[key] = value
        self.touch(key)
        self.evictIfNeeded()
        return value
    }

    func save(url: URL, etag: String?, data: Data, response: HTTPURLResponse? = nil) {
        guard let etag else { return }

        let key = url.absoluteString
        if self.maxEntries > 0 {
            self.store[key] = (etag, data)
            self.touch(key)
            self.evictIfNeeded()
        }
        self.persistentStore?.save(url: url, etag: etag, data: data, response: response)
    }

    func setRateLimitReset(date: Date) {
        self.rateLimitedUntil = date
        self.persistentStore?.setRateLimitReset(date: date)
    }

    func rateLimitUntil(now: Date = Date()) -> Date? {
        let until = self.rateLimitedUntil ?? self.persistentStore?.rateLimitUntil(now: now)
        guard let until else { return nil }

        if until <= now {
            self.rateLimitedUntil = nil
            return nil
        }
        return until
    }

    func isRateLimited(now: Date = Date()) -> Bool {
        guard let until = self.rateLimitUntil(now: now) else { return false }

        return until > now
    }

    func clear() {
        self.store.removeAll()
        self.entryOrder.removeAll()
        self.rateLimitedUntil = nil
        self.persistentStore?.clear()
    }

    func count() -> Int {
        self.persistentStore?.count() ?? self.store.count
    }

    private func touch(_ key: String) {
        self.entryOrder.removeAll { $0 == key }
        self.entryOrder.append(key)
    }

    private func evictIfNeeded() {
        while self.store.count > self.maxEntries, let oldest = self.entryOrder.first {
            self.entryOrder.removeFirst()
            self.store[oldest] = nil
        }
    }
}
