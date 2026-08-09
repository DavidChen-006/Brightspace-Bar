import AppKit
import RepoBarCore

extension StatusBarMenuBuilder {
    func contributionSubmenu(username: String, displayName: String) -> NSMenu {
        self.target.activityMenuCoordinator.contributionSubmenu(username: username, displayName: displayName)
    }

    func activityMenuItem(for event: ActivityEvent) -> NSMenuItem {
        self.target.activityMenuCoordinator.activityMenuItem(for: event)
    }

    func commitMenuItem(for commit: RepoCommitSummary) -> NSMenuItem {
        self.target.activityMenuCoordinator.commitMenuItem(for: commit)
    }
}
