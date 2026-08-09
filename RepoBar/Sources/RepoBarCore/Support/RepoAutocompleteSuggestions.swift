import Foundation

public enum RepoAutocompleteSuggestions {
    public static func suggestions(
        query: String,
        prefetched: [Repository],
        limit: Int,
        localBonus: Int = 30,
        showRecentsForEmptyQuery: Bool = true
    ) -> [Repository] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            guard showRecentsForEmptyQuery else { return [] }

            return Array(prefetched.prefix(max(limit, 0)))
        }

        let localScored = RepoAutocompleteScoring.scored(
            repos: prefetched,
            query: trimmed,
            sourceRank: 0,
            bonus: localBonus
        )
        let sortedLocal = RepoAutocompleteScoring.sort(localScored)
        return Array(sortedLocal.prefix(max(limit, 0))).map(\.repo)
    }
}
