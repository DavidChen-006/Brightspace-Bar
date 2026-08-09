import Commander
import Foundation
import RepoBarCore

struct OnlyWithSelection: ExpressibleFromArgument {
    let filter: RepositoryOnlyWith

    init?(argument: String) {
        let rawTokens = argument
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        var requireIssues = false
        var requirePRs = false

        for token in rawTokens {
            switch token {
            case "work":
                requireIssues = true
                requirePRs = true
            case "issues", "issue":
                requireIssues = true
            case "prs", "pr", "pulls", "pull":
                requirePRs = true
            default:
                return nil
            }
        }

        guard requireIssues || requirePRs else { return nil }

        self.filter = RepositoryOnlyWith(requireIssues: requireIssues, requirePRs: requirePRs)
    }
}
