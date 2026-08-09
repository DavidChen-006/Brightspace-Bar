import AppKit
import Foundation
import RepoBarCore
import SwiftUI

@MainActor
final class ChangelogMenuCoordinator {
    private let appState: AppState
    private let menuBuilder: StatusBarMenuBuilder
    private let menuItemFactory: MenuItemViewFactory
    private var menus: [ObjectIdentifier: ChangelogMenuEntry] = [:]
    private var cache: [String: ChangelogCacheEntry] = [:]
    private var cacheOrder: [String] = []
    private var inflight: [String: Task<ChangelogFetchResult, Never>] = [:]

    init(appState: AppState, menuBuilder: StatusBarMenuBuilder, menuItemFactory: MenuItemViewFactory) {
        self.appState = appState
        self.menuBuilder = menuBuilder
        self.menuItemFactory = menuItemFactory
    }

    func registerChangelogMenu(_ menu: NSMenu, fullName: String, localStatus: LocalRepoStatus?) {
        self.menus[ObjectIdentifier(menu)] = ChangelogMenuEntry(
            menu: menu,
            fullName: fullName,
            localPath: localStatus?.path
        )
    }

    func pruneMenus() {
        self.menus = self.menus.filter { $0.value.menu != nil }
    }

    func handleMenuWillOpen(_ menu: NSMenu) -> Bool {
        guard let entry = self.menus[ObjectIdentifier(menu)] else { return false }

        self.menuBuilder.refreshMenuViewHeights(in: menu)
        Task { @MainActor [weak self] in
            guard let self else { return }

            await self.refreshChangelogMenu(menu: menu, entry: entry)
        }
        return true
    }

    func cachedPresentation(fullName: String, releaseTag: String?) -> ChangelogRowPresentation? {
        guard var entry = self.cache[fullName],
              let parsed = entry.parsed
        else { return nil }

        let key = releaseTag ?? "__none__"
        if let cached = entry.presentationCache[key] {
            self.touchCache(fullName)
            return cached
        }
        guard let presentation = ChangelogParser.presentation(parsed: parsed, releaseTag: releaseTag) else { return nil }

        entry.presentationCache[key] = presentation
        self.cache[fullName] = entry
        self.touchCache(fullName)
        return presentation
    }

    func cachedHeadline(fullName: String) -> String? {
        guard let parsed = self.cache[fullName]?.parsed else { return nil }

        self.touchCache(fullName)
        return ChangelogParser.headline(parsed: parsed)
    }

    func prefetchChangelog(fullName: String, localPath: URL?, releaseTag: String?) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            let now = Date()
            if let cached = self.cache[fullName] {
                let isFresh = now.timeIntervalSince(cached.fetchedAt) <= AppLimits.Changelog.cacheTTL
                if isFresh {
                    self.touchCache(fullName)
                    self.menuBuilder.updateChangelogRow(fullName: fullName, releaseTag: releaseTag)
                    return
                }
            }

