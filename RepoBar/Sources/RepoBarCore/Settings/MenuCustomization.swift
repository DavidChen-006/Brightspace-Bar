import Foundation

public enum MainMenuItemGroup: String, Hashable, Sendable {
    case auth
    case header
    case status
    case filters
    case repos
    case footer
}

public enum MainMenuItemID: String, CaseIterable, Codable, Hashable, Sendable {
    case loggedOutPrompt
    case signInAction
    case contributionHeader
    case statusBanner
    case rateLimits
    case actionsLimits
    case filters
    case repoList
    case issueNavigator
    case preferences
    case about
    case restartToUpdate
    case quit

    public var title: String {
        switch self {
        case .loggedOutPrompt: "Account Status"
        case .signInAction: "Sign In"
        case .contributionHeader: "Contribution Header"
        case .statusBanner: "Status Banner"
        case .rateLimits: "GitHub API Status"
        case .actionsLimits: "Actions & Runners"
        case .filters: "Menu Filters"
        case .repoList: "Repository Cards"
        case .issueNavigator: "Issue Navigator"
        case .preferences: "Preferences"
        case .about: "About RepoBar"
        case .restartToUpdate: "Restart to Update"
        case .quit: "Quit RepoBar"
        }
    }

    public var subtitle: String? {
        switch self {
        case .loggedOutPrompt: "Login state banner"
        case .signInAction: "GitHub sign-in action"
        case .contributionHeader: "Heatmap header + submenu"
        case .statusBanner: "Rate-limit or error banner"
        case .rateLimits: "Current blocker and rate-limit diagnostics"
        case .actionsLimits: "Runner status, queue depth, and usage"
        case .filters: "Pinned/hidden filter chips"
        case .repoList: "Repo cards + inline heatmap"
        case .issueNavigator: "Fast issue and pull request search"
        case .preferences: nil
        case .about: nil
        case .restartToUpdate: "Shown when an update is ready"
        case .quit: nil
        }
    }

    public var group: MainMenuItemGroup {
        switch self {
        case .loggedOutPrompt, .signInAction: .auth
        case .contributionHeader: .header
        case .statusBanner, .rateLimits, .actionsLimits: .status
        case .filters: .filters
        case .repoList: .repos
        case .issueNavigator, .preferences, .about, .restartToUpdate, .quit: .footer
        }
    }
}

public enum RepoSubmenuItemGroup: String, Hashable, Sendable {
    case open
    case local
    case lists
    case heatmap
    case commits
    case activity
    case manage
}

public enum RepoSubmenuItemID: String, CaseIterable, Codable, Hashable, Sendable {
    case openOnGitHub
    case openInFinder
    case openInTerminal
    case checkoutRepo
    case localState
    case worktrees
    case issues
    case pulls
    case releases
    case changelog
    case ciRuns
    case discussions
    case tags
    case branches
    case contributors
    case heatmap
    case commits
    case activity
    case pinToggle
    case hideRepo
    case moveUp
    case moveDown

    public var title: String {
        switch self {
        case .openOnGitHub: "Open on GitHub"
        case .openInFinder: "Open in Finder"
        case .openInTerminal: "Open in Terminal"
        case .checkoutRepo: "Checkout Repo"
        case .localState: "Local Repo Status"
        case .worktrees: "Worktrees"
        case .issues: "Issues"
        case .pulls: "Pull Requests"
        case .releases: "Releases"
        case .changelog: "Changelog"
        case .ciRuns: "CI Runs"
        case .discussions: "Discussions"
        case .tags: "Tags"
        case .branches: "Branches"
        case .contributors: "Contributors"
        case .heatmap: "Heatmap"
        case .commits: "Commits"
        case .activity: "Activity"
        case .pinToggle: "Pin/Unpin"
        case .hideRepo: "Hide Repo"
        case .moveUp: "Move Up"
        case .moveDown: "Move Down"
        }
    }

    public var subtitle: String? {
        switch self {
        case .openOnGitHub: "Open repository in browser"
        case .openInFinder: "Local checkout"
        case .openInTerminal: "Local checkout"
        case .checkoutRepo: "Clone or checkout"
        case .localState: "Sync + dirty state"
        case .worktrees: "Switch or create worktrees"
        case .issues: "Recent issues list"
        case .pulls: "Recent pull requests"
        case .releases: "Recent releases list"
        case .changelog: "Inline markdown preview"
        case .ciRuns: "Recent CI runs"
        case .discussions: "Recent discussions"
        case .tags: "Recent tags"
        case .branches: "Branch menu"
        case .contributors: "Recent contributors"
        case .heatmap: "Repo heatmap submenu"
        case .commits: "Commit list preview"
        case .activity: "Activity feed preview"
        case .pinToggle: nil
        case .hideRepo: nil
        case .moveUp: nil
        case .moveDown: nil
        }
    }

