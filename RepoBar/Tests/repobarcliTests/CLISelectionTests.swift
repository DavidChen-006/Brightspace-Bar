@testable import repobarcli
import RepoBarCore
import Testing

struct CLISelectionTests {
    @Test
    func `scope selection parses values`() {
        #expect(RepoScopeSelection(argument: "all") == .all)
        #expect(RepoScopeSelection(argument: "Pinned") == .pinned)
        #expect(RepoScopeSelection(argument: "hidden") == .hidden)
    }

    @Test
    func `filter selection parses values`() {
        #expect(RepoFilterSelection(argument: "all") == .all)
        #expect(RepoFilterSelection(argument: "work") == .work)
        #expect(RepoFilterSelection(argument: "issues") == .issues)
        #expect(RepoFilterSelection(argument: "pr") == .prs)
    }

    @Test
    func `filter selection maps to only with`() {
        #expect(RepoFilterSelection.all.onlyWith == .none)
        #expect(RepoFilterSelection.work.onlyWith == RepositoryOnlyWith(requireIssues: true, requirePRs: true))
        #expect(RepoFilterSelection.issues.onlyWith == RepositoryOnlyWith(requireIssues: true))
        #expect(RepoFilterSelection.prs.onlyWith == RepositoryOnlyWith(requirePRs: true))
    }

    @Test
    func `activity scope parses values`() {
        #expect(GlobalActivityScope(argument: "all") == .allActivity)
        #expect(GlobalActivityScope(argument: "my") == .myActivity)
        #expect(GlobalActivityScope(argument: "mine") == .myActivity)
    }
}
