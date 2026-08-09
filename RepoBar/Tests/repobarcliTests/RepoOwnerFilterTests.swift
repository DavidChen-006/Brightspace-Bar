@testable import repobarcli
import RepoBarCore
import Testing

struct RepoOwnerFilterTests {
    @Test
    func `parse owners splits and normalizes`() {
        let filter = RepoOwnerFilter.parse([
            "Steipete, org-one",
            "org-two/repo",
            "  org-three  "
        ])

        #expect(filter != nil)
        #expect(filter?.owners == ["steipete", "org-one", "org-two", "org-three"])
    }

    @Test
    func `parse owners ignores empty tokens`() {
        let filter = RepoOwnerFilter.parse([" , , "])
        #expect(filter == nil)
    }

    @Test
    func `applying filters by owner`() throws {
        let filter = try #require(RepoOwnerFilter.parse(["mine"]))
        let repos = [
            Repository(
                id: "1",
                name: "one",
                owner: "mine",
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
            ),
            Repository(
                id: "2",
                name: "two",
                owner: "other",
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
        ]

        let filtered = filter.applying(to: repos)
        #expect(filtered.count == 1)
        #expect(filtered.first?.fullName == "mine/one")
    }

    @Test
    func `owner filtered activity fetch does not pre limit global repos`() throws {
        let filter = try #require(RepoOwnerFilter.parse(["amantus-ai"]))

        #expect(ReposCommand.activityFetchLimit(requestedLimit: 50, ownerFilter: nil) == 50)
        #expect(ReposCommand.activityFetchLimit(requestedLimit: 50, ownerFilter: filter) == nil)
    }
}
