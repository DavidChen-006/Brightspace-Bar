import AppKit
import RepoBarCore

extension StatusBarMenuBuilder {
    func makeRepoSubmenu(for repo: RepositoryDisplayModel, isPinned: Bool) -> NSMenu {
        RepoSubmenuBuilder(menuBuilder: self).makeRepoSubmenu(for: repo, isPinned: isPinned)
    }
}
