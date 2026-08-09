import Foundation
@testable import RepoBarCore
import Testing

struct LocalRepoStatusTests {
    @Test
    func `sync detail formats counts`() {
        let status = LocalRepoStatus(
            path: URL(fileURLWithPath: "/tmp"),
            name: "Repo",
            fullName: nil,
            branch: "main",
            isClean: true,
            aheadCount: nil,
            behindCount: 2,
            syncState: .behind,
            dirtyCounts: nil
        )
        #expect(status.syncDetail == "Behind 2")
    }

    @Test
    func `sync detail includes dirty summary`() {
        let status = LocalRepoStatus(
            path: URL(fileURLWithPath: "/tmp"),
            name: "Repo",
            fullName: nil,
            branch: "main",
            isClean: false,
            aheadCount: nil,
            behindCount: nil,
            syncState: .dirty,
            dirtyCounts: LocalDirtyCounts(added: 1, modified: 2, deleted: 3)
        )
        #expect(status.syncDetail == "Dirty (+1 -3 ~2)")
    }

    @Test
    func `can auto sync requires clean behind`() {
        let status = LocalRepoStatus(
            path: URL(fileURLWithPath: "/tmp"),
            name: "Repo",
            fullName: nil,
            branch: "main",
            isClean: true,
            aheadCount: 0,
            behindCount: 1,
            syncState: .behind
        )
        #expect(status.canAutoSync == true)
    }

    @Test
    func `can auto sync rejects detached`() {
        let status = LocalRepoStatus(
            path: URL(fileURLWithPath: "/tmp"),
            name: "Repo",
            fullName: nil,
            branch: "detached",
            isClean: true,
            aheadCount: 0,
            behindCount: 1,
            syncState: .behind
        )
        #expect(status.canAutoSync == false)
    }

    @Test
    func `local dirty counts summary ordering`() {
        let counts = LocalDirtyCounts(added: 2, modified: 1, deleted: 0)
        #expect(counts.summary == "+2 ~1")
        #expect(counts.isEmpty == false)
    }

    @Test
    func `local sync state resolve and labels`() {
        #expect(LocalSyncState.resolve(isClean: true, ahead: 0, behind: 0) == .synced)
        #expect(LocalSyncState.resolve(isClean: true, ahead: 0, behind: 2) == .behind)
        #expect(LocalSyncState.resolve(isClean: true, ahead: 1, behind: 0) == .ahead)
        #expect(LocalSyncState.resolve(isClean: true, ahead: 1, behind: 2) == .diverged)
        #expect(LocalSyncState.resolve(isClean: false, ahead: 0, behind: 0) == .dirty)
        #expect(LocalSyncState.resolve(isClean: true, ahead: nil, behind: nil) == .unknown)
        #expect(LocalSyncState.ahead.symbolName == "arrow.up.square")
        #expect(LocalSyncState.unknown.accessibilityLabel == "No upstream")
    }
}
