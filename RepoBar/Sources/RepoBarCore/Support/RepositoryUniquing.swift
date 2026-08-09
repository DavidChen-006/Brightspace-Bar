import Foundation

public enum RepositoryUniquing {
    public static func byFullName(_ repos: [Repository]) -> [Repository] {
        var seen: Set<String> = []
        return repos.filter { repo in
            seen.insert(repo.fullName.lowercased()).inserted
        }
    }
}
