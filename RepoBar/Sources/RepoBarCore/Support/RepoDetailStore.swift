import Foundation

struct RepoDetailStore {
    private var memory: [String: RepoDetailCache] = [:]
    private var diskStore: RepoDetailCacheStore

    init(diskStore: RepoDetailCacheStore = RepoDetailCacheStore()) {
        self.diskStore = diskStore
    }

    mutating func load(apiHost: URL, owner: String, name: String) -> RepoDetailCache {
        let key = Self.cacheKey(apiHost: apiHost, owner: owner, name: name)
        if let cached = self.memory[key] {
            return cached
        }
        if let cached = self.diskStore.load(apiHost: apiHost, owner: owner, name: name) {
            self.memory[key] = cached
            return cached
        }
        return RepoDetailCache()
    }

    mutating func save(_ cache: RepoDetailCache, apiHost: URL, owner: String, name: String) {
        let key = Self.cacheKey(apiHost: apiHost, owner: owner, name: name)
        self.memory[key] = cache
        self.diskStore.save(cache, apiHost: apiHost, owner: owner, name: name)
    }

    /// Capability cache: use TTL so newly-enabled discussions can reappear without a manual reset.
    mutating func discussionsEnabled(
        apiHost: URL,
        owner: String,
        name: String,
        now: Date,
        ttl: TimeInterval
    ) -> Bool? {
        let cache = self.load(apiHost: apiHost, owner: owner, name: name)
        guard let enabled = cache.discussionsEnabled, let checkedAt = cache.discussionsCheckedAt else { return nil }
        guard now.timeIntervalSince(checkedAt) <= ttl else { return nil }

        return enabled
    }

    mutating func updateDiscussionsEnabled(
        apiHost: URL,
        owner: String,
        name: String,
        enabled: Bool,
        checkedAt: Date
    ) -> Bool {
        var cache = self.load(apiHost: apiHost, owner: owner, name: name)
        let hasChanged = cache.discussionsEnabled != enabled
            || cache.discussionsCheckedAt != checkedAt
        cache.discussionsEnabled = enabled
        cache.discussionsCheckedAt = checkedAt
        if hasChanged {
            self.save(cache, apiHost: apiHost, owner: owner, name: name)
        }
        return hasChanged
    }

    mutating func clear() {
        self.memory = [:]
        self.diskStore.clear()
    }

    private static func cacheKey(apiHost: URL, owner: String, name: String) -> String {
        let host = apiHost.host ?? "api.github.com"
        return "\(host)::\(owner)/\(name)"
    }
}

struct RepoDetailCachePolicy {
    var openPullsTTL: TimeInterval
    var ciTTL: TimeInterval
    var activityTTL: TimeInterval
    var trafficTTL: TimeInterval
    var heatmapTTL: TimeInterval
    var releaseTTL: TimeInterval

    static let `default` = RepoDetailCachePolicy(
        openPullsTTL: RepoDetailCacheConstants.openPullsTTL,
        ciTTL: RepoDetailCacheConstants.ciTTL,
        activityTTL: RepoDetailCacheConstants.activityTTL,
        trafficTTL: RepoDetailCacheConstants.trafficTTL,
        heatmapTTL: RepoDetailCacheConstants.heatmapTTL,
        releaseTTL: RepoDetailCacheConstants.releaseTTL
    )

    func state(for cache: RepoDetailCache, now: Date) -> RepoDetailCacheState {
        RepoDetailCacheState(
            openPulls: self.freshness(lastFetched: cache.openPullsFetchedAt, now: now, ttl: self.openPullsTTL),
            ci: self.freshness(lastFetched: cache.ciFetchedAt, now: now, ttl: self.ciTTL),
            activity: self.freshness(lastFetched: cache.activityFetchedAt, now: now, ttl: self.activityTTL),
            traffic: self.freshness(lastFetched: cache.trafficFetchedAt, now: now, ttl: self.trafficTTL),
            heatmap: self.freshness(lastFetched: cache.heatmapFetchedAt, now: now, ttl: self.heatmapTTL),
            release: self.freshness(lastFetched: cache.releaseFetchedAt, now: now, ttl: self.releaseTTL)
        )
    }

    private func freshness(lastFetched: Date?, now: Date, ttl: TimeInterval) -> CacheFreshness {
        guard let lastFetched else { return .missing }
        guard now.timeIntervalSince(lastFetched) >= ttl else { return .fresh }

        return .stale
    }
}
