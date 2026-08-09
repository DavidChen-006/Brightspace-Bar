import Foundation

public enum CacheFreshness: String, Codable, Sendable {
    case missing
    case fresh
    case stale

    public var needsRefresh: Bool {
        self != .fresh
    }
}

public struct RepoDetailCacheState: Equatable, Sendable {
    public var openPulls: CacheFreshness
    public var ci: CacheFreshness
    public var activity: CacheFreshness
    public var traffic: CacheFreshness
    public var heatmap: CacheFreshness
    public var release: CacheFreshness

    public init(
        openPulls: CacheFreshness,
        ci: CacheFreshness,
        activity: CacheFreshness,
        traffic: CacheFreshness,
        heatmap: CacheFreshness,
        release: CacheFreshness
    ) {
        self.openPulls = openPulls
        self.ci = ci
        self.activity = activity
        self.traffic = traffic
        self.heatmap = heatmap
        self.release = release
    }

    public static let missing = RepoDetailCacheState(
        openPulls: .missing,
        ci: .missing,
        activity: .missing,
        traffic: .missing,
        heatmap: .missing,
        release: .missing
    )
}
