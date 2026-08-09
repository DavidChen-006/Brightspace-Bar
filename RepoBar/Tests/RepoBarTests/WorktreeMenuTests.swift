import AppKit
@testable import RepoBar
import Testing

struct WorktreeMenuTests {
    @MainActor
    @Test
    func `worktree menu item wires action and payload`() {
        let manager = StatusBarMenuManager(appState: AppState())
        let path = URL(fileURLWithPath: "/tmp/worktree", isDirectory: true)
        let model = LocalRefMenuRowViewModel(
            kind: .worktree,
            title: "/tmp/worktree",
            detail: "main",
            isCurrent: true,
            isDetached: false,
            upstream: nil,
            aheadCount: nil,
            behindCount: nil,
            lastCommitDate: nil,
            lastCommitAuthor: nil,
            dirtySummary: nil
        )
        let item = manager.makeLocalWorktreeMenuItemForTesting(model, path: path, fullName: "owner/repo")

        #expect(item.target != nil)
        #expect(item.action != nil)
        #expect(manager.isWorktreeMenuItemForTesting(item))
    }
}
