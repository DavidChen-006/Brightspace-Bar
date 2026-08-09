import Foundation
import RepoBarCore
import Testing

struct RepoAutocompleteScoringCoverageTests {
    @Test
    func `score handles exact and prefix with slash`() {
        let repo = Repository(
            id: "1",
            name: "RepoBar",
            owner: "steipete",
            sortOrder: nil,
            error: nil,
            rateLimitedUntil: nil,
            ciStatus: .unknown,
            openIssues: 0,
            openPulls: 0,
            latestRelease: nil,
            latestActivity: nil,
            traffic: nil,
            heatmap: []
        )

        #expect(RepoAutocompleteScoring.score(repo: repo, query: "steipete/repobar") == 1000)
        #expect(RepoAutocompleteScoring.score(repo: repo, query: "steipete/rep") == 700)
    }

    @Test
    func `score handles owner fallback and subsequence`() {
        let repo = Repository(
            id: "1",
            name: "RepoBar",
            owner: "steipete",
            sortOrder: nil,
            error: nil,
            rateLimitedUntil: nil,
            ciStatus: .unknown,
            openIssues: 0,
            openPulls: 0,
            latestRelease: nil,
            latestActivity: nil,
            traffic: nil,
            heatmap: []
        )

        #expect(RepoAutocompleteScoring.score(repo: repo, query: "stp") != nil)
        #expect(RepoAutocompleteScoring.score(repo: repo, query: "stei") != nil)
        #expect(RepoAutocompleteScoring.score(repo: repo, query: "zzzz") == nil)
        #expect(RepoAutocompleteScoring.score(repo: repo, query: "  ") == nil)
    }

    @Test
    func `merge picks best score and sorts`() {
        func make(_ fullName: String) -> Repository {
            let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
            return Repository(
                id: fullName,
                name: parts[1],
                owner: parts[0],
                sortOrder: nil,
                error: nil,
                rateLimitedUntil: nil,
                ciStatus: .unknown,
                openIssues: 0,
                openPulls: 0,
                latestRelease: nil,
                latestActivity: nil,
                traffic: nil,
                heatmap: []
            )
        }

        let local = RepoAutocompleteScoring.scored(repos: [make("me/Alpha")], query: "a", sourceRank: 0)
        let remote = RepoAutocompleteScoring.scored(repos: [make("me/alpha"), make("me/Beta")], query: "a", sourceRank: 1, bonus: 5)
        let merged = RepoAutocompleteScoring.merge(local: local, remote: remote, limit: 10)

        #expect(merged.count == 2)
        // Dedupe is case-insensitive and picks the best score; the remote entry wins due to the bonus.
        #expect(merged.map(\.fullName).contains("me/alpha"))
        #expect(merged.map(\.fullName).contains("me/Beta"))
    }
}
