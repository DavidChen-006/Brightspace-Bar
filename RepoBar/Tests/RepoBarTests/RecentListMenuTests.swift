import AppKit
@testable import RepoBar
import RepoBarCore
import Testing

struct RecentListMenuTests {
    @MainActor
    @Test
    func `recent list cache evicts least recently used entry`() {
        let cache = RecentListCache<Int>(maxEntries: 2)
        let now = Date(timeIntervalSinceReferenceDate: 1000)

        cache.store([1], for: "one", fetchedAt: now)
        cache.store([2], for: "two", fetchedAt: now)
        #expect(cache.stale(for: "one") == [1])
        cache.store([3], for: "three", fetchedAt: now)

        #expect(cache.count() == 2)
        #expect(cache.stale(for: "one") == [1])
        #expect(cache.stale(for: "two") == nil)
        #expect(cache.stale(for: "three") == [3])
    }

    @MainActor
    @Test
    func `recent list menus survive main menu open`() {
        let appState = AppState()
        let manager = StatusBarMenuManager(appState: appState)
        let mainMenu = NSMenu()
        let submenu = NSMenu()

        manager.setMainMenuForTesting(mainMenu)
        manager.registerRecentListMenu(
            submenu,
            context: RepoRecentMenuContext(fullName: "owner/repo", kind: .issues)
        )

        manager.menuWillOpen(mainMenu)

        #expect(manager.isRecentListMenu(submenu))
    }

    @MainActor
    @Test
    func `recent list menus survive filter rebuild`() async throws {
        let appState = AppState()
        let manager = StatusBarMenuManager(appState: appState)
        let mainMenu = NSMenu()
        let submenu = NSMenu()

        manager.setMainMenuForTesting(mainMenu)
        manager.registerRecentListMenu(
            submenu,
            context: RepoRecentMenuContext(fullName: "owner/repo", kind: .issues)
        )

        manager.menuFiltersChanged()
        try await Task.sleep(for: .milliseconds(50))

        #expect(manager.isRecentListMenu(submenu))
    }

    @MainActor
    @Test
    func `recent list failures show user facing reason`() {
        let error = GitHubAPIError.badStatus(code: 403, message: "Requires repository issues access.")

        #expect(
            RecentListMenuCoordinator.failureMessage(for: error) ==
                "Failed: Requires repository issues access."
        )
    }

    @MainActor
    @Test
    func `recent list timeouts include configured seconds`() {
        #expect(RecentListMenuCoordinator.timeoutMessage(timeout: 12) == "Timed out after 12s")
    }

    @MainActor
    @Test
    func `recent list rate limit message is visible`() {
        let reset = Date(timeIntervalSinceNow: 120)
        let error = GitHubAPIError.rateLimited(until: reset, message: "GitHub rate limit hit.")

        #expect(RecentListMenuCoordinator.rateLimitMessage(for: error)?.contains("GitHub rate limited; resets") == true)
        #expect(RecentListMenuCoordinator.rateLimitMessage(for: URLError(.timedOut)) == nil)
    }

    @MainActor
    @Test
    func `multi reference menu offers issue navigator action at end`() throws {
        let appState = AppState()
        let manager = StatusBarMenuManager(appState: appState)
        let menu = NSMenu()
        let matches = try [
            Self.makeReference(number: 1),
            Self.makeReference(number: 2)
        ]

        manager.populateGitHubReferenceMenuForTesting(menu, matches: matches)

        let titles = menu.items.map(\.title)
        #expect(Array(titles.suffix(2)) == ["", "Open 2 refs in Issue Navigator…"])
        #expect(menu.items.last?.target is GitHubReferenceStatusCoordinator)
    }

    @MainActor
    @Test
    func `multi reference status item uses click action instead of attached menu`() throws {
        let appState = AppState()
        let manager = StatusBarMenuManager(appState: appState)
        let matches = try [
            Self.makeReference(number: 1),
            Self.makeReference(number: 2)
        ]

        appState.session.gitHubReferenceMatches = matches
        appState.session.gitHubReferenceMatch = matches.first
        manager.syncGitHubReferenceStatusItemForTesting()

        let item = try #require(manager.gitHubReferenceStatusItemForTesting())
        let button = try #require(item.button)
        #expect(item.menu == nil)
        #expect(button.target is GitHubReferenceStatusCoordinator)
        #expect(button.action == #selector(GitHubReferenceStatusCoordinator.statusItemClicked(_:)))
    }

    private static func makeReference(number: Int) throws -> GitHubReferenceMatch {
        let url = try #require(URL(string: "https://github.com/owner/repo/issues/\(number)"))
        return GitHubReferenceMatch(
            query: .repositoryIssueNumber(repositoryFullName: "owner/repo", number: number),
            title: "Issue \(number)",
            url: url,
            repositoryFullName: "owner/repo",
            kind: .issue,
            state: .open,
            createdAt: Date(timeIntervalSinceReferenceDate: TimeInterval(number)),
            updatedAt: Date(timeIntervalSinceReferenceDate: TimeInterval(number))
        )
    }
}
