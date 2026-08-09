import RepoBarCore
import SwiftUI

struct RepoDetailView: View {
    @Bindable var appModel: AppModel
    let repository: Repository
    @State private var model: RepoDetailModel
    @Environment(\.openURL) private var openURL

    init(appModel: AppModel, repository: Repository) {
        self.appModel = appModel
        self.repository = repository
        _model = State(initialValue: RepoDetailModel(repo: repository, github: appModel.github))
    }

    var body: some View {
        List {
            Section {
                overview
            }

            if model.isLoading {
                Section {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity)
                }
            }

            if let error = model.error {
                Section {
                    Text(error).foregroundStyle(.orange)
                }
            }

            Section("Activity") {
                NavigationLink {
                    let events = Array(repository.activityEvents.prefix(AppLimits.RepoActivity.limit))
                    RepoDetailListView(
                        title: "Recent Activity",
                        items: events,
                        id: \.url,
                        emptyText: "No recent activity"
                    ) { event in
                        Button {
                            openURL(event.url)
                        } label: {
                            ActivityRow(event: event)
                        }
                        .buttonStyle(.plain)
                    }
                } label: {
                    RepoDetailSectionRow(
                        title: "Recent Activity",
                        subtitle: subtitleText(
                            primary: repository.activityEvents.first?.title,
                            fallback: "No recent activity"
                        ),
                        count: repository.activityEvents.count,
                        symbolName: "bolt"
                    )
                }

                NavigationLink {
                    let commits = model.commits?.items ?? []
                    RepoDetailListView(
                        title: "Commits",
                        items: commits,
                        id: \.url,
                        emptyText: "No recent commits"
                    ) { commit in
                        Button {
                            openURL(commit.url)
                        } label: {
                            CommitRow(commit: commit)
                        }
                        .buttonStyle(.plain)
                    }
                } label: {
                    RepoDetailSectionRow(
                        title: "Commits",
                        subtitle: subtitleText(
                            primary: model.commits?.items.first?.message,
                            fallback: "No recent commits"
                        ),
                        count: model.commits?.items.count,
                        symbolName: "arrow.turn.down.right"
                    )
                }
            }

            Section("Code") {
                NavigationLink {
                    RepoDetailListView(
                        title: "Pull Requests",
                        items: model.pulls,
                        id: \.url,
                        emptyText: "No open pull requests"
                    ) { pr in
                        LinkRow(
                            title: "#\(pr.number) \(pr.title)",
                            subtitle: pr.authorLogin,
                            date: pr.updatedAt,
                            url: pr.url,
                            avatarURL: pr.authorAvatarURL,
                            placeholderSymbol: "person.fill"
                        )
                    }
                } label: {
                    RepoDetailSectionRow(
                        title: "Pull Requests",
                        subtitle: subtitleText(
                            primary: model.pulls.first?.title,
                            fallback: "No open pull requests"
                        ),
                        count: model.pulls.count,
                        symbolName: "arrow.triangle.branch"
                    )
                }

                NavigationLink {
                    RepoDetailListView(
                        title: "Issues",
                        items: model.issues,
                        id: \.url,
                        emptyText: "No open issues"
                    ) { issue in
                        LinkRow(
                            title: "#\(issue.number) \(issue.title)",
                            subtitle: issue.authorLogin,
                            date: issue.updatedAt,
                            url: issue.url,
                            avatarURL: issue.authorAvatarURL,
                            placeholderSymbol: "person.fill"
                        )
                    }
                } label: {
                    RepoDetailSectionRow(
                        title: "Issues",
                        subtitle: subtitleText(
                            primary: model.issues.first?.title,
                            fallback: "No open issues"
                        ),
                        count: model.issues.count,
                        symbolName: "exclamationmark.circle"
                    )
                }
            }

            Section("Releases") {
                NavigationLink {
                    RepoDetailListView(
                        title: "Releases",
                        items: model.releases,
                        id: \.url,
                        emptyText: "No releases"
                    ) { release in
                        LinkRow(
                            title: release.name,
                            subtitle: release.tag,
                            date: release.publishedAt,
                            url: release.url,
                            avatarURL: release.authorAvatarURL,
                            placeholderSymbol: "tag.fill"
                        )
                    }
                } label: {
                    RepoDetailSectionRow(
                        title: "Releases",
                        subtitle: subtitleText(
                            primary: model.releases.first?.name,
                            fallback: "No releases"
                        ),
                        count: model.releases.count,
                        symbolName: "tag"
                    )
                }

                NavigationLink {
                    RepoDetailListView(
                        title: "Workflow Runs",
                        items: model.workflows,
                        id: \.url,
                        emptyText: "No workflow runs"
                    ) { run in
                        LinkRow(
                            title: run.name,
                            subtitle: run.branch ?? "",
                            date: run.updatedAt,
                            url: run.url,
                            avatarURL: run.actorAvatarURL,
                            placeholderSymbol: "person.fill"
                        )
                    }
                } label: {
                    RepoDetailSectionRow(
                        title: "Workflow Runs",
                        subtitle: subtitleText(
                            primary: model.workflows.first?.name,
                            fallback: "No workflow runs"
                        ),
                        count: model.workflows.count,
                        symbolName: "checkmark.seal"
                    )
                }
            }

            Section("Community") {
                if repository.discussionsEnabled != false {
                    NavigationLink {
                        RepoDetailListView(
                            title: "Discussions",
                            items: model.discussions,
                            id: \.url,
                            emptyText: "No discussions"
                        ) { discussion in
                            LinkRow(
                                title: discussion.title,
                                subtitle: discussion.authorLogin,
                                date: discussion.updatedAt,
                                url: discussion.url,
                                avatarURL: discussion.authorAvatarURL,
                                placeholderSymbol: "person.fill"
                            )
                        }
                    } label: {
                        RepoDetailSectionRow(
                            title: "Discussions",
                            subtitle: subtitleText(
                                primary: model.discussions.first?.title,
                                fallback: "No discussions"
                            ),
                            count: model.discussions.count,
                            symbolName: "bubble.left.and.bubble.right"
                        )
                    }
                }

                NavigationLink {
                    RepoDetailListView(
                        title: "Contributors",
                        items: model.contributors,
                        id: \.login,
                        emptyText: "No contributors"
                    ) { contributor in
                        LinkRow(
                            title: contributor.login,
                            subtitle: "\(contributor.contributions) contributions",
                            date: nil,
                            url: contributor.url,
                            avatarURL: contributor.avatarURL,
                            placeholderSymbol: "person.fill"
                        )
                    }
                } label: {
                    RepoDetailSectionRow(
                        title: "Contributors",
                        subtitle: subtitleText(
                            primary: model.contributors.first?.login,
                            fallback: "No contributors"
                        ),
                        count: model.contributors.count,
                        symbolName: "person.3"
                    )
                }
            }

            Section("References") {
                NavigationLink {
                    RepoDetailListView(
                        title: "Tags",
                        items: model.tags,
                        id: \.name,
                        emptyText: "No tags"
                    ) { tag in
                        LinkRow(title: tag.name, subtitle: tag.commitSHA, date: nil, url: tagURL(tag.name))
                    }
                } label: {
                    RepoDetailSectionRow(
                        title: "Tags",
                        subtitle: subtitleText(
                            primary: model.tags.first?.name,
                            fallback: "No tags"
                        ),
                        count: model.tags.count,
                        symbolName: "tag.fill"
                    )
                }

                NavigationLink {
                    RepoDetailListView(
                        title: "Branches",
                        items: model.branches,
                        id: \.name,
                        emptyText: "No branches"
                    ) { branch in
                        LinkRow(title: branch.name, subtitle: branch.commitSHA, date: nil, url: branchURL(branch.name))
                    }
                } label: {
                    RepoDetailSectionRow(
                        title: "Branches",
                        subtitle: subtitleText(
                            primary: model.branches.first?.name,
                            fallback: "No branches"
                        ),
                        count: model.branches.count,
                        symbolName: "point.topleft.down.curvedto.point.bottomright.up"
                    )
                }
            }

            Section("Files") {
                NavigationLink {
                    RepoFilesView(appModel: appModel, repository: repository)
                } label: {
                    RepoDetailSectionRow(
                        title: "Browse files",
                        subtitle: "Repository tree",
                        count: nil,
                        symbolName: "folder"
                    )
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(GlassBackground())
        .navigationTitle(repository.fullName)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    openURL(repoURL())
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
            }
        }
        .task { await model.load() }
    }

