import Foundation

enum GitHubReleasePicker {
    /// Pick the newest stable release, preferring publishedAt over createdAt.
    static func latestRelease(from responses: [ReleaseResponse]) -> Release? {
        let candidates = responses
            .filter { $0.draft != true && $0.prerelease != true }
            .sorted {
                let lhsDate = $0.publishedAt ?? $0.createdAt ?? .distantPast
                let rhsDate = $1.publishedAt ?? $1.createdAt ?? .distantPast
                return lhsDate > rhsDate
            }
        guard let rel = candidates.first else { return nil }

        let published = rel.publishedAt ?? rel.createdAt ?? Date.distantPast
        return Release(name: rel.name ?? rel.tagName, tag: rel.tagName, publishedAt: published, url: rel.htmlUrl)
    }
}