    public var group: RepoSubmenuItemGroup {
        switch self {
        case .openOnGitHub: .open
        case .openInFinder, .openInTerminal, .checkoutRepo, .localState, .worktrees: .local
        case .changelog: .open
        case .issues, .pulls, .releases, .ciRuns, .discussions, .tags, .branches, .contributors: .lists
        case .heatmap: .heatmap
        case .commits: .commits
        case .activity: .activity
        case .pinToggle, .hideRepo, .moveUp, .moveDown: .manage
        }
    }
}

public struct MenuCustomization: Equatable, Codable, Hashable, Sendable {
    public var hiddenMainMenuItems: Set<MainMenuItemID> = [.actionsLimits]
    public var mainMenuOrder: [MainMenuItemID] = Self.defaultMainMenuOrder
    public var hiddenRepoSubmenuItems: Set<RepoSubmenuItemID> = []
    public var repoSubmenuOrder: [RepoSubmenuItemID] = Self.defaultRepoSubmenuOrder

    public init() {}

    public mutating func normalize() {
        let originalRepoOrder = self.repoSubmenuOrder
        self.mainMenuOrder = Self.normalizedOrder(self.mainMenuOrder, defaults: Self.defaultMainMenuOrder)
        Self.moveMainMenuItem(.rateLimits, after: .statusBanner, in: &self.mainMenuOrder)
        Self.moveMainMenuItem(.actionsLimits, after: .rateLimits, in: &self.mainMenuOrder)
        self.repoSubmenuOrder = Self.normalizedOrder(self.repoSubmenuOrder, defaults: Self.defaultRepoSubmenuOrder)
        if originalRepoOrder.contains(.changelog) == false {
            self.repoSubmenuOrder.removeAll { $0 == .changelog }
            if let openIndex = self.repoSubmenuOrder.firstIndex(of: .openOnGitHub) {
                self.repoSubmenuOrder.insert(.changelog, at: openIndex + 1)
            } else {
                self.repoSubmenuOrder.insert(.changelog, at: 0)
            }
        }
    }

    public func normalized() -> MenuCustomization {
        var copy = self
        copy.normalize()
        return copy
    }

    public static let requiredMainMenuItems: Set<MainMenuItemID> = [
        .preferences,
        .about,
        .quit
    ]

    public static let defaultMainMenuOrder: [MainMenuItemID] = [
        .loggedOutPrompt,
        .signInAction,
        .contributionHeader,
        .statusBanner,
        .rateLimits,
        .actionsLimits,
        .filters,
        .repoList,
        .issueNavigator,
        .preferences,
        .about,
        .restartToUpdate,
        .quit
    ]

    public static let defaultRepoSubmenuOrder: [RepoSubmenuItemID] = [
        .openOnGitHub,
        .changelog,
        .openInFinder,
        .openInTerminal,
        .checkoutRepo,
        .localState,
        .worktrees,
        .issues,
        .pulls,
        .releases,
        .ciRuns,
        .discussions,
        .tags,
        .branches,
        .contributors,
        .heatmap,
        .commits,
        .activity,
        .pinToggle,
        .hideRepo
    ]

    private static func normalizedOrder<T: Hashable>(_ order: [T], defaults: [T]) -> [T] {
        var seen = Set<T>()
        var result: [T] = []
        let allowed = Set(defaults)
        for item in order where allowed.contains(item) && seen.insert(item).inserted {
            result.append(item)
        }
        for item in defaults where seen.insert(item).inserted {
            result.append(item)
        }
        return result
    }

    private static func moveMainMenuItem(
        _ item: MainMenuItemID,
        after anchor: MainMenuItemID,
        in order: inout [MainMenuItemID]
    ) {
        guard let itemIndex = order.firstIndex(of: item),
              let anchorIndex = order.firstIndex(of: anchor) else { return }

        order.remove(at: itemIndex)
        let adjustedAnchorIndex = itemIndex < anchorIndex ? anchorIndex - 1 : anchorIndex
        order.insert(item, at: min(adjustedAnchorIndex + 1, order.count))
    }
}

public extension MainMenuItemID {
    var isRequired: Bool {
        MenuCustomization.requiredMainMenuItems.contains(self)
    }
}
