@testable import RepoBar
@testable import RepoBarCore
import Testing

@MainActor
struct GitHubReferenceLineScopedTests {
    @Test
    func `recommendation list keeps fs safe PR scoped to repository`() {
        let text = """
          10 I’d Do

          1. openclaw/telecrawl PR #3: Archive Telegram Postbox media. Clean, checks green.
          2. openclaw/crawlbar PR #8: brand icon asset guard. Clean, checks green, likely easy land.
          3. openclaw/agent-skills PR #5: frontmatter trigger accuracy. Checks green, good maintainer hygiene.
          4. openclaw/agent-skills PR #8: validation/installer ergonomics. Clean, no checks shown; run validation.
          5. openclaw/acpx issue #344: troubleshooting docs for ACP init/mapping. Label says queueable + clear fix.
          6. openclaw/clawbench issue #28: shell=False whitespace splitting bug. Current-main repro + clear fix.
          7. openclaw/fs-safe PR #27: EPERM move fallback. Useful bug fix; needs local proof.
          8. openclaw/wacli PR #271: bound direct media HTTP downloads. Important safety fix; checks green.
          9. steipete/RepoBar issue #70: “update from About” bug. Fresh, small app bug.
          10. openclaw/clawgo PR #1: default policy edge tests + Go 1.26. Clean, no checks; quick local gate.
        """

        let queries = GitHubReferenceTranslator.queries(from: text)
        #expect(queries.contains(
            .repositoryIssueNumber(repositoryFullName: "openclaw/fs-safe", number: 27)
        ))
        #expect(!queries.contains(.issueNumber(27)))
    }

    @Test
    func `same issue number can still inherit override on another line`() {
        let text = """
          other/repo PR #7: scoped external reference.
          #7 selected repository follow-up.
        """

        #expect(GitHubReferenceTranslator.queries(
            from: text,
            repositoryContextOverride: "current/repo"
        ) == [
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 7),
            .repositoryIssueNumber(repositoryFullName: "current/repo", number: 7)
        ])
    }

    @Test
    func `repository scoped PR series does not leak to override context`() {
        #expect(GitHubReferenceTranslator.queries(
            from: "other/repo PR #7 and #8",
            repositoryContextOverride: "current/repo"
        ) == [
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 7),
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 8)
        ])
        #expect(GitHubReferenceTranslator.queries(
            from: "other/repo PR 7 and 8",
            repositoryContextOverride: "current/repo"
        ) == [
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 7),
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 8)
        ])
        #expect(GitHubReferenceTranslator.queries(
            from: "other/repo pull requests #7 and #8",
            repositoryContextOverride: "current/repo"
        ) == [
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 7),
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 8)
        ])
        #expect(GitHubReferenceTranslator.queries(
            from: "other/repo PR #7 and PR #8",
            repositoryContextOverride: "current/repo"
        ) == [
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 7),
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 8)
        ])
        #expect(GitHubReferenceTranslator.queries(
            from: "other/repo issue #7 and PR #8",
            repositoryContextOverride: "current/repo"
        ) == [
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 7),
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 8)
        ])
        #expect(GitHubReferenceTranslator.queries(
            from: "other/repo gh-42",
            repositoryContextOverride: "current/repo"
        ) == [
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 42)
        ])
        #expect(GitHubReferenceTranslator.queries(
            from: "openclaw/openclaw.ai PR #132",
            repositoryContextOverride: "current/repo"
        ) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/openclaw.ai", number: 132)
        ])
        #expect(GitHubReferenceTranslator.queries(
            from: "other/repo: PR 7",
            repositoryContextOverride: "current/repo"
        ) == [
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 7)
        ])
        #expect(GitHubReferenceTranslator.queries(
            from: "Status: other/repo PR 7",
            repositoryContextOverride: "current/repo"
        ) == [
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 7)
        ])
        #expect(GitHubReferenceTranslator.queries(
            from: "other/repo PR #7. #8 belongs to the current repo",
            repositoryContextOverride: "current/repo"
        ) == [
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 7),
            .repositoryIssueNumber(repositoryFullName: "current/repo", number: 8)
        ])
        #expect(GitHubReferenceTranslator.queries(
            from: "other/repo PR #7. PR #7 belongs to the current repo",
            repositoryContextOverride: "current/repo"
        ) == [
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 7),
            .repositoryIssueNumber(repositoryFullName: "current/repo", number: 7)
        ])
        #expect(GitHubReferenceTranslator.queries(
            from: "other/repo #18 also affects PR 18",
            repositoryContextOverride: "current/repo"
        ) == [
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 18),
            .repositoryIssueNumber(repositoryFullName: "current/repo", number: 18)
        ])
        #expect(GitHubReferenceTranslator.queries(from: "other/repo #18 also affects PR 18") == [
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 18),
            .issueNumber(18)
        ])
        let mixedContextQueries = GitHubReferenceTranslator.queries(from: """
          Found in current/repo.
          1. #1
          2. other/repo PR #2
        """)
        #expect(mixedContextQueries.count == 2)
        #expect(mixedContextQueries.contains(.repositoryIssueNumber(repositoryFullName: "current/repo", number: 1)))
        #expect(mixedContextQueries.contains(.repositoryIssueNumber(repositoryFullName: "other/repo", number: 2)))
        #expect(GitHubReferenceTranslator.queries(
            from: "other/repo: #7. #8 belongs to the current repo",
            repositoryContextOverride: "current/repo"
        ) == [
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 7),
            .repositoryIssueNumber(repositoryFullName: "current/repo", number: 8)
        ])
        #expect(GitHubReferenceTranslator.queries(
            from: "other/repo PR #7; #8 belongs to the current repo",
            repositoryContextOverride: "current/repo"
        ) == [
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 7),
            .repositoryIssueNumber(repositoryFullName: "current/repo", number: 8)
        ])
        #expect(GitHubReferenceTranslator.queries(
            from: "other/repo PR #7.) #8 belongs to the current repo",
            repositoryContextOverride: "current/repo"
        ) == [
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 7),
            .repositoryIssueNumber(repositoryFullName: "current/repo", number: 8)
        ])
        #expect(GitHubReferenceTranslator.queries(
            from: "other/repo PR #7.\" #8 belongs to the current repo",
            repositoryContextOverride: "current/repo"
        ) == [
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 7),
            .repositoryIssueNumber(repositoryFullName: "current/repo", number: 8)
        ])
        #expect(GitHubReferenceTranslator.queries(from: "other/repo requests 2 reviewers").isEmpty)
        #expect(GitHubReferenceTranslator.queries(
            from: "other/repo PR 7",
            minimumBareDigits: 3,
            repositoryContextOverride: "current/repo"
        ).isEmpty)
        #expect(GitHubReferenceTranslator.queries(
            from: "other/repo PR #7",
            minimumBareDigits: 3,
            repositoryContextOverride: "current/repo"
        ) == [
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 7)
        ])
    }
}
