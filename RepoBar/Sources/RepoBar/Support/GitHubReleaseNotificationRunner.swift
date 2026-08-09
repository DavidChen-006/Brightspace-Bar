import Algorithms
import Foundation
import RepoBarCore

@MainActor
final class GitHubReleaseNotificationRunner {
    private static let minimumPollInterval: TimeInterval = 15 * 60

    private let snapshotStore: GitHubReleaseNotificationSnapshotStore
    private let logger = RepoBarLogging.logger("GitHubNotifications")

    init(snapshotStore: GitHubReleaseNotificationSnapshotStore = GitHubReleaseNotificationSnapshotStore()) {
        self.snapshotStore = snapshotStore
    }

    func process(
        settings: GitHubReleaseNotificationSettings,
        pinnedRepositories: [String],
        github: GitHubClient,
        concurrencyLimit: Int
    ) async {
        guard settings.enabled else { return }

        let pinnedRepositories = Self.uniqueRepositoryFullNames(pinnedRepositories)
        guard pinnedRepositories.isEmpty == false else {
            self.snapshotStore.save(GitHubReleaseNotificationSnapshotState())
            return
        }

        let refreshStartedAt = Date()
        let previousState = self.snapshotStore.load()
        guard GitHubReleaseNotificationDetector.shouldPoll(
            previousState: previousState,
            now: refreshStartedAt,
            minimumInterval: Self.minimumPollInterval
        ) else {
            self.logger.debug("Skipping GitHub release notification refresh; last poll is still fresh")
            return
        }

        let releasesByRepository = await self.fetchPinnedReleases(
            for: pinnedRepositories,
            github: github,
            concurrencyLimit: concurrencyLimit
        )

        let result = GitHubReleaseNotificationDetector.events(
            for: releasesByRepository,
            previousState: previousState,
            settings: settings,
            trackedRepositoryFullNames: pinnedRepositories,
            observedAt: refreshStartedAt
        )
        var nextState = result.state
        nextState.lastCheckedAt = refreshStartedAt
        self.snapshotStore.save(nextState)

        self.logger.debug(
            "GitHub release notification refresh: repos=\(releasesByRepository.count), previousRepos=\(previousState.repositories.count), events=\(result.events.count)"
        )
        if result.events.isEmpty == false {
            self.logger.info("GitHub release notification events detected: \(result.events.count)")
        }

        for event in result.events {
            await RepoBarNotifier.shared.notify(Self.notification(for: event))
        }
    }

    func resetSnapshots() {
        self.snapshotStore.clear()
    }

    private func fetchPinnedReleases(
        for fullNames: [String],
        github: GitHubClient,
        concurrencyLimit: Int
    ) async -> [String: [RepoReleaseSummary]] {
        var result: [String: [RepoReleaseSummary]] = [:]
        for chunk in fullNames.chunks(ofCount: max(1, concurrencyLimit)) {
            await withTaskGroup(of: (String, [RepoReleaseSummary])?.self) { group in
                for fullName in chunk {
                    guard let parts = Self.repositoryParts(from: fullName) else { continue }

                    group.addTask {
                        do {
                            let releases = try await github.recentReleases(
                                owner: parts.owner,
                                name: parts.name,
                                limit: 20
                            )
                            return (fullName, releases)
                        } catch {
                            return nil
                        }
                    }
                }

                for await entry in group {
                    guard let (fullName, releases) = entry else { continue }

                    result[fullName] = releases
                }
            }
        }

        return result
    }

    private static func notification(for event: GitHubReleaseNotificationEvent) -> RepoBarNotification {
        RepoBarNotification(
            identifier: event.id,
            title: self.notificationTitle(for: event),
            body: self.notificationBody(for: event),
            url: event.url,
            clickAction: .openInBrowser
        )
    }

    private static func notificationTitle(for event: GitHubReleaseNotificationEvent) -> String {
        event.isPrerelease
            ? "New pre-release in \(event.repositoryFullName)"
            : "New release in \(event.repositoryFullName)"
    }

    private static func notificationBody(for event: GitHubReleaseNotificationEvent) -> String {
        let trimmedName = event.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false, trimmedName != event.tag else {
            return event.tag
        }

        return "\(trimmedName) (\(event.tag))"
    }

    private nonisolated static func uniqueRepositoryFullNames(_ fullNames: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for fullName in fullNames {
            let trimmed = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard trimmed.isEmpty == false, seen.insert(key).inserted else { continue }

            result.append(trimmed)
        }
        return result
    }

    private nonisolated static func repositoryParts(from fullName: String) -> (owner: String, name: String)? {
        let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].isEmpty == false, parts[1].isEmpty == false else { return nil }

        return (parts[0], parts[1])
    }
}
