import Foundation
@testable import RepoBarCore
import Testing

struct GitHubReleaseNotificationDetectorTests {
    @Test
    func `polls when no previous check exists`() {
        #expect(GitHubReleaseNotificationDetector.shouldPoll(
            previousState: GitHubReleaseNotificationSnapshotState(),
            now: Self.date(1000),
            minimumInterval: 900
        ))
    }

    @Test
    func `skips polling until minimum interval elapses`() {
        let state = GitHubReleaseNotificationSnapshotState(lastCheckedAt: Self.date(1000))

        #expect(GitHubReleaseNotificationDetector.shouldPoll(
            previousState: state,
            now: Self.date(1899),
            minimumInterval: 900
        ) == false)
        #expect(GitHubReleaseNotificationDetector.shouldPoll(
            previousState: state,
            now: Self.date(1900),
            minimumInterval: 900
        ))
    }

    @Test
    func `polls after clock moves backwards`() {
        let state = GitHubReleaseNotificationSnapshotState(lastCheckedAt: Self.date(1000))

        #expect(GitHubReleaseNotificationDetector.shouldPoll(
            previousState: state,
            now: Self.date(900),
            minimumInterval: 900
        ))
    }

    @Test
    func `first snapshot does not emit backlog`() {
        let result = GitHubReleaseNotificationDetector.events(
            for: ["steipete/RepoBar": [Self.release(tag: "v1.0.0", publishedAt: Self.date(100))]],
            previousState: GitHubReleaseNotificationSnapshotState(),
            settings: Self.enabledSettings(),
            observedAt: Self.date(150)
        )

        #expect(result.events.isEmpty)
        #expect(
            result.state.repositories["steipete/repobar"]?["v1.0.0"]
                == GitHubReleaseNotificationSnapshot(publishedAt: Self.date(100), isPrerelease: false)
        )
        #expect(result.state.repositoryBaselines["steipete/repobar"] == Self.date(150))
    }

    @Test
    func `new release emits after initial snapshot`() {
        let first = GitHubReleaseNotificationDetector.events(
            for: ["steipete/RepoBar": [Self.release(tag: "v1.0.0", publishedAt: Self.date(100))]],
            previousState: GitHubReleaseNotificationSnapshotState(),
            settings: Self.enabledSettings(),
            observedAt: Self.date(150)
        )

        let second = GitHubReleaseNotificationDetector.events(
            for: [
                "steipete/RepoBar": [
                    Self.release(tag: "v1.1.0", publishedAt: Self.date(200)),
                    Self.release(tag: "v1.0.0", publishedAt: Self.date(100))
                ]
            ],
            previousState: first.state,
            settings: Self.enabledSettings(),
            observedAt: Self.date(250)
        )

        #expect(second.events.count == 1)
        #expect(second.events.first?.tag == "v1.1.0")
        #expect(second.events.first?.repositoryFullName == "steipete/RepoBar")
    }

    @Test
    func `pre-release is suppressed by default`() {
        let first = GitHubReleaseNotificationDetector.events(
            for: ["steipete/RepoBar": [Self.release(tag: "v1.0.0", publishedAt: Self.date(100))]],
            previousState: GitHubReleaseNotificationSnapshotState(),
            settings: Self.enabledSettings(),
            observedAt: Self.date(150)
        )

        let second = GitHubReleaseNotificationDetector.events(
            for: [
                "steipete/RepoBar": [
                    Self.release(tag: "v1.1.0-rc1", publishedAt: Self.date(200), isPrerelease: true),
                    Self.release(tag: "v1.0.0", publishedAt: Self.date(100))
                ]
            ],
            previousState: first.state,
            settings: Self.enabledSettings(),
            observedAt: Self.date(250)
        )

        #expect(second.events.isEmpty)
    }

    @Test
    func `pre-release emits when included`() {
        var settings = Self.enabledSettings()
        settings.includePrereleases = true
        let first = GitHubReleaseNotificationDetector.events(
            for: ["steipete/RepoBar": [Self.release(tag: "v1.0.0", publishedAt: Self.date(100))]],
            previousState: GitHubReleaseNotificationSnapshotState(),
            settings: settings,
            observedAt: Self.date(150)
        )

        let second = GitHubReleaseNotificationDetector.events(
            for: [
                "steipete/RepoBar": [
                    Self.release(tag: "v1.1.0-rc1", publishedAt: Self.date(200), isPrerelease: true),
                    Self.release(tag: "v1.0.0", publishedAt: Self.date(100))
                ]
            ],
            previousState: first.state,
            settings: settings,
            observedAt: Self.date(250)
        )

        #expect(second.events.count == 1)
        #expect(second.events.first?.tag == "v1.1.0-rc1")
        #expect(second.events.first?.isPrerelease == true)
    }

    @Test
    func `pre-release promoted to stable emits when pre-releases are excluded`() {
        let first = GitHubReleaseNotificationDetector.events(
            for: [
                "steipete/RepoBar": [
                    Self.release(tag: "v1.1.0", publishedAt: Self.date(200), isPrerelease: true),
                    Self.release(tag: "v1.0.0", publishedAt: Self.date(100))
                ]
            ],
            previousState: GitHubReleaseNotificationSnapshotState(),
            settings: Self.enabledSettings(),
            observedAt: Self.date(250)
        )

        let second = GitHubReleaseNotificationDetector.events(
            for: [
                "steipete/RepoBar": [
                    Self.release(tag: "v1.1.0", publishedAt: Self.date(200)),
                    Self.release(tag: "v1.0.0", publishedAt: Self.date(100))
                ]
            ],
            previousState: first.state,
            settings: Self.enabledSettings(),
            observedAt: Self.date(300)
        )

        #expect(second.events.count == 1)
        #expect(second.events.first?.tag == "v1.1.0")
        #expect(second.events.first?.isPrerelease == false)
    }

    @Test
    func `pre-release and promoted release use distinct notification identifiers`() {
        var settings = Self.enabledSettings()
        settings.includePrereleases = true
        let baseline = GitHubReleaseNotificationSnapshotState(
            repositories: [
                "steipete/repobar": [
                    "v1.0.0": GitHubReleaseNotificationSnapshot(
                        publishedAt: Self.date(100),
                        isPrerelease: false
                    )
                ]
            ],
            repositoryBaselines: ["steipete/repobar": Self.date(150)]
        )
        let prerelease = GitHubReleaseNotificationDetector.events(
            for: [
                "steipete/RepoBar": [
                    Self.release(tag: "v1.1.0", publishedAt: Self.date(200), isPrerelease: true),
                    Self.release(tag: "v1.0.0", publishedAt: Self.date(100))
                ]
            ],
            previousState: baseline,
            settings: settings,
            observedAt: Self.date(250)
        )
        let stable = GitHubReleaseNotificationDetector.events(
            for: [
                "steipete/RepoBar": [
                    Self.release(tag: "v1.1.0", publishedAt: Self.date(200)),
                    Self.release(tag: "v1.0.0", publishedAt: Self.date(100))
                ]
            ],
            previousState: prerelease.state,
            settings: settings,
            observedAt: Self.date(300)
        )

        #expect(prerelease.events.count == 1)
        #expect(stable.events.count == 1)
        #expect(prerelease.events.first?.id != stable.events.first?.id)
    }

    @Test
    func `older release re-entering window does not emit as new`() {
        let first = GitHubReleaseNotificationDetector.events(
            for: ["steipete/RepoBar": [Self.release(tag: "v2.0.0", publishedAt: Self.date(200))]],
            previousState: GitHubReleaseNotificationSnapshotState(),
            settings: Self.enabledSettings(),
            observedAt: Self.date(150)
        )

        let second = GitHubReleaseNotificationDetector.events(
            for: [
                "steipete/RepoBar": [
                    Self.release(tag: "v2.0.0", publishedAt: Self.date(200)),
                    Self.release(tag: "v1.0.0", publishedAt: Self.date(100))
                ]
            ],
            previousState: first.state,
            settings: Self.enabledSettings(),
            observedAt: Self.date(250)
        )

        #expect(second.events.isEmpty)
    }

    @Test
    func `disabled settings emit nothing and preserve state`() {
        let previous = GitHubReleaseNotificationSnapshotState(
            repositories: [
                "steipete/repobar": [
                    "v1.0.0": GitHubReleaseNotificationSnapshot(
                        publishedAt: Self.date(100),
                        isPrerelease: false
                    )
                ]
            ],
            repositoryBaselines: ["steipete/repobar": Self.date(150)]
        )

        let result = GitHubReleaseNotificationDetector.events(
            for: ["steipete/RepoBar": [Self.release(tag: "v2.0.0", publishedAt: Self.date(300))]],
            previousState: previous,
            settings: GitHubReleaseNotificationSettings(),
            observedAt: Self.date(350)
        )

        #expect(result.events.isEmpty)
        #expect(result.state == previous)
    }

    @Test
    func `untracked repository is ignored`() {
        let first = GitHubReleaseNotificationDetector.events(
            for: ["steipete/RepoBar": [Self.release(tag: "v1.0.0", publishedAt: Self.date(100))]],
            previousState: GitHubReleaseNotificationSnapshotState(),
            settings: Self.enabledSettings(),
            trackedRepositoryFullNames: ["steipete/RepoBar"],
            observedAt: Self.date(150)
        )

        let second = GitHubReleaseNotificationDetector.events(
            for: [
                "steipete/RepoBar": [Self.release(tag: "v1.0.0", publishedAt: Self.date(100))],
                "other/repo": [Self.release(tag: "v9.9.9", publishedAt: Self.date(400))]
            ],
            previousState: first.state,
            settings: Self.enabledSettings(),
            trackedRepositoryFullNames: ["steipete/RepoBar"],
            observedAt: Self.date(450)
        )

        #expect(second.events.isEmpty)
        #expect(second.state.repositories["other/repo"] == nil)
    }

    private static func enabledSettings() -> GitHubReleaseNotificationSettings {
        var settings = GitHubReleaseNotificationSettings()
        settings.enabled = true
        return settings
    }

    private static func release(
        tag: String,
        publishedAt: Date,
        isPrerelease: Bool = false,
        name: String? = nil
    ) -> RepoReleaseSummary {
        RepoReleaseSummary(
            name: name ?? tag,
            tag: tag,
            url: URL(string: "https://github.com/steipete/RepoBar/releases/tag/\(tag)")!,
            publishedAt: publishedAt,
            isPrerelease: isPrerelease,
            authorLogin: nil,
            authorAvatarURL: nil,
            assetCount: 0,
            downloadCount: 0,
            assets: []
        )
    }

    private static func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
