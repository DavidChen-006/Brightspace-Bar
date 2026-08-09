import Foundation

public enum OwnerFilter {
    public static func normalize(_ owners: [String]) -> [String] {
        let normalized = owners
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        return Array(Set(normalized)).sorted()
    }
}
