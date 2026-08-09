import Foundation
@testable import RepoBar
@testable import RepoBarCore
import Testing

struct ActionsOwnerSelectionTests {
    @Test @MainActor
    func `uses explicit owner filter when configured`() {
        let repos = [
            Self.repo(owner: "openclaw", name: "openclaw"),
            Self.repo(owner: "steipete", name: "RepoBar")
        ]

        let owners = AppState.actionsOwners(
            username: "steipete",
            repositories: repos,
            monitoredOwners: [" objcio ", "steipete", "OBJCiO"]
        )

        #expect(owners.map(\.name) == ["objcio", "steipete"])
        #expect(owners.map(\.isOrg) == [true, false])
    }

    @Test @MainActor
    func `uses repository owners when owner filter is empty`() {
        let repos = [
            Self.repo(owner: "openclaw", name: "clawsweeper"),
            Self.repo(owner: "OpenClaw", name: "crabpot"),
            Self.repo(owner: "steipete", name: "RepoBar")
        ]

        let owners = AppState.actionsOwners(
            username: "steipete",
            repositories: repos,
            monitoredOwners: []
        )

        #expect(owners.map(\.name) == ["steipete", "openclaw"])
        #expect(owners.map(\.isOrg) == [false, true])
    }

    @Test @MainActor
    func `uses cached menu snapshot repositories when live repositories are empty`() {
        let snapshotRepos = [
            Self.repo(owner: "openclaw", name: "clawsweeper")
        ]
        let snapshot = MenuSnapshot(repositories: snapshotRepos, capturedAt: Date())

        let repos = AppState.actionsRepositories(repositories: [], menuSnapshot: snapshot)

        #expect(repos.map(\.fullName) == ["openclaw/clawsweeper"])
    }

    @Test @MainActor
    func `scans repository runners whenever repositories are available`() {
        let repos = [Self.repo(owner: "openclaw", name: "clawsweeper")]
        let emptyOrgRunners = ActionsRunnerInfo(totalCount: 0, runners: [], fetchedAt: Date())
        let orgRunners = ActionsRunnerInfo(
            totalCount: 1,
            runners: [RunnerSummary(id: 1, name: "mac-mini", os: "macOS", status: "online", busy: false, labels: [])],
            fetchedAt: Date()
        )

        #expect(AppState.shouldScanRepositoryRunners(after: emptyOrgRunners, repos: repos))
        #expect(AppState.shouldScanRepositoryRunners(after: orgRunners, repos: repos))
        #expect(!AppState.shouldScanRepositoryRunners(after: emptyOrgRunners, repos: []))
    }

    @Test @MainActor
    func `combines org and repository scoped runners`() throws {
        let now = Date()
        let orgRunners = ActionsRunnerInfo(
            totalCount: 1,
            runners: [RunnerSummary(id: 1, name: "org-mac", os: "macOS", status: "online", busy: false, labels: [])],
            fetchedAt: now
        )
        let repoRunners = ActionsRunnerInfo(
            totalCount: 3,
            runners: [
                RunnerSummary(id: 1, name: "org-mac-duplicate", os: "macOS", status: "online", busy: false, labels: []),
                RunnerSummary(id: 2, name: "repo-linux", os: "Linux", status: "online", busy: true, labels: []),
                RunnerSummary(id: 3, name: "repo-win", os: "Windows", status: "offline", busy: false, labels: [])
            ],
            fetchedAt: now
        )

        let combined = try #require(AppState.combinedRunnerInfo(
            orgRunners: orgRunners,
            repositoryRunners: [repoRunners],
            scannedRepositoryCount: 5,
            totalRepositoryCount: 12,
            fetchedAt: now
        ))

        #expect(combined.totalCount == 3)
        #expect(combined.runners.map(\.name) == ["org-mac", "repo-linux", "repo-win"])
        #expect(combined.repositorySampleDescription == "Sampled 5 of 12 repos")
    }

    private static func repo(owner: String, name: String) -> Repository {
        Repository(
            id: "\(owner)/\(name)",
            name: name,
            owner: owner,
            sortOrder: 0,
            error: nil,
            rateLimitedUntil: nil,
            ciStatus: .unknown,
            openIssues: 0,
            openPulls: 0,
            latestRelease: nil,
            latestActivity: nil,
            activityEvents: [],
            traffic: nil,
            heatmap: []
        )
    }
}