            let fetch = await self.loadChangelog(fullName: fullName, localPath: localPath)
            self.storeCacheEntry(self.makeCacheEntry(fetch: fetch), for: fullName)
            self.menuBuilder.updateChangelogRow(fullName: fullName, releaseTag: releaseTag)
        }
    }

    private func refreshChangelogMenu(menu: NSMenu, entry: ChangelogMenuEntry) async {
        let now = Date()
        if let cached = self.cache[entry.fullName] {
            let isFresh = now.timeIntervalSince(cached.fetchedAt) <= AppLimits.Changelog.cacheTTL
            if isFresh {
                self.touchCache(entry.fullName)
                self.applyResult(cached.result, to: menu)
                self.updateChangelogRow(fullName: entry.fullName)
                return
            }
        }

        if let cached = self.cache[entry.fullName] {
            self.applyResult(cached.result, to: menu)
        } else {
            self.applyLoading(to: menu)
        }

        let fetch = await self.loadChangelog(fullName: entry.fullName, localPath: entry.localPath)
        self.storeCacheEntry(self.makeCacheEntry(fetch: fetch), for: entry.fullName)
        self.applyResult(fetch.result, to: menu)
        self.updateChangelogRow(fullName: entry.fullName)
    }

    private func applyLoading(to menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(self.menuBuilder.infoItem("Loading…"))
        self.menuBuilder.refreshMenuViewHeights(in: menu)
        menu.update()
    }

    private func applyResult(_ result: ChangelogResult, to menu: NSMenu) {
        menu.removeAllItems()
        switch result {
        case .signedOut:
            menu.addItem(self.menuBuilder.infoItem("Sign in to load changelog"))
        case .missing:
            menu.addItem(self.menuBuilder.infoItem("No changelog found"))
        case let .failure(message):
            menu.addItem(self.menuBuilder.infoMessageItem("Changelog failed: \(message)"))
        case let .content(content):
            let view = ChangelogMenuView(content: content)
            menu.addItem(self.menuItemFactory.makeItem(for: view, enabled: false))
        }
        if menu.items.contains(where: { $0.view != nil }) {
            self.menuBuilder.refreshMenuViewHeights(in: menu)
        }
        menu.update()
    }

    private func loadChangelog(fullName: String, localPath: URL?) async -> ChangelogFetchResult {
        if let task = self.inflight[fullName] {
            return await task.value
        }
        let task = Task { @MainActor in
            await self.fetchChangelog(fullName: fullName, localPath: localPath)
        }
        self.inflight[fullName] = task
        let result = await task.value
        self.inflight[fullName] = nil
        return result
    }

    private func updateChangelogRow(fullName: String) {
        let releaseTag = self.appState.session.repositories
            .first(where: { $0.fullName == fullName })?
            .latestRelease?
            .tag
        self.menuBuilder.updateChangelogRow(fullName: fullName, releaseTag: releaseTag)
    }

    private func fetchChangelog(fullName: String, localPath: URL?) async -> ChangelogFetchResult {
        if let localPath, let localResult = self.loadLocalChangelog(root: localPath) {
            return ChangelogFetchResult(result: .content(localResult.content), parsed: localResult.parsed)
        }

        guard case .loggedIn = self.appState.session.account else {
            return ChangelogFetchResult(result: .signedOut, parsed: nil)
        }
        guard let (owner, name) = self.ownerAndName(from: fullName) else {
            return ChangelogFetchResult(result: .failure("Invalid repository"), parsed: nil)
        }

        do {
            let items = try await self.appState.github.repoContents(owner: owner, name: name)
            guard let match = self.matchingChangelogItem(in: items) else {
                return ChangelogFetchResult(result: .missing, parsed: nil)
            }

            let data = try await self.appState.github.repoFileContents(owner: owner, name: name, path: match.path)
            guard let text = String(bytes: data, encoding: .utf8) else {
                return ChangelogFetchResult(result: .failure("Changelog is not UTF-8"), parsed: nil)
            }
            guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return ChangelogFetchResult(result: .missing, parsed: nil)
            }

            let (truncatedText, isTruncated) = self.truncateMarkdown(text)
            let content = ChangelogContent(
                fileName: match.name,
                markdown: truncatedText,
                source: .remote,
                isTruncated: isTruncated
            )
            let parsed = ChangelogParser.parse(markdown: text)
            return ChangelogFetchResult(result: .content(content), parsed: parsed)
        } catch {
            return ChangelogFetchResult(result: .failure(error.userFacingMessage), parsed: nil)
        }
    }

    private func loadLocalChangelog(root: URL) -> ChangelogLocalResult? {
        guard let fileURL = self.localChangelogURL(root: root) else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let text = String(bytes: data, encoding: .utf8) else { return nil }
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }

        let (truncatedText, isTruncated) = self.truncateMarkdown(text)
        let content = ChangelogContent(
            fileName: fileURL.lastPathComponent,
            markdown: truncatedText,
            source: .local,
            isTruncated: isTruncated
        )
        let parsed = ChangelogParser.parse(markdown: text)
        return ChangelogLocalResult(content: content, parsed: parsed)
    }

    private func localChangelogURL(root: URL) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return nil }
        guard let match = self.matchingChangelogName(in: names) else { return nil }

        let url = root.appendingPathComponent(match, isDirectory: false)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue == false
        else { return nil }

        return url
    }

    private func matchingChangelogItem(in items: [RepoContentItem]) -> RepoContentItem? {
        let files = items.filter { $0.type == .file }
        for candidate in Self.changelogCandidates {
            if let match = files.first(where: { $0.name.lowercased() == candidate }) {
                return match
            }
        }
        return nil
    }

    private func matchingChangelogName(in names: [String]) -> String? {
        for candidate in Self.changelogCandidates {
            if let match = names.first(where: { $0.lowercased() == candidate }) {
                return match
            }
        }
        return nil
    }

    private func truncateMarkdown(_ text: String) -> (String, Bool) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var truncated = false
        if lines.count > AppLimits.Changelog.maxLines {
            lines = Array(lines.prefix(AppLimits.Changelog.maxLines))
            truncated = true
        }
        var result = lines.joined(separator: "\n")
        if result.count > AppLimits.Changelog.maxCharacters {
            result = String(result.prefix(AppLimits.Changelog.maxCharacters))
            truncated = true
        }
        return (result.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), truncated)
    }

    private func ownerAndName(from fullName: String) -> (String, String)? {
        let parts = fullName.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }

        return (String(parts[0]), String(parts[1]))
    }

    private static let changelogCandidates: [String] = [
        "changelog.md",
        "changelog"
    ]

    private func makeCacheEntry(fetch: ChangelogFetchResult) -> ChangelogCacheEntry {
        ChangelogCacheEntry(
            fetchedAt: Date(),
            result: fetch.result,
            parsed: fetch.parsed,
            presentationCache: [:]
        )
    }

    private func storeCacheEntry(_ entry: ChangelogCacheEntry, for fullName: String) {
        self.cache[fullName] = entry
        self.touchCache(fullName)
        while self.cache.count > AppLimits.Changelog.cacheEntries, let oldest = self.cacheOrder.first {
            self.cacheOrder.removeFirst()
            self.cache[oldest] = nil
        }
    }

    private func touchCache(_ fullName: String) {
        self.cacheOrder.removeAll { $0 == fullName }
        self.cacheOrder.append(fullName)
    }
}

private final class ChangelogMenuEntry {
    weak var menu: NSMenu?
    let fullName: String
    let localPath: URL?

    init(menu: NSMenu, fullName: String, localPath: URL?) {
        self.menu = menu
        self.fullName = fullName
        self.localPath = localPath
    }
}

private struct ChangelogCacheEntry {
    let fetchedAt: Date
    let result: ChangelogResult
    let parsed: ChangelogParsed?
    var presentationCache: [String: ChangelogRowPresentation]
}

private struct ChangelogFetchResult {
    let result: ChangelogResult
    let parsed: ChangelogParsed?
}

private struct ChangelogLocalResult {
    let content: ChangelogContent
    let parsed: ChangelogParsed
}

private enum ChangelogResult {
    case signedOut
    case missing
    case failure(String)
    case content(ChangelogContent)
}
