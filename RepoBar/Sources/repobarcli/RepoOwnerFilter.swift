import Foundation
import RepoBarCore

struct RepoOwnerFilter: Equatable {
    let owners: Set<String>

    static func parse(_ values: [String]) -> RepoOwnerFilter? {
        let parsed = values
            .flatMap { $0.split(separator: ",") }
            .compactMap { self.normalizeOwner(String($0)) }
        let owners = Set(parsed)
        return owners.isEmpty ? nil : RepoOwnerFilter(owners: owners)
    }

    func applying(to repos: [Repository]) -> [Repository] {
        repos.filter { self.owners.contains($0.owner.lowercased()) }
    }

    func inserting(owner: String) -> RepoOwnerFilter {
        let normalized = Self.normalizeOwner(owner) ?? owner.lowercased()
        var merged = self.owners
        merged.insert(normalized)
        return RepoOwnerFilter(owners: merged)
    }

    private static func normalizeOwner(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        let owner = trimmed.split(separator: "/", maxSplits: 1).first.map(String.init) ?? trimmed
        let normalized = owner.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}
