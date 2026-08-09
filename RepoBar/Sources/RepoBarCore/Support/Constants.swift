import Foundation

/// Centralized constants so limits/TTLs stay obvious and discoverable.
public enum RepoCacheConstants {
    /// Upper bound for how many repos we prefetch from `/user/repos` to power autocomplete.
    public static let maxRepositoriesToPrefetch = 1000

    /// How long the prefetched repo list stays warm before we refetch.
    public static let cacheTTL: TimeInterval = 60 * 60 // 1 hour
}

public enum LocalProjectsConstants {
    // Allow ghq-style layouts (e.g. ~/ghq/github.com/owner/repo) which sit 3–4 levels
    // below the configured root path.
    public static let defaultMaxDepth: Int = 4
    public static let defaultSnapshotConcurrencyLimit: Int = 8
    public static let gitCommandTimeout: TimeInterval = 8
    public static let dirtyFileLimit: Int = 10
}

public enum RepoDetailCacheConstants {
    public static let openPullsTTL: TimeInterval = 60 * 60
    public static let ciTTL: TimeInterval = 60 * 60
    public static let activityTTL: TimeInterval = 60 * 60
    public static let trafficTTL: TimeInterval = 60 * 60
    public static let heatmapTTL: TimeInterval = 24 * 60 * 60
    public static let releaseTTL: TimeInterval = 60 * 60
    public static let discussionsCapabilityTTL: TimeInterval = 24 * 60 * 60
}
