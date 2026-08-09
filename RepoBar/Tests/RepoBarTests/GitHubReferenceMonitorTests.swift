import Foundation
@testable import RepoBarCore
import Testing

@MainActor
struct GitHubReferenceMonitorTests {
    @Test
    func `bare numbers and issue prefixes become issue queries`() {
        #expect(GitHubReferenceTranslator.query(from: "73655") == .issueNumber(73655))
        #expect(GitHubReferenceTranslator.query(from: "7") == .issueNumber(7))
        #expect(GitHubReferenceTranslator.query(from: "#7") == .issueNumber(7))
        #expect(GitHubReferenceTranslator.query(from: "gh-42") == .issueNumber(42))
        #expect(GitHubReferenceTranslator.query(from: "GH-42") == .issueNumber(42))
        #expect(GitHubReferenceTranslator.query(from: " #78096. ") == .issueNumber(78096))
        #expect(GitHubReferenceTranslator.query(from: "a73655") == nil)
    }

    @Test
    func `commit hashes become commit queries`() {
        #expect(GitHubReferenceTranslator.query(from: "4992546") == .commitHash("4992546"))
        #expect(GitHubReferenceTranslator.query(from: " - bare short SHA: 4992546") == .commitHash("4992546"))
        #expect(GitHubReferenceTranslator.query(from: "ffd212ca43") == .commitHash("ffd212ca43"))
        #expect(
            GitHubReferenceTranslator.query(from: "d04517cefff3af339f560a8e388cacc3898e6562") ==
                .commitHash("d04517cefff3af339f560a8e388cacc3898e6562")
        )
        #expect(GitHubReferenceTranslator.query(from: "1234567") == .commitHash("1234567"))
        #expect(GitHubReferenceTranslator.query(from: "abcdef") == nil)
    }

    @Test
    func `owner repo issue shorthand becomes repository scoped issue query`() {
        #expect(
            GitHubReferenceTranslator.query(from: "steipete/summarize#215") ==
                .repositoryIssueNumber(repositoryFullName: "steipete/summarize", number: 215)
        )
        #expect(
            GitHubReferenceTranslator.query(from: "openclaw/clawsweeper#57") ==
                .repositoryIssueNumber(repositoryFullName: "openclaw/clawsweeper", number: 57)
        )
        #expect(
            GitHubReferenceTranslator.query(from: " steipete/summarize#215. ") ==
                .repositoryIssueNumber(repositoryFullName: "steipete/summarize", number: 215)
        )
        #expect(
            GitHubReferenceTranslator.query(from: "  - scoped issue shorthand: steipete/summarize#215") ==
                .repositoryIssueNumber(repositoryFullName: "steipete/summarize", number: 215)
        )
    }

    @Test
    func `repo name issue shorthand becomes repository name scoped issue query`() {
        #expect(
            GitHubReferenceTranslator.query(from: "discrawl#64") ==
                .repositoryNameIssueNumber(repositoryName: "discrawl", number: 64)
        )
        #expect(
            GitHubReferenceTranslator.query(from: " Discrawl#64. ") ==
                .repositoryNameIssueNumber(repositoryName: "Discrawl", number: 64)
        )
        #expect(
            GitHubReferenceTranslator.query(from: "steipete/RepoBar#66") ==
                .repositoryIssueNumber(repositoryFullName: "steipete/RepoBar", number: 66)
        )
        #expect(
            GitHubReferenceTranslator.query(from: "https://github.com/steipete/RepoBar/pull/66") ==
                .repositoryIssueNumber(repositoryFullName: "steipete/RepoBar", number: 66)
        )
    }

    @Test
    func `chained owner repo issue shorthand becomes multiple repository scoped issue queries`() {
        #expect(
            GitHubReferenceTranslator.queries(from: "openclaw/crabbox#70/#71") == [
                .repositoryIssueNumber(repositoryFullName: "openclaw/crabbox", number: 70),
                .repositoryIssueNumber(repositoryFullName: "openclaw/crabbox", number: 71)
            ]
        )
        #expect(
            GitHubReferenceTranslator.queries(from: "make - openclaw/crabbox#70/#71: work") == [
                .repositoryIssueNumber(repositoryFullName: "openclaw/crabbox", number: 70),
                .repositoryIssueNumber(repositoryFullName: "openclaw/crabbox", number: 71)
            ]
        )
    }

    @Test
    func `ranged owner repo issue shorthand becomes repository scoped issue series`() {
        #expect(
            GitHubReferenceTranslator.queries(from: "openclaw/crabbox#66-#69") == [
                .repositoryIssueNumber(repositoryFullName: "openclaw/crabbox", number: 66),
                .repositoryIssueNumber(repositoryFullName: "openclaw/crabbox", number: 67),
                .repositoryIssueNumber(repositoryFullName: "openclaw/crabbox", number: 68),
                .repositoryIssueNumber(repositoryFullName: "openclaw/crabbox", number: 69)
            ]
        )
        #expect(
            GitHubReferenceTranslator.queries(from: "also make openclaw/crabbox#66-#69 work (series)") == [
                .repositoryIssueNumber(repositoryFullName: "openclaw/crabbox", number: 66),
                .repositoryIssueNumber(repositoryFullName: "openclaw/crabbox", number: 67),
                .repositoryIssueNumber(repositoryFullName: "openclaw/crabbox", number: 68),
                .repositoryIssueNumber(repositoryFullName: "openclaw/crabbox", number: 69)
            ]
        )
        #expect(
            GitHubReferenceTranslator.queries(from: "openclaw/crabbox#66-69") == [
                .repositoryIssueNumber(repositoryFullName: "openclaw/crabbox", number: 66),
                .repositoryIssueNumber(repositoryFullName: "openclaw/crabbox", number: 67),
                .repositoryIssueNumber(repositoryFullName: "openclaw/crabbox", number: 68),
                .repositoryIssueNumber(repositoryFullName: "openclaw/crabbox", number: 69)
            ]
        )
    }

    @Test
    func `github issue and pr urls become repository scoped issue queries`() {
        #expect(
            GitHubReferenceTranslator.query(from: "https://github.com/openclaw/openclaw/issues/73655") ==
                .repositoryIssueNumber(repositoryFullName: "openclaw/openclaw", number: 73655)
        )
        #expect(
            GitHubReferenceTranslator.query(from: "https://github.com/openclaw/openclaw/pull/123") ==
                .repositoryIssueNumber(repositoryFullName: "openclaw/openclaw", number: 123)
        )
        #expect(
            GitHubReferenceTranslator.query(from: "https://github.com/openclaw/openclaw/issues/1234567") ==
                .repositoryIssueNumber(repositoryFullName: "openclaw/openclaw", number: 1_234_567)
        )
        #expect(
            GitHubReferenceTranslator.query(from: "https://github.com/openclaw/openclaw/pull/1234567") ==
                .repositoryIssueNumber(repositoryFullName: "openclaw/openclaw", number: 1_234_567)
        )
        #expect(GitHubReferenceTranslator.query(from: "httpx://github.com/openclaw/openclaw/issues/1") == nil)
    }

    @Test
    func `github url references preserve source url and kind for provisional previews`() throws {
        let references = GitHubReferenceTranslator.urlReferences(in: """
          - https://github.com/openclaw/openclaw/pull/85652
            Fixes gateway prompt history.
          - https://github.com/openclaw/openclaw/pull/85777
            Fixes WhatsApp auto-reply failure logging.
          - https://github.com/openclaw/openclaw/issues/85796
            Tracks Twitch cleanup.
        """)

        #expect(references.map(\.query) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/openclaw", number: 85652),
            .repositoryIssueNumber(repositoryFullName: "openclaw/openclaw", number: 85777),
            .repositoryIssueNumber(repositoryFullName: "openclaw/openclaw", number: 85796)
        ])
        #expect(references.map(\.kind) == [.pullRequest, .pullRequest, .issue])
        #expect(references.first?.url.absoluteString == "https://github.com/openclaw/openclaw/pull/85652")

        let provisional = try #require(GitHubReferenceMatch.provisional(
            query: references[0].query,
            url: references[0].url,
            kind: references[0].kind,
            now: Date(timeIntervalSince1970: 0)
        ))
        #expect(provisional.url.absoluteString == "https://github.com/openclaw/openclaw/pull/85652")
        #expect(provisional.kind == .pullRequest)
        #expect(provisional.repositoryFullName == "openclaw/openclaw")
        #expect(provisional.isResolved == false)

        let unresolved = GitHubReferenceMatch.unresolved(from: provisional, now: Date(timeIntervalSince1970: 1))
        #expect(unresolved.url == provisional.url)
        #expect(unresolved.kind == .pullRequest)
        #expect(unresolved.title == "GitHub preview unavailable")
        #expect(unresolved.isResolved == false)
    }

    @Test
    func `github commit urls become repository scoped commit queries`() {
        #expect(
            GitHubReferenceTranslator.query(from: "https://github.com/openclaw/openclaw/commit/ffd212ca43abcdef") ==
                .repositoryCommitHash(repositoryFullName: "openclaw/openclaw", hash: "ffd212ca43abcdef")
        )
        #expect(
            GitHubReferenceTranslator.query(from: "https://github.com/openclaw/openclaw/commits/ffd212ca43") ==
                .repositoryCommitHash(repositoryFullName: "openclaw/openclaw", hash: "ffd212ca43")
        )
        #expect(
            GitHubReferenceTranslator.query(from: "https://github.com/openclaw/openclaw/pull/57843/changes/d04517cefff3af339f560a8e388cacc3898e6562") ==
                .repositoryCommitHash(repositoryFullName: "openclaw/openclaw", hash: "d04517cefff3af339f560a8e388cacc3898e6562")
        )
    }

    @Test
    func `distinct commit hashes with shared display prefix remain distinct`() {
        let first = "abcdef1234000000000000000000000000000000"
        let second = "abcdef1234ffffffffffffffffffffffffffffff"

        #expect(GitHubReferenceTranslator.queries(from: "commits \(first) \(second)") == [
            .commitHash(first),
            .commitHash(second)
        ])
    }

    @Test
    func `github actions run urls become repository scoped workflow run queries`() {
        #expect(
            GitHubReferenceTranslator.query(from: "https://github.com/openclaw/songsee/actions/runs/25620622163") ==
                .repositoryWorkflowRun(repositoryFullName: "openclaw/songsee", runID: 25_620_622_163)
        )
    }

    @Test
    func `multiple bare issue references inherit repository context`() {
        let text = """
        Found 5 more in openclaw/gogcli after clean main pull.

        1. #569 release/bottle codesigning
        2. #568 local self-sign PR
        3. #567 Win11 access_denied
        4. #338 Workspace invalid_rapt
        5. #468 Google Meet PR
        """
        #expect(
            GitHubReferenceTranslator.queries(from: text) == [
                .repositoryIssueNumber(repositoryFullName: "openclaw/gogcli", number: 569),
                .repositoryIssueNumber(repositoryFullName: "openclaw/gogcli", number: 568),
                .repositoryIssueNumber(repositoryFullName: "openclaw/gogcli", number: 567),
                .repositoryIssueNumber(repositoryFullName: "openclaw/gogcli", number: 338),
                .repositoryIssueNumber(repositoryFullName: "openclaw/gogcli", number: 468)
            ]
        )
    }

    @Test
    func `multiple grouped issue references use line scoped repository context`() {
        let text = """
            - openclaw/discrawl: #61, #62, #63
            - openclaw/acpx: #294, #295, #296, #297, #303
            - openclaw/openclaw.ai: #132, #133, #134
            - steipete/oracle: #188
            - openclaw/spogo: #26
            - openclaw/gitcrawl: #14
        """
        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/discrawl", number: 61),
            .repositoryIssueNumber(repositoryFullName: "openclaw/discrawl", number: 62),
            .repositoryIssueNumber(repositoryFullName: "openclaw/discrawl", number: 63),
            .repositoryIssueNumber(repositoryFullName: "openclaw/acpx", number: 294),
            .repositoryIssueNumber(repositoryFullName: "openclaw/acpx", number: 295),
            .repositoryIssueNumber(repositoryFullName: "openclaw/acpx", number: 296),
            .repositoryIssueNumber(repositoryFullName: "openclaw/acpx", number: 297),
            .repositoryIssueNumber(repositoryFullName: "openclaw/acpx", number: 303),
            .repositoryIssueNumber(repositoryFullName: "openclaw/openclaw.ai", number: 132),
            .repositoryIssueNumber(repositoryFullName: "openclaw/openclaw.ai", number: 133),
            .repositoryIssueNumber(repositoryFullName: "openclaw/openclaw.ai", number: 134),
            .repositoryIssueNumber(repositoryFullName: "steipete/oracle", number: 188),
            .repositoryIssueNumber(repositoryFullName: "openclaw/spogo", number: 26),
            .repositoryIssueNumber(repositoryFullName: "openclaw/gitcrawl", number: 14)
        ])
    }

    @Test
    func `multiple repository issue references allow space before issue number`() {
        let text = """
          - steipete/birdclaw #23: X bookmarks max_results=90 workaround. Small, 4 files, tests
            included, strong real-world bug proof. Best first review.
          - steipete/birdclaw #18: --early-stop dedupe saturation for likes/bookmarks. Larger but
            self-contained, lots of tests/docs, live smoke in PR body.
          - steipete/oracle #194: browser upload ZIP bundle format. Medium 17-file feature, tests/
            docs/changelog included. Worth review before it rots.
          - steipete/steipete.me #224: blog post "When Claude Emails Claude". Clean, old green CI,
            content-only-ish plus hero image. Likely easy land/close decision.
          - steipete/camsnap #2: Docker + GHCR publishing. Small 4-file PR but DIRTY; good review/fix
            candidate if Docker support still wanted.

          Skipped for now:
        """
        #expect(GitHubReferenceTranslator.queries(from: text).map(\.displayText) == [
            "steipete/birdclaw#23",
            "steipete/birdclaw#18",
            "steipete/oracle#194",
            "steipete/steipete.me#224",
            "steipete/camsnap#2"
        ])
    }

    @Test
    func `multiple parser ignores slash words that are not repository context`() {
        let text = """
        Found items in openclaw/gogcli.

        1. #569 release/bottle codesigning
        2. #568 local self-sign PR
        """
        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/gogcli", number: 569),
            .repositoryIssueNumber(repositoryFullName: "openclaw/gogcli", number: 568)
        ])
    }

    @Test
    func `multiple parser ignores ordered list numbers`() {
        let text = """
        1. #10 first
        2. #11 second
        """
        #expect(GitHubReferenceTranslator.queries(from: text) == [.issueNumber(10), .issueNumber(11)])
    }

    @Test
    func `leading issue list ignores prose repository paths in item details`() {
        let text = """
         - #72085: close. Bad rebase artifact; adds ~2.7k duplicated config docs with stray :wq
            lines.
          - #71831: add. Small browser docs note; matches current bare WebSocket CDP fallback
            behavior.
          - #29110: close. Bitwarden Secrets-specific resolver/example; product-specific promotion
            and adds a maintained script surface.
          - #55010: add. Correct Plugin SDK migration table fix; mapAllowlistResolutionInputs is
            exported from plugin-sdk/allow-from.
          - #45683: add. Correct default docs: runtime defaults are stallSoftMs=10000,
            stallHardMs=30000.
          - #46552: add, but manually fold/simplify. Useful steer/streaming clarification; current
            docs already cover part of it.
          - #40039: add. Useful troubleshooting note for narrow tools.profile, with wording kept
            security-conscious.
          - #39513: add partially. Cron/HEARTBEAT behavior is real; I'd add the cron docs note,
            skip the AGENTS template churn/comment.
          - #40387: close. EasyRunner-specific deployment guide, external product/website
            promotion.
          - #38685: add. Useful Telegram multi-agent same-group example; fold into existing
            Telegram bots-per-agent accordion.
        """
        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .issueNumber(72085),
            .issueNumber(71831),
            .issueNumber(29110),
            .issueNumber(55010),
            .issueNumber(45683),
            .issueNumber(46552),
            .issueNumber(40039),
            .issueNumber(39513),
            .issueNumber(40387),
            .issueNumber(38685)
        ])
    }

    @Test
    func `multiple parser prioritizes copied triage list references`() {
        let text = """
         State: main, clean, pulled. Open PRs: none. Open issues: 12.

          Best Next Work

          - #597 keyring locking: Fit good; risk medium auth storage; proof source-level strong; next implement first. Foundation for #596.
          - #620 Gmail search attachments JSON: Fit good; risk low; proof source confirms messageItem drops attachments; next small PR + regression test.
          - #621 XDG kind paths: Fit good; risk medium migration/storage paths; proof source confirms config-dir conflation; next design/implement with read-legacy/write-new.
          - #600 service-account key stdin/env: Fit good; risk low-medium secrets intake; proof source likely direct file read; next implement after agreeing flag shape.
          - #461/#460 People API disabled: Fit good bug; risk low; PR #462 closed unmerged.
            Next fix #461, close #460 as duplicate/noisy repro.

          Needs Maintainer Decision

          - #596 store Google OAuth client_secret in keyring: valid security hardening; risk medium storage contract.
            Blocker: default flip, legacy opt-out, diagnostics, sequence after #597.
          - #622 GOG_HOME / per-kind dirs: good operator feature, but depends on #621. Blocker: layout/validation/flag semantics.
          - #599 ${VAR} interpolation in credentials JSON: useful but behavior-sensitive. Blocker: opt-in --expand-env vs always-on, missing-var semantics.
          - #598 seed initial access token: reasonable perf/ergonomics; lower priority than storage safety.
            Blocker: expiry contract and whether rotated access tokens should persist.
          - #585 Docs anchored comments UI workaround: real Google API gap, but plugin/browser automation scope.
            Next: document OpenClaw browser workaround or defer from CLI proper.
          - #588 official OpenClaw plugin: poor/mixed fit until concrete plugin-only benefit is stated.
            Next: ask reporter to answer maintainer’s existing “what benefit over CLI?” question.

          gpt-5.5 high fast · ~/Projects/gogcli
        """
        let displayTexts = GitHubReferenceTranslator.queries(
            from: text,
            repositoryContextOverride: "openclaw/gogcli"
        ).map(\.displayText)

        #expect(Array(displayTexts.prefix(12)) == [
            "openclaw/gogcli#597",
            "openclaw/gogcli#620",
            "openclaw/gogcli#621",
            "openclaw/gogcli#600",
            "openclaw/gogcli#461",
            "openclaw/gogcli#460",
            "openclaw/gogcli#596",
            "openclaw/gogcli#622",
            "openclaw/gogcli#599",
            "openclaw/gogcli#598",
            "openclaw/gogcli#585",
            "openclaw/gogcli#588"
        ])
        #expect(displayTexts.contains("openclaw/gogcli#12") == false)
    }

    @Test
    func `bare pr references inherit selected repository list item context`() {
        let text = """
        1. openclaw/Peekaboo

        - Do: PR #139, maybe #138 in same pass.
        - Why: small, concrete stale-tool-schema prompt fix; tests added. #138 is a 1-line community docs add.
        - Risk: low. Proof path: Swift/package tests around PeekabooAgentRuntime.
        """
        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/Peekaboo", number: 139),
            .repositoryIssueNumber(repositoryFullName: "openclaw/Peekaboo", number: 138)
        ])
    }

    @Test
    func `bare references stay unscoped when selection has multiple repository list items`() {
        let text = """
        1. openclaw/Peekaboo
        2. openclaw/gogcli

        - Do: PR #139
        """
        #expect(GitHubReferenceTranslator.queries(from: text) == [.issueNumber(139)])
    }

    @Test
    func `explicit repository context beats selected repository list item context`() {
        let text = """
        1. openclaw/Peekaboo

        Found in openclaw/gogcli: #569
        """
        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/gogcli", number: 569)
        ])
    }

    @Test
    func `bare numbers in pr and issue prose become multiple references`() {
        let text = """
        any chance you can review PR 75133, 78985 and 82724 for inclusion? They are all related to bugs/issues with subagents, delegated tasks to harnesses like codex and claude.

        I also have a security fix/enhancement I have proposed that has been out there for a while. That is 76949.
        """
        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .issueNumber(75133),
            .issueNumber(78985),
            .issueNumber(82724),
            .issueNumber(76949)
        ])

        #expect(GitHubReferenceTranslator.queries(from: "PR #123, 456 and 789") == [
            .issueNumber(123),
            .issueNumber(456),
            .issueNumber(789)
        ])

        #expect(GitHubReferenceTranslator.queries(from: "please review pull requests 123 and 456") == [
            .issueNumber(123),
            .issueNumber(456)
        ])

        #expect(GitHubReferenceTranslator.queries(from: """
        I also have a security fix/enhancement I have proposed that has been out there for a while.
        That is 76949.
        """) == [.issueNumber(76949)])
    }

    @Test
    func `contextual bare issue parser ignores years`() {
        let text = "please review PR 68 from 2026"
        #expect(GitHubReferenceTranslator.queries(from: text) == [.issueNumber(68)])
        #expect(GitHubReferenceTranslator.queries(from: "please review PR 2026") == [.issueNumber(2026)])
        #expect(GitHubReferenceTranslator.queries(from: "please review issue 1999") == [.issueNumber(1999)])
    }

    @Test
    func `contextual bare issue parser ignores incidental sentence numbers`() {
        #expect(GitHubReferenceTranslator.queries(from: "please review PR 68 with 2 commits") == [.issueNumber(68)])
        #expect(GitHubReferenceTranslator.queries(from: "please review PR 123 on iOS 26") == [.issueNumber(123)])
        #expect(GitHubReferenceTranslator.queries(from: "Open PR: 123") == [.issueNumber(123)])
        #expect(GitHubReferenceTranslator.queries(from: "Closed issue: 12") == [.issueNumber(12)])
        #expect(GitHubReferenceTranslator.queries(from: "Open PRs: 123, 456") == [.issueNumber(123), .issueNumber(456)])
        #expect(GitHubReferenceTranslator.queries(from: "Closed issues: 12 and 13") == [.issueNumber(12), .issueNumber(13)])
        #expect(GitHubReferenceTranslator.queries(from: "please review PR 123 adds support") == [.issueNumber(123)])
        #expect(GitHubReferenceTranslator.queries(from: "issue 456 deletes stale state") == [.issueNumber(456)])
        #expect(GitHubReferenceTranslator.queries(from: "please review PRs 123 and 456 add support") == [.issueNumber(123), .issueNumber(456)])
        #expect(GitHubReferenceTranslator.queries(from: "please review PRs 123 and 456 add 2 tests") == [.issueNumber(123), .issueNumber(456)])
        #expect(GitHubReferenceTranslator.queries(from: "please review PRs 123 and 456 add / remove support") == [.issueNumber(123), .issueNumber(456)])
        #expect(GitHubReferenceTranslator.queries(from: "closed issues 12 and 13 delete stale state") == [.issueNumber(12), .issueNumber(13)])
        #expect(GitHubReferenceTranslator.queries(from: "Open issues: 12").isEmpty)
        #expect(GitHubReferenceTranslator.queries(from: "this PR has 2 commits").isEmpty)
        #expect(GitHubReferenceTranslator.queries(from: "I have issues with 2 things").isEmpty)
    }

    @Test
    func `ordered list parser prefers leading references over incidental references`() {
        let text = """
        1. #2172 — schema text extensions
           URL: https://github.com/openclaw/clawhub/pull/2172
           Why: small, real bug, linked #874.
        2. #2173 — canonical /user/<handle> profile route
           URL: https://github.com/openclaw/clawhub/pull/2173
        3. #2186 — OpenAPI package catalog docs
           URL: https://github.com/openclaw/clawhub/pull/2186
        """
        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/clawhub", number: 2172),
            .repositoryIssueNumber(repositoryFullName: "openclaw/clawhub", number: 2173),
            .repositoryIssueNumber(repositoryFullName: "openclaw/clawhub", number: 2186)
        ])
    }

    @Test
    func `multiple parser dedupes references after inheriting scoped context`() {
        let text = "openclaw/gogcli#569 #569 https://github.com/openclaw/gogcli/issues/569"
        #expect(GitHubReferenceTranslator.queries(from: text) == [
            .repositoryIssueNumber(repositoryFullName: "openclaw/gogcli", number: 569)
        ])
    }

    @Test
    func `local path candidates trim prompt separators`() {
        let text = "gpt-5.5 high fast · ~/Projects/crabbox · -"
        #expect(GitHubReferenceLocalContext.localPathCandidates(in: text) == ["~/Projects/crabbox"])
    }

    @Test
    func `remote urls become github repository full names`() {
        #expect(
            GitHubReferenceLocalContext.gitHubRepositoryFullName(
                fromRemoteURL: "https://github.com/openclaw/crabbox.git"
            ) == "openclaw/crabbox"
        )
        #expect(
            GitHubReferenceLocalContext.gitHubRepositoryFullName(
                fromRemoteURL: "git@github.com:openclaw/crabbox.git"
            ) == "openclaw/crabbox"
        )
    }

    @Test
    func `bare references inherit local repository context`() async {
        let status = LocalRepoStatus(
            path: URL(fileURLWithPath: "/tmp/crabbox"),
            name: "crabbox",
            fullName: "openclaw/crabbox",
            branch: "main",
            isClean: true,
            aheadCount: 0,
            behindCount: 0,
            syncState: .synced
        )
        let index = LocalRepoIndex(statuses: [status])
        let text = """
        - PRs:
            - #61 feat: add checkpoint ledger store
            - #60 docs: sharpen agent workspace positioning

        gpt-5.5 high fast · /tmp/crabbox · -
        """
        let repositoryFullName = await GitHubReferenceLocalContext.repositoryFullName(in: text, localRepoIndex: index)
        let queries: [GitHubReferenceQuery] = GitHubReferenceLocalContext.queries(
            GitHubReferenceTranslator.queries(from: text),
            applyingRepositoryFullName: repositoryFullName
        )
        let expected: [GitHubReferenceQuery] = [
            .repositoryIssueNumber(repositoryFullName: "openclaw/crabbox", number: 61),
            .repositoryIssueNumber(repositoryFullName: "openclaw/crabbox", number: 60)
        ]
        #expect(queries == expected)
    }

    @Test
    func `bare commit references inherit unique local commit context`() async throws {
        let repoURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoURL) }

        try runGit(["init"], in: repoURL)
        try runGit(["config", "user.email", "repobar-tests@example.com"], in: repoURL)
        try runGit(["config", "user.name", "RepoBar Tests"], in: repoURL)
        try "hello\n".write(to: repoURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "."], in: repoURL)
        try runGit(["commit", "-m", "init"], in: repoURL)
        let sha = try runGit(["rev-parse", "HEAD"], in: repoURL).trimmingCharacters(in: .whitespacesAndNewlines)
        let shortSHA = String(sha.prefix(7))

        let status = LocalRepoStatus(
            path: repoURL,
            name: "RepoBar",
            fullName: "steipete/RepoBar",
            branch: "main",
            isClean: true,
            aheadCount: 0,
            behindCount: 0,
            syncState: .synced
        )
        let queries = await GitHubReferenceLocalContext.queries(
            [.commitHash(shortSHA)],
            applyingLocalRepositoryContextFrom: LocalRepoIndex(statuses: [status])
        )

        #expect(queries == [.repositoryCommitHash(repositoryFullName: "steipete/RepoBar", hash: shortSHA)])
    }

    @Test
    func `repo name issue references inherit unique local repository context`() async {
        let status = LocalRepoStatus(
            path: URL(fileURLWithPath: "/tmp/discrawl"),
            name: "discrawl",
            fullName: "openclaw/discrawl",
            branch: "main",
            isClean: true,
            aheadCount: 0,
            behindCount: 0,
            syncState: .synced
        )

        let queries = await GitHubReferenceLocalContext.queries(
            [.repositoryNameIssueNumber(repositoryName: "discrawl", number: 64)],
            applyingLocalRepositoryContextFrom: LocalRepoIndex(statuses: [status])
        )

        #expect(queries == [.repositoryIssueNumber(repositoryFullName: "openclaw/discrawl", number: 64)])
    }

    @Test
    func `local repository context beats prose slash words`() {
        let text = """
        - #2124 header avatar controls
        - #2128 content container constraints
        - #908 upload page validation errors hidden. Likely fix: surface validationError inline/toast on publish/upload forms.
        - #937 clawhub update --all false local changes.
        - #951 onlycrabs.ai README mismatch.

        Skipped: #2126 too large, #1110 conflicts + API/CLI feature, #1712 stats/accounting touches telemetry semantics.

        gpt-5.5 high fast · ~/Projects/clawhub · Context 67% left
        """
        let queries = GitHubReferenceTranslator.queries(
            from: text,
            repositoryContextOverride: "openclaw/clawhub"
        )
        #expect(queries.map(\.displayText) == [
            "openclaw/clawhub#2124",
            "openclaw/clawhub#2128",
            "openclaw/clawhub#908",
            "openclaw/clawhub#937",
            "openclaw/clawhub#951",
            "openclaw/clawhub#2126",
            "openclaw/clawhub#1110",
            "openclaw/clawhub#1712"
        ])
    }
}

@discardableResult
private func runGit(_ arguments: [String], in directory: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = directory
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    try process.run()
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    if process.terminationStatus != 0 {
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        let message = String(data: errorData, encoding: .utf8) ?? "git failed"
        throw NSError(domain: "GitHubReferenceMonitorTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
    }
    return String(data: data, encoding: .utf8) ?? ""
}
