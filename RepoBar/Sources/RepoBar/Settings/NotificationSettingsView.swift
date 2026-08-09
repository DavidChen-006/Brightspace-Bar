import RepoBarCore
import SwiftUI

struct NotificationSettingsView: View {
    @Bindable var session: Session
    let appState: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Pull request notifications", isOn: self.$session.settings.gitHubPullRequestNotifications.enabled)
                    .onChange(of: self.session.settings.gitHubPullRequestNotifications.enabled) { _, enabled in
                        if enabled {
                            self.appState.resetGitHubPullRequestNotificationSnapshots()
                            self.appState.requestRefresh(cancelInFlight: true)
                        }
                        self.appState.persistSettings()
                    }

                if self.session.settings.gitHubPullRequestNotifications.enabled {
                    Toggle("New pull requests", isOn: self.$session.settings.gitHubPullRequestNotifications.newPullRequests)
                        .onChange(of: self.session.settings.gitHubPullRequestNotifications.newPullRequests) { _, _ in
                            self.appState.persistSettings()
                        }
                    Toggle("Pull request updates", isOn: self.$session.settings.gitHubPullRequestNotifications.pullRequestUpdates)
                        .onChange(of: self.session.settings.gitHubPullRequestNotifications.pullRequestUpdates) { _, _ in
                            self.appState.persistSettings()
                        }
                    Toggle("Review requested", isOn: self.$session.settings.gitHubPullRequestNotifications.reviewRequests)
                        .onChange(of: self.session.settings.gitHubPullRequestNotifications.reviewRequests) { _, _ in
                            self.appState.persistSettings()
                        }
                    Toggle("New comments", isOn: self.$session.settings.gitHubPullRequestNotifications.comments)
                        .onChange(of: self.session.settings.gitHubPullRequestNotifications.comments) { _, _ in
                            self.appState.persistSettings()
                        }
                    Picker("When clicked", selection: self.$session.settings.gitHubPullRequestNotifications.clickAction) {
                        ForEach(GitHubPullRequestNotificationClickAction.allCases, id: \.self) { action in
                            Text(action.label)
                                .tag(action)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: self.session.settings.gitHubPullRequestNotifications.clickAction) { _, _ in
                        self.appState.persistSettings()
                    }
                }
            } header: {
                Text("GitHub")
            } footer: {
                Text("Scoped to pinned repositories. The first refresh records the current state without sending notifications.")
            }

            Section {
                Toggle("Release notifications", isOn: self.$session.settings.gitHubReleaseNotifications.enabled)
                    .onChange(of: self.session.settings.gitHubReleaseNotifications.enabled) { _, enabled in
                        if enabled {
                            self.appState.resetGitHubReleaseNotificationSnapshots()
                            self.appState.requestRefresh(cancelInFlight: true)
                        }
                        self.appState.persistSettings()
                    }

                if self.session.settings.gitHubReleaseNotifications.enabled {
                    Toggle("Include pre-releases", isOn: self.$session.settings.gitHubReleaseNotifications.includePrereleases)
                        .onChange(of: self.session.settings.gitHubReleaseNotifications.includePrereleases) { _, _ in
                            self.appState.persistSettings()
                        }
                }
            } footer: {
                Text("Notifies when a pinned repository publishes a new release. Checks at most every 15 minutes and uses GitHub's conditional request cache.")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
