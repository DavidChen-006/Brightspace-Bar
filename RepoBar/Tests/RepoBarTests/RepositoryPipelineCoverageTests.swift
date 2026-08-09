import Foundation
import RepoBarCore
import Testing

struct RepositoryPipelineCoverageTests {
    @Test
    func `pin priority sorts pinned first then by pinned order`() {
        let a = Repository(
            id: "1",
            name: "A",
            owner: "me",
            sortOrder: nil,
            error: nil,
            rateLimitedUntil: nil,
            ciStatus: .unknown,
            openIssues: 0,
            openPulls: 0,
            pushedAt: Date(timeIntervalSinceReferenceDate: 10),
            latestRelease: nil,
            latestActivity: nil,
            traffic: nil,
            heatmap: []
        )
        let b = Repository(
            id: "2",
            name: "B",
            owner: "me",
            sortOrder: nil,
            error: nil,
            rateLimitedUntil: nil,
            ciStatus: .unknown,
            openIssues: 0,
            openPulls: 0,
            pushedAt: Date(timeIntervalSinceReferenceDate: 20),
            latestRelease: nil,
            latestActivity: nil,
            traffic: nil,
            heatmap: []
        )
        let c = Repository(
            id: "3",
            name: "C",
            owner: "me",
            sortOrder: nil,
            error: nil,
            rateLimitedUntil: nil,
            ciStatus: .unknown,
            openIssues: 0,
            openPulls: 0,
            pushedAt: Date(timeIntervalSinceReferenceDate: 30),
            latestRelease: nil,
            latestActivity: nil,
            traffic: nil,
            heatmap: []
        )

        let query = RepositoryQuery(
            scope: .all,
            sortKey: .activity,
            pinned: [b.fullName, a.fullName],
            hidden: [],
            pinPriority: true
        )
        let out = RepositoryPipeline.apply([c, a, b], query: query)
        #expect(out.prefix(2).map(\.fullName) == [b.fullName, a.fullName])
    }

    @Test
    func `hidden scope and negative limit`() {
        let a = Repository(
            id: "1",
            name: "A",
            owner: "me",
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
        let b = Repository(
            id: "2",
            name: "B",
            owner: "me",
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

        let query = RepositoryQuery(
            scope: .hidden,
            sortKey: .name,
            limit: -1,
            pinned: [],
            hidden: [b.fullName],
            pinPriority: false
        )
        let out = RepositoryPipeline.apply([a, b], query: query)
        #expect(out.isEmpty)
    }

    @Test
    func `age cutoff defaults`() {
        let now = Date(timeIntervalSinceReferenceDate: 5_000_000)
        #expect(RepositoryQueryDefaults.ageCutoff(now: now, scope: .pinned) == nil)
        #expect(RepositoryQueryDefaults.ageCutoff(now: now, scope: .all, ageDays: 0) == nil)
        #expect(RepositoryQueryDefaults.ageCutoff(now: now, scope: .all, ageDays: 1) != nil)
    }

    @Test
    func `apply with limit nil returns all`() {
        let a = Repository(
            id: "1",
            name: "A",
            owner: "me",
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
        let query = RepositoryQuery(scope: .all, sortKey: .name, limit: nil)
        let out = RepositoryPipeline.apply([a], query: query)
        #expect(out.count == 1)
    }

    @Test
    func `pin priority branch coverage`() {
        let a = Repository(
            id: "1",
            name: "A",
            owner: "me",
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
        let b = Repository(
            id: "2",
            name: "B",
            owner: "me",
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
        let c = Repository(
            id: "3",
            name: "C",
            owner: "me",
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

        let query = RepositoryQuery(
            scope: .all,
            sortKey: .name,
            pinned: [a.fullName],
            hidden: [],
            pinPriority: true
        )

        let out = RepositoryPipeline.apply([b, a, c], query: query)
        #expect(out.first?.fullName == a.fullName)
    }
}
