import Foundation
@testable import RepoBarCore
import Testing

struct RepoAutocompleteScoringTests {
    @Test
    func `exact full name wins`() {
        let exact = Self.repo(owner: "steipete", name: "RepoBar")
        let prefix = Self.repo(owner: "steipete", name: "Repo")

        let scored = RepoAutocompleteScoring.scored(
            repos: [prefix, exact],
            query: "steipete/RepoBar",
            sourceRank: 0
        )
        let sorted = RepoAutocompleteScoring.sort(scored)
        #expect(sorted.first?.repo.fullName == "steipete/RepoBar")
    }

    @Test
    func `repo name beats owner match`() {
        let ownerMatch = Self.repo(owner: "repo", name: "alpha")
        let repoMatch = Self.repo(owner: "steipete", name: "repo")

        let scored = RepoAutocompleteScoring.scored(
            repos: [ownerMatch, repoMatch],
            query: "repo",
            sourceRank: 0
        )
        let sorted = RepoAutocompleteScoring.sort(scored)
        #expect(sorted.first?.repo.fullName == "steipete/repo")
    }

    @Test
    func `subsequence matches are included`() {
        let repo = Self.repo(owner: "steipete", name: "RepoBar")
        let score = RepoAutocompleteScoring.score(repo: repo, query: "rpb")
        #expect(score != nil)
    }

    @Test
    func `owner plus repo beats repo only`() {
        let exactOwner = Self.repo(owner: "steipete", name: "repo")
        let otherOwner = Self.repo(owner: "other", name: "repo")

        let scored = RepoAutocompleteScoring.scored(
            repos: [otherOwner, exactOwner],
            query: "steipete/repo",
            sourceRank: 0
        )
        let sorted = RepoAutocompleteScoring.sort(scored)
        #expect(sorted.first?.repo.fullName == "steipete/repo")
    }

    @Test
    func `topic exact match boosts score`() throws {
        let repo = Self.repo(owner: "swiftlang", name: "indexstore-db", topics: ["swift"])

        let score = RepoAutocompleteScoring.score(repo: repo, query: "swift")
        // Should match via topic "swift" even though neither owner nor name contain "swift"
        #expect(score != nil)
        #expect(try #require(score) >= 400, "Topic exact match should contribute at least 400")
    }

    @Test
    func `topic prefix match works`() throws {
        let repo = Self.repo(owner: "apple", name: "some-tool", topics: ["machine-learning"])

        let score = RepoAutocompleteScoring.score(repo: repo, query: "machine")
        #expect(score != nil)
        #expect(try #require(score) >= 300, "Topic prefix match should contribute at least 300")
    }

    @Test
    func `language exact match works`() throws {
        let repo = Self.repo(owner: "openclaw", name: "clawbook", language: "Ruby")

        let score = RepoAutocompleteScoring.score(repo: repo, query: "ruby")
        #expect(score != nil)
        #expect(try #require(score) >= 150, "Language exact match should contribute at least 150")
    }

    @Test
    func `description substring match works`() throws {
        let repo = Self.repo(
            owner: "someorg",
            name: "cool-tool",
            description: "A declarative UI framework for building iOS apps"
        )

        let score = RepoAutocompleteScoring.score(repo: repo, query: "declarative")
        #expect(score != nil)
        #expect(try #require(score) >= 60, "Description substring should contribute at least 60")
    }

    @Test
    func `metadata match shows repo when name doesnt match`() {
        let repo = Self.repo(owner: "someone", name: "unrelated", description: "iOS utility library", language: "Swift", topics: ["swift"])

        // Query "swift" matches topic "swift" — repo should appear even though name is "unrelated"
        let scored = RepoAutocompleteScoring.scored(repos: [repo], query: "swift", sourceRank: 0)
        #expect(scored.isEmpty == false)
        #expect(scored.first?.repo.fullName == "someone/unrelated")
    }

    @Test
    func `no match returns nil with metadata fields`() {
        let repo = Self.repo(owner: "me", name: "alpha", description: "some project", language: "Swift", topics: ["ios"])

        #expect(RepoAutocompleteScoring.score(repo: repo, query: "zzzzz") == nil)
    }
}

private extension RepoAutocompleteScoringTests {
    static func repo(
        owner: String,
        name: String,
        description: String? = nil,
        language: String? = nil,
        topics: [String] = []
    ) -> Repository {
        Repository(
            id: UUID().uuidString,
            name: name,
            owner: owner,
            description: description,
            language: language,
            topics: topics,
            sortOrder: nil,
            error: nil,
            rateLimitedUntil: nil,
            ciStatus: .unknown,
            ciRunCount: nil,
            openIssues: 0,
            openPulls: 0,
            stars: 0,
            pushedAt: nil,
            latestRelease: nil,
            latestActivity: nil,
            traffic: nil,
            heatmap: []
        )
    }
}
