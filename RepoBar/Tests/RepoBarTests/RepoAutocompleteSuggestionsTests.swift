import Foundation
import RepoBarCore
import Testing

struct RepoAutocompleteSuggestionsTests {
    @Test
    func `empty query returns recents prefix`() {
        let prefetched = [
            Self.make("steipete/RepoBar"),
            Self.make("steipete/clawdis"),
            Self.make("amantus-ai/sweetistics")
        ]

        let results = RepoAutocompleteSuggestions.suggestions(query: "  ", prefetched: prefetched, limit: 2)
        #expect(results.map(\.fullName) == ["steipete/RepoBar", "steipete/clawdis"])
    }

    @Test
    func `non matching query does not fallback to recents`() {
        let prefetched = [
            Self.make("steipete/RepoBar"),
            Self.make("amantus-ai/sweetistics")
        ]

        let results = RepoAutocompleteSuggestions.suggestions(query: "zzzz-not-a-repo", prefetched: prefetched, limit: 8)
        #expect(results.isEmpty)
    }

    @Test
    func `matching query filters and ranks by name`() {
        let prefetched = [
            Self.make("steipete/RepoBar"),
            Self.make("amantus-ai/sweetistics"),
            Self.make("steipete/clawdis")
        ]

        let results = RepoAutocompleteSuggestions.suggestions(query: "sweetis", prefetched: prefetched, limit: 8)
        #expect(results.first?.fullName == "amantus-ai/sweetistics")
        #expect(results.contains(where: { $0.fullName == "steipete/RepoBar" }) == false)
    }
}

private extension RepoAutocompleteSuggestionsTests {
    static func make(_ fullName: String) -> Repository {
        let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
        return Repository(
            id: fullName,
            name: parts[1],
            owner: parts[0],
            isFork: false,
            isArchived: false,
            sortOrder: nil,
            error: nil,
            rateLimitedUntil: nil,
            ciStatus: .unknown,
            ciRunCount: nil,
            openIssues: 0,
            openPulls: 0,
            stars: 0,
            forks: 0,
            pushedAt: nil,
            latestRelease: nil,
            latestActivity: nil,
            activityEvents: [],
            traffic: nil,
            heatmap: []
        )
    }
}
