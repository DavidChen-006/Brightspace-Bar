import Foundation
@testable import RepoBarCore
import Testing

@MainActor
struct GitHubReferenceRepositoryHeadingTests {
    @Test
    func `indented references inherit repository heading list item context`() {
        let text = """
          - openclaw/Tachikoma: 1 issue / 1 PR
            #18 closes #17, 24 additions / 1 deletion, focused ANTHROPIC_BASE_URL bugfix + test.
          - openclaw/clawdex: 0 issues / 1 PR
            #1 removes the default personal backup remote, makes init local-only, updates docs/tests.
          - steipete/oracle: 0 issues / 1 PR
            #225 Dependabot group bump, 12 deps, package + lockfile only.
          - openclaw/casa: 1 issue / 1 PR
            #2 tiny HomeKit JSON fix for NaN/Infinity, 9 additions / 2 deletions.
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18),
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 17),
            .repositoryIssueNumber(repositoryFullName: "openclaw/clawdex", number: 1),
            .repositoryIssueNumber(repositoryFullName: "steipete/oracle", number: 225),
            .repositoryIssueNumber(repositoryFullName: "openclaw/casa", number: 2)
        ])
    }

    @Test
    func `indented references inherit bare repository heading context`() {
        let text = """
        openclaw/Tachikoma: 1 issue / 1 PR
          #18 closes #17.
        openclaw/clawdex: 0 issues / 1 PR
          #1 removes the default personal backup remote.
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18),
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 17),
            .repositoryIssueNumber(repositoryFullName: "openclaw/clawdex", number: 1)
        ])
    }

    @Test
    func `repository heading list context stops at unindented lines`() {
        let text = """
        - openclaw/Tachikoma: 1 issue / 1 PR
        #18 should stay unscoped outside the list item block.
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [.issueNumber(18)])
    }

    @Test
    func `repository heading list context does not suppress same-number references outside block`() {
        let text = """
        - openclaw/Tachikoma: 1 issue / 1 PR
          #18 belongs to Tachikoma.
        #18 should stay unscoped outside the list item block.
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18),
            .issueNumber(18)
        ])
    }

    @Test
    func `repository heading parser preserves leading indentation for sibling items`() {
        let text = """
          - openclaw/Tachikoma: 1 issue / 1 PR
            #18 belongs to Tachikoma.
          - #99 stays a sibling.
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18),
            .issueNumber(99)
        ])
    }

    @Test
    func `repository heading list references stay before later urls`() {
        let text = """
        - openclaw/Tachikoma: 1 issue / 1 PR
          #18 belongs to Tachikoma.
        https://github.com/openclaw/clawdex/pull/1
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18),
            .repositoryIssueNumber(repositoryFullName: "openclaw/clawdex", number: 1)
        ])
    }

    @Test
    func `repository heading list references stay after earlier urls`() {
        let text = """
        https://github.com/openclaw/clawdex/pull/1
        - openclaw/Tachikoma: 1 issue / 1 PR
          #18 belongs to Tachikoma.
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/clawdex", number: 1),
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18)
        ])
    }

    @Test
    func `same-number grouped refs do not suppress unrelated primary list refs`() {
        let text = """
        - #1 local
        - #2 local
        - other/repo #1
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .issueNumber(1),
            .issueNumber(2),
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 1)
        ])
    }

    @Test
    func `nested list references inherit nearest repository heading context`() {
        let text = """
        - openclaw/Tachikoma: 1 issue / 1 PR
          - #18 closes #17.
        - openclaw/clawdex: 0 issues / 1 PR
          - #1 removes the default personal backup remote.
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18),
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 17),
            .repositoryIssueNumber(repositoryFullName: "openclaw/clawdex", number: 1)
        ])
    }

    @Test
    func `numbered repository headings inherit context after nested count summary`() {
        let text = """
          1. steipete/birdclaw
              - 0 issues / 1 PR
              - PR #44: clean, one green GitGuardian check
              - title: fix: keep init alive when searchDirectoryEffect scan throws
              - best first: own repo, small bugfix shape
          2. openclaw/clawsweeper-state
              - 0 issues / 1 PR
              - PR #3: 95 add / 8 del / 7 files, security checks green
              - caveat: “six confirmed bugs from audit” smells review-heavy despite small queue
          3. openclaw/wacli
              - 1 issue / 1 PR
              - PR #267: 474 add / 5 del / 9 files, CI + docker green
              - issue #268 needs product/maintainer decision; PR is a feature, likely reviewable but not tiny
          4. openclaw/mcporter
              - 2 issues / 1 PR
              - PR #175: 858 add / 7 del / 12 files, CI green across ubuntu/macos/windows
              - issue #188 is P1 lifecycle/reuse bug; probably more urgent than PR #175
          5. openclaw/spogo
              - 0 issues / 1 PR
              - PR #29: 1692 add / 33 del / 23 files
              - queue tiny, diff not tiny; later
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "steipete/birdclaw", number: 44),
            .repositoryIssueNumber(repositoryFullName: "openclaw/clawsweeper-state", number: 3),
            .repositoryIssueNumber(repositoryFullName: "openclaw/wacli", number: 267),
            .repositoryIssueNumber(repositoryFullName: "openclaw/wacli", number: 268),
            .repositoryIssueNumber(repositoryFullName: "openclaw/mcporter", number: 175),
            .repositoryIssueNumber(repositoryFullName: "openclaw/mcporter", number: 188),
            .repositoryIssueNumber(repositoryFullName: "openclaw/spogo", number: 29)
        ])
    }

    @Test
    func `numbered repository headings keep sibling context after active block`() {
        let text = """
          1. steipete/birdclaw
              - 0 issues / 1 PR
              - PR #44
          2. openclaw/clawsweeper-state
              - 0 issues / 1 PR
              - PR #3
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "steipete/birdclaw", number: 44),
            .repositoryIssueNumber(repositoryFullName: "openclaw/clawsweeper-state", number: 3)
        ])
    }

    @Test
    func `normal repository heading clears stale pending repository only heading`() {
        let text = """
        1. old/repo
        2. new/repo: 0 issues / 1 PR
           - 0 issues / 1 PR
           - PR #3
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "new/repo", number: 3)
        ])
    }

    @Test
    func `repository heading child rows ignore diffstat tail counts`() {
        let text = """
        - owner/repo: 0 issues / 3 PRs
          - PR #3: 95 additions
          - PR #4: 7 files changed
          - PR #5: 1 deletion
          - PR #6: 95 additions and 8 deletions
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "owner/repo", number: 3),
            .repositoryIssueNumber(repositoryFullName: "owner/repo", number: 4),
            .repositoryIssueNumber(repositoryFullName: "owner/repo", number: 5),
            .repositoryIssueNumber(repositoryFullName: "owner/repo", number: 6)
        ])
    }

    @Test
    func `repository heading list context wins for nested items with urls`() {
        let text = """
        - openclaw/Tachikoma: 1 issue / 1 PR
          - #18 https://github.com/openclaw/Tachikoma/pull/18
        - openclaw/clawdex: 0 issues / 1 PR
          - #1 https://github.com/openclaw/clawdex/pull/1
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18),
            .repositoryIssueNumber(repositoryFullName: "openclaw/clawdex", number: 1)
        ])
    }

    @Test
    func `repository heading list leaves nonleading references for normal parsing`() {
        let text = """
        - openclaw/Tachikoma: 1 issue / 1 PR
          URL: https://github.com/openclaw/clawdex/pull/1
          See steipete/oracle#225 too.
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/clawdex", number: 1),
            .repositoryIssueNumber(repositoryFullName: "steipete/oracle", number: 225)
        ])
    }

    @Test
    func `repository heading leading references keep explicit refs on same line`() {
        let text = """
        - openclaw/Tachikoma: 1 issue / 1 PR
          #18 depends on other/repo#7 and https://github.com/openclaw/clawdex/pull/1
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18),
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 7),
            .repositoryIssueNumber(repositoryFullName: "openclaw/clawdex", number: 1)
        ])
    }

    @Test
    func `repository heading child rows preserve explicit spaced repository refs`() {
        let text = """
        - openclaw/Tachikoma: 1 issue / 1 PR
          other/repo #7
          other/repo: #8
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 7),
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 8)
        ])
    }

    @Test
    func `repository heading child rows preserve explicit grouped repository refs`() {
        let text = """
        - openclaw/Tachikoma: 1 issue / 1 PR
          other/repo: #7 and #8
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 7),
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 8)
        ])
    }

    @Test
    func `repository heading child rows preserve explicit repository issue prose`() {
        let text = """
        - openclaw/Tachikoma: 1 issue / 1 PR
          other/repo PR #7
          other/repo PR 10
          other/repo issues #8 and #9
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 7),
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 10),
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 8),
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 9)
        ])
    }

    @Test
    func `repository heading child rows respect minimum bare digits`() {
        let text = """
        - openclaw/Tachikoma: 1 issue / 1 PR
          PR 7
        """

        #expect(GitHubReferenceTranslator.queries(
            from: text,
            minimumBareDigits: 3
        ).isEmpty)
    }

    @Test
    func `repository heading child rows preserve later explicit repository issue prose`() {
        let text = """
        - openclaw/Tachikoma: 1 issue / 1 PR
          #18 depends on other/repo PR 7 and other/repo pull request #8
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18),
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 7),
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 8)
        ])
    }

    @Test
    func `repository heading child rows keep prose-prefixed explicit repository issue series`() {
        let text = """
        - openclaw/Tachikoma: 1 issue / 1 PR
          #18 depends on other/repo PR 7 and 8
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18),
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 7),
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 8)
        ])
    }

    @Test
    func `repository heading child rows stop explicit spaced repository series at sentence boundary`() {
        let text = """
        - openclaw/Tachikoma: 1 issue / 1 PR
          #18 depends on other/repo #7. #8 belongs to Tachikoma.
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18),
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 7),
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 8)
        ])
    }

    @Test
    func `repository heading child rows stop explicit compact repository series at sentence boundary`() {
        let text = """
        - openclaw/Tachikoma: 1 issue / 1 PR
          #18 depends on other/repo#7. #8 belongs to Tachikoma.
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18),
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 7),
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 8)
        ])
    }

    @Test
    func `repository heading child rows preserve later explicit repository spaced series`() {
        let text = """
        - openclaw/Tachikoma: 1 issue / 1 PR
          #18 depends on other/repo #7 and #8
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18),
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 7),
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 8)
        ])
    }

    @Test
    func `repository heading child rows stop explicit series at later heading issue prose`() {
        let text = """
        - openclaw/Tachikoma: 1 issue / 1 PR
          See other/repo #7 and PR #8
          See other/repo#9 and issue #10
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 7),
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 8),
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 9),
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 10)
        ])
    }

    @Test
    func `repository heading child rows preserve explicit spaced repository series`() {
        let text = """
        - openclaw/Tachikoma: 1 issue / 1 PR
          other/repo #7 and #8
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 7),
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 8)
        ])
    }

    @Test
    func `repository heading child rows preserve compact explicit repository series`() {
        let text = """
        - openclaw/Tachikoma: 1 issue / 1 PR
          other/repo#7 and #8
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 7),
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 8)
        ])
    }

    @Test
    func `repository heading child rows keep multiple explicit repository spans separate`() {
        let text = """
        - openclaw/Tachikoma: 1 issue / 1 PR
          See other/repo #7 and another/repo #8
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 7),
            .repositoryIssueNumber(repositoryFullName: "another/repo", number: 8)
        ])
    }

    @Test
    func `repository heading child rows preserve leading heading ref before later explicit refs`() {
        let text = """
        - openclaw/Tachikoma: 1 issue / 1 PR
          #18 depends on other/repo #7
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18),
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 7)
        ])
    }

    @Test
    func `repository heading child rows keep same-number heading and explicit refs`() {
        let text = """
        - openclaw/Tachikoma: 1 issue / 1 PR
          #18 depends on other/repo #18
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18),
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 18)
        ])
    }

    @Test
    func `repository heading child rows keep same-number contextual heading and explicit refs`() {
        let text = """
        - openclaw/Tachikoma: 1 issue / 1 PR
          PR 18 depends on other/repo #18
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18),
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 18)
        ])
    }

    @Test
    func `repository heading child rows keep explicit-leading same-number contextual refs`() {
        let text = """
        - openclaw/Tachikoma: 1 issue / 1 PR
          other/repo #18 also affects PR 18
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "other/repo", number: 18),
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18)
        ])
    }

    @Test
    func `repository heading child rows do not parse hex prose as commits without commit context`() {
        let text = """
        - openclaw/Tachikoma: 1 issue / 1 PR
          #18 defaced parser.
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18)
        ])
    }

    @Test
    func `repository heading child rows keep numeric commit refs with commit context`() {
        let text = """
        - openclaw/Tachikoma: 0 issues / 1 PR
          commit 4992546
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryCommitHash(repositoryFullName: "openclaw/Tachikoma", hash: "4992546")
        ])
    }

    @Test
    func `repository heading child rows carry commit context across lines`() {
        let text = """
        - openclaw/Tachikoma: 0 issues / 1 PR
          commit:
          4992546
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryCommitHash(repositoryFullName: "openclaw/Tachikoma", hash: "4992546")
        ])
    }

    @Test
    func `repository heading child rows support compound bare shorthand`() {
        let text = """
        - openclaw/Tachikoma: 2 issues / 1 PR
          - #61/#62 fixes both.
          - #64-#65 fixes series.
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 61),
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 62),
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 64),
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 65)
        ])
    }

    @Test
    func `repository heading child rows keep contextual bare references`() {
        let text = """
        - openclaw/Tachikoma: 2 issues / 1 PR
          #18 also fixes PR 19 and 20.
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18),
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 19),
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 20)
        ])
    }

    @Test
    func `repository heading child rows support prose before references`() {
        let text = """
        - openclaw/Tachikoma: 2 issues / 1 PR
          PR #18 also fixes issue 19 and 20.
          See #21 too.
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18),
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 19),
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 20),
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 21)
        ])
    }

    @Test
    func `repository heading child rows keep cross-line contextual back references`() {
        let text = """
        - openclaw/Tachikoma: 2 issues / 1 PR
          PR #18.
          This is 19.
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18),
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 19)
        ])
    }

    @Test
    func `repository heading child rows carry back reference state from final sentence only`() {
        let text = """
        - openclaw/Tachikoma: 2 issues / 1 PR
          PR #18. Done.
          This is 19.
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18)
        ])
    }

    @Test
    func `repository heading count summary child rows do not arm back references`() {
        let text = """
        - openclaw/Tachikoma: 1 issue / 1 PR
          Open issues: 1
          This is 2.
        """

        #expect(GitHubReferenceTranslator.queries(from: text).isEmpty)
    }

    @Test
    func `repository heading accepts pull request plural count summary`() {
        let text = """
        - openclaw/Tachikoma: 1 issue / 2 pull requests
          #18 belongs to Tachikoma.
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18)
        ])
    }
}

@MainActor
struct GitHubReferenceRepositoryHeadingMergeTests {
    @Test
    func `repository heading consumed rows separate contextual back references`() {
        let text = """
        Please review PR 5.
        - openclaw/Tachikoma: 1 issue / 1 PR
          #18 belongs to Tachikoma.
        This is 19.
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .issueNumber(5),
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18)
        ])
    }

    @Test
    func `consumed repository only heading keeps unrelated normal context ambiguous`() {
        let text = """
        1. openclaw/Peekaboo
        2. openclaw/gogcli
           - 0 issues / 1 PR
           - PR #2

        - Do: PR #139
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/gogcli", number: 2),
            .issueNumber(139)
        ])
    }

    @Test
    func `empty consumed repository only block keeps unrelated normal context ambiguous`() {
        let text = """
        1. openclaw/Peekaboo
        2. openclaw/gogcli
           - 0 issues / 1 PR

        - Do: PR #139
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .issueNumber(139)
        ])
    }

    @Test
    func `empty consumed bare repository only block keeps unrelated normal context ambiguous`() {
        let text = """
        openclaw/Peekaboo
        openclaw/gogcli
          0 issues / 1 PR

        - Do: PR #139
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .issueNumber(139)
        ])
    }

    @Test
    func `explicit normal repository context beats leftover repository only list item`() {
        let text = """
        1. openclaw/Peekaboo
        2. openclaw/gogcli
           - 0 issues / 1 PR
           - PR #2

        Found in openclaw/Peekaboo.
        - Do: PR #139
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/gogcli", number: 2),
            .repositoryIssueNumber(repositoryFullName: "openclaw/Peekaboo", number: 139)
        ])
    }

    @Test
    func `repository heading blocks keep primary url list shortcut`() {
        let text = """
        - openclaw/Tachikoma: 1 issue / 1 PR
          #18 belongs to Tachikoma.
        1. #2172 schema text extensions
           URL: https://github.com/openclaw/clawhub/pull/2172
           Why: small, real bug, linked #874.
        2. #2173 canonical profile route
           URL: https://github.com/openclaw/clawhub/pull/2173
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18),
            .repositoryIssueNumber(repositoryFullName: "openclaw/clawhub", number: 2172),
            .repositoryIssueNumber(repositoryFullName: "openclaw/clawhub", number: 2173)
        ])
    }

    @Test
    func `repository heading blocks keep primary url list shortcut across split list`() {
        let text = """
        1. #2172 schema text extensions
           URL: https://github.com/openclaw/clawhub/pull/2172
           Why: small, real bug, linked #874.
        - openclaw/Tachikoma: 1 issue / 1 PR
          #18 belongs to Tachikoma.
        2. #2173 canonical profile route
           URL: https://github.com/openclaw/clawhub/pull/2173
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/clawhub", number: 2172),
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18),
            .repositoryIssueNumber(repositoryFullName: "openclaw/clawhub", number: 2173)
        ])
    }

    @Test
    func `repository heading blocks keep split primary url shortcut with multiple repos`() {
        let text = """
        1. #10 first
           URL: https://github.com/a/repo/pull/10
        - openclaw/Tachikoma: 1 issue / 1 PR
          #18 belongs to Tachikoma.
        2. #20 second
           URL: https://github.com/b/repo/pull/20
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "a/repo", number: 10),
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18),
            .repositoryIssueNumber(repositoryFullName: "b/repo", number: 20)
        ])
    }

    @Test
    func `repository heading blocks do not let primary url shortcut admit incidental same-number repo refs`() {
        let text = """
        1. #10 first
           URL: https://github.com/a/repo/pull/10
        - openclaw/Tachikoma: 1 issue / 1 PR
          #18 belongs to Tachikoma.
        Later b/repo#10 is unrelated prose.
        2. #20 second
           URL: https://github.com/b/repo/pull/20
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "a/repo", number: 10),
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18),
            .repositoryIssueNumber(repositoryFullName: "b/repo", number: 20)
        ])
    }

    @Test
    func `repository heading blocks keep split compound primary list refs`() {
        let text = """
        - #61/#62 first pair
        - openclaw/Tachikoma: 1 issue / 1 PR
          #18 belongs to Tachikoma.
        - #64/#65 second pair
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .issueNumber(61),
            .issueNumber(62),
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18),
            .issueNumber(64),
            .issueNumber(65)
        ])
    }

    @Test
    func `repository heading blocks preserve normal repository context across chunks`() {
        let text = """
        Found in openclaw/gogcli.
        - openclaw/Tachikoma: 1 issue / 1 PR
          #18
        1. #569
        2. #568
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18),
            .repositoryIssueNumber(repositoryFullName: "openclaw/gogcli", number: 569),
            .repositoryIssueNumber(repositoryFullName: "openclaw/gogcli", number: 568)
        ])
    }

    @Test
    func `repository heading child prose does not leak repository context outside block`() {
        let text = """
        - openclaw/Tachikoma: 1 issue / 1 PR
          Found in openclaw/gogcli.
          #18
        1. #569
        """

        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18),
            .issueNumber(569)
        ])
    }

    @Test
    func `repository colon references without count summary use normal parsing`() {
        #expect(GitHubReferenceTranslator.queries(from: """
        - openclaw/Tachikoma: https://github.com/openclaw/Tachikoma/pull/18
        """) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18)
        ])

        #expect(GitHubReferenceTranslator.queries(from: """
        - openclaw/Tachikoma: PR 18
        """) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18)
        ])
    }

    @Test
    func `repository count heading with same-line reference uses normal parsing`() {
        #expect(GitHubReferenceTranslator.queries(from: """
        - openclaw/Tachikoma: 1 issue / 1 PR https://github.com/openclaw/Tachikoma/pull/18
        """) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/Tachikoma", number: 18)
        ])

        #expect(GitHubReferenceTranslator.queries(from: """
        - openclaw/Tachikoma: issue PR 18
        """) == [.issueNumber(18)])

        #expect(GitHubReferenceTranslator.queries(from: """
        - openclaw/Tachikoma: 1 issue / 1 PR 18
        """) == [.issueNumber(18)])
    }
}