    private func subtitleText(primary: String?, fallback: String) -> String? {
        if let primary, primary.isEmpty == false {
            return primary
        }
        if model.isLoading {
            return "Loading…"
        }
        return fallback
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(repository.fullName)
                    .font(.headline)
                Spacer()
            }
            HStack(spacing: 10) {
                MetricPill(label: "CI", value: repository.ciStatus.label)
                MetricPill(label: "Issues", value: "\(repository.stats.openIssues)")
                MetricPill(label: "PRs", value: "\(repository.stats.openPulls)")
                MetricPill(label: "Stars", value: "\(repository.stats.stars)")
                MetricPill(label: "Forks", value: "\(repository.stats.forks)")
            }
            if let traffic = repository.traffic {
                Text("Visitors \(traffic.uniqueVisitors) • Cloners \(traffic.uniqueCloners)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let release = repository.latestRelease {
                Text("Latest release: \(release.name) — \(ReleaseFormatter.menuLine(for: release, now: Date()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func repoURL() -> URL {
        RepoWebURLBuilder(host: appModel.session.settings.githubHost)
            .repoURL(fullName: repository.fullName) ?? appModel.session.settings.githubHost
    }

    private func tagURL(_ tag: String) -> URL {
        RepoWebURLBuilder(host: appModel.session.settings.githubHost)
            .tagURL(fullName: repository.fullName, tag: tag) ?? repoURL()
    }

    private func branchURL(_ branch: String) -> URL {
        RepoWebURLBuilder(host: appModel.session.settings.githubHost)
            .branchURL(fullName: repository.fullName, branch: branch) ?? repoURL()
    }
}

private struct MetricPill: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
            Text(value)
                .font(.caption2).bold()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct LinkRow: View {
    let title: String
    let subtitle: String?
    let date: Date?
    let url: URL?
    var avatarURL: URL? = nil
    var placeholderSymbol: String? = nil
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url { openURL(url) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                if avatarURL != nil || placeholderSymbol != nil {
                    AvatarView(
                        url: avatarURL,
                        symbolName: placeholderSymbol ?? "person.fill",
                        size: 22
                    )
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let date {
                            Text(RelativeFormatter.string(from: date, relativeTo: Date()))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct RepoDetailSectionRow: View {
    let title: String
    let subtitle: String?
    let count: Int?
    let symbolName: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbolName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                if let subtitle, subtitle.isEmpty == false {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let count {
                Text("\(count)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct RepoDetailListView<Item, ID: Hashable, Row: View>: View {
    let title: String
    let items: [Item]
    let id: KeyPath<Item, ID>
    let emptyText: String
    let row: (Item) -> Row

    var body: some View {
        List {
            if items.isEmpty {
                Text(emptyText)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items, id: id) { item in
                    row(item)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(GlassBackground())
        .listStyle(.plain)
        .navigationTitle(title)
    }
}

private extension CIStatus {
    var label: String {
        switch self {
        case .passing: "Passing"
        case .failing: "Failing"
        case .pending: "Pending"
        case .unknown: "Unknown"
        }
    }
}
