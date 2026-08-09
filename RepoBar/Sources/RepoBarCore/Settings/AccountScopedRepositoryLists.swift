import Foundation

/// Pinned and hidden repository lists, partitioned by account ID.
///
/// Entries are stored as `owner/name` to mirror the legacy single-account
/// `RepoListSettings.pinnedRepositories` / `hiddenRepositories` format.
/// Legacy values continue to work via `merged(with:legacyAccountID:)` and
/// `legacyPinned(activeAccountID:)` helpers.
public struct AccountScopedRepositoryLists: Equatable, Codable, Sendable {
    public var pinnedByAccount: [String: [String]]
    public var hiddenByAccount: [String: [String]]

    public init(
        pinnedByAccount: [String: [String]] = [:],
        hiddenByAccount: [String: [String]] = [:]
    ) {
        self.pinnedByAccount = pinnedByAccount
        self.hiddenByAccount = hiddenByAccount
    }

    public var isEmpty: Bool {
        self.pinnedByAccount.isEmpty && self.hiddenByAccount.isEmpty
    }

    public func pinned(for accountID: String) -> [String] {
        self.pinnedByAccount[accountID] ?? []
    }

    public func hidden(for accountID: String) -> [String] {
        self.hiddenByAccount[accountID] ?? []
    }

    public mutating func setPinned(_ items: [String], for accountID: String) {
        let cleaned = Self.normalize(items)
        if cleaned.isEmpty {
            self.pinnedByAccount.removeValue(forKey: accountID)
        } else {
            self.pinnedByAccount[accountID] = cleaned
        }
    }

    public mutating func setHidden(_ items: [String], for accountID: String) {
        let cleaned = Self.normalize(items)
        if cleaned.isEmpty {
            self.hiddenByAccount.removeValue(forKey: accountID)
        } else {
            self.hiddenByAccount[accountID] = cleaned
        }
    }

    /// Returns pinned items for `accountID`, falling back to legacy single-list
    /// entries when no per-account entry exists. Useful while migrating UI to
    /// multi-account without breaking single-account users.
    public func pinned(for accountID: String, legacy: [String]) -> [String] {
        if let perAccount = self.pinnedByAccount[accountID], perAccount.isEmpty == false {
            return perAccount
        }
        return legacy
    }

    public func hidden(for accountID: String, legacy: [String]) -> [String] {
        if let perAccount = self.hiddenByAccount[accountID], perAccount.isEmpty == false {
            return perAccount
        }
        return legacy
    }

    private static func normalize(_ items: [String]) -> [String] {
        var seen: Set<String> = []
        return items.compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return nil }

            let lower = trimmed.lowercased()
            guard seen.insert(lower).inserted else { return nil }

            return trimmed
        }
    }
}
