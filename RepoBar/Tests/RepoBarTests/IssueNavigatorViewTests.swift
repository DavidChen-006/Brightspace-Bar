import Foundation
@testable import RepoBar
@testable import RepoBarCore
import Testing

struct IssueNavigatorViewTests {
    @MainActor
    private final class PlatformRecorder {
        var openedURL: URL?
        var copiedURL: URL?
    }

    @Test
    func `initial reference matches do not get overwritten by clipboard seed`() {
        #expect(!IssueNavigatorView.shouldSeedClipboardOnAppear(hasInitialMatches: true))
        #expect(IssueNavigatorView.shouldSeedClipboardOnAppear(hasInitialMatches: false))
    }

    @Test
    func `decorated issue navigator labels remain parseable for manual search`() {
        let queries = GitHubReferenceTranslator.queries(from: "1. openclaw/gogcli#673 · 1 PR · add --thread-id to G")

        #expect(queries == [.repositoryIssueNumber(repositoryFullName: "openclaw/gogcli", number: 673)])
    }

    @Test
    func `unresolved metadata uses reference label in navigator chrome`() throws {
        let match = try GitHubReferenceMatch(
            query: .repositoryIssueNumber(repositoryFullName: "openclaw/imsg", number: 135),
            title: "GitHub preview unavailable",
            url: #require(URL(string: "https://github.com/openclaw/imsg/issues/135")),
            repositoryFullName: "openclaw/imsg",
            kind: .issue,
            state: nil,
            createdAt: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            isResolved: false
        )

        #expect(match.issueNavigatorHeaderTitle == "openclaw/imsg#135")
        #expect(match.issueNavigatorTitle == "openclaw/imsg#135")
    }

    @Test
    @MainActor
    func `model owns clipboard and platform actions`() throws {
        let match = try Self.makeMatch()
        let recorder = PlatformRecorder()
        let model = IssueNavigatorModel(
            appState: AppState(),
            initialMatches: [match],
            browserStore: IssueNavigatorBrowserStore(),
            platform: .init(
                readClipboard: { " openclaw/imsg#135 " },
                openURL: { recorder.openedURL = $0 },
                copyURL: { recorder.copiedURL = $0 }
            )
        )

        model.updateClipboard(seedIfEmpty: true)
        model.openSelected()
        model.copySelected()

        #expect(model.searchText == "openclaw/imsg#135")
        #expect(model.clipboardDisplayText == "openclaw/imsg#135")
        #expect(!model.shouldShowClipboardPrompt)
        #expect(recorder.openedURL == match.url)
        #expect(recorder.copiedURL == match.url)
    }

    @Test
    @MainActor
    func `model preserves initial order and repairs missing selection`() throws {
        let first = try Self.makeMatch(number: 2)
        let second = try Self.makeMatch(number: 1)
        let model = IssueNavigatorModel(
            appState: AppState(),
            initialMatches: [first, second, first],
            browserStore: IssueNavigatorBrowserStore(),
            platform: .init(readClipboard: { nil }, openURL: { _ in }, copyURL: { _ in })
        )

        #expect(model.results.map(\.url) == [first.url, second.url])
        model.selectedURL = nil
        model.ensureSelection()
        #expect(model.selectedURL == first.url)
    }

    private static func makeMatch(number: Int = 135) throws -> GitHubReferenceMatch {
        try GitHubReferenceMatch(
            query: .repositoryIssueNumber(repositoryFullName: "openclaw/imsg", number: number),
            title: "Issue \(number)",
            url: #require(URL(string: "https://github.com/openclaw/imsg/issues/\(number)")),
            repositoryFullName: "openclaw/imsg",
            kind: .issue,
            state: .open,
            createdAt: nil,
            updatedAt: Date(timeIntervalSince1970: TimeInterval(number)),
            isResolved: true
        )
    }
}
