import RepoBarCore
import SwiftUI

struct RepoCardView: View {
    @Bindable var appModel: AppModel
    let model: RepositoryCardModel
    @Environment(\.openURL) private var openURL

    private var isPinned: Bool {
        appModel.session.settings.repoList.pinnedRepositories.contains(model.title)
    }

    private var isHidden: Bool {
        appModel.session.settings.repoList.hiddenRepositories.contains(model.title)
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                header
                stats
                if let releaseLine = model.releaseLine {
                    Text(releaseLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let activityLine = model.activityLine {
                    HStack(spacing: 6) {
                        Image(systemName: "text.bubble")
                            .foregroundStyle(.secondary)
                        Text(activityLine)
                            .font(.caption)
                            .lineLimit(2)
                        Spacer(minLength: 6)
                        if let age = model.latestActivityAge {
                            Text(age)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let error = model.error {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .lineLimit(2)
                    }
                } else if let limit = model.rateLimitedUntil {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .foregroundStyle(.orange)
                        Text("Rate limited until \(RelativeFormatter.string(from: limit, relativeTo: Date()))")
                            .font(.caption)
                    }
                }

                if appModel.session.settings.heatmap.display == .inline, !model.heatmap.isEmpty {
                    let filtered = HeatmapFilter.filter(model.heatmap, range: appModel.session.heatmapRange)
                    VStack(spacing: 4) {
                        HeatmapView(cells: filtered, accentTone: appModel.session.settings.appearance.accentTone, height: 48)
                        HeatmapAxisLabelsView(range: appModel.session.heatmapRange, foregroundStyle: Color.secondary)
                    }
                }
            }
        }
        .contextMenu {
            if isPinned {
                Button("Unpin") { Task { await appModel.removePinned(model.title) } }
            } else {
                Button("Pin") { Task { await appModel.addPinned(model.title) } }
            }
            if isHidden {
                Button("Unhide") { Task { await appModel.unhide(model.title) } }
            } else {
                Button("Hide") { Task { await appModel.hide(model.title) } }
            }
            Button("Open in GitHub") { open(repoURL()) }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.title)
                        .font(.headline)
                        .lineLimit(1)
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
            }
            Spacer()
            Button {
                open(repoURL())
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
        }
    }

    private var stats: some View {
        HStack(spacing: 8) {
            StatChip(
                label: "CI",
                value: model.ciRunCount.map(String.init),
                color: ciColor(model.ciStatus),
                textColor: ciColor(model.ciStatus)
            ) {
                open(actionsURL())
            }
            StatChip(label: "Issues", value: "\(model.issues)") { open(issuesURL()) }
            StatChip(label: "PRs", value: "\(model.pulls)") { open(pullsURL()) }
            StatChip(label: "Visitors", value: model.trafficVisitors.map(String.init) ?? "--") { }
            StatChip(label: "Cloners", value: model.trafficCloners.map(String.init) ?? "--") { }
        }
        .font(.caption2)
    }

    private func repoURL() -> URL {
        RepoWebURLBuilder(host: appModel.session.settings.githubHost)
            .repoURL(fullName: model.title) ?? appModel.session.settings.githubHost
    }

    private func issuesURL() -> URL {
        RepoWebURLBuilder(host: appModel.session.settings.githubHost)
            .issuesURL(fullName: model.title) ?? repoURL().appendingPathComponent("issues")
    }

    private func pullsURL() -> URL {
        RepoWebURLBuilder(host: appModel.session.settings.githubHost)
            .pullsURL(fullName: model.title) ?? repoURL().appendingPathComponent("pulls")
    }

    private func actionsURL() -> URL {
        RepoWebURLBuilder(host: appModel.session.settings.githubHost)
            .actionsURL(fullName: model.title) ?? repoURL().appendingPathComponent("actions")
    }

    private func open(_ url: URL) {
        openURL(url)
    }

    private func ciColor(_ status: CIStatus) -> Color {
        switch status {
        case .passing:
            return Color.green
        case .failing:
            return Color.red
        case .pending:
            return Color.blue
        case .unknown:
            return Color.gray
        }
    }
}

private struct StatChip: View {
    let label: String
    let value: String?
    let color: Color
    let textColor: Color
    let action: () -> Void

    init(
        label: String,
        value: String?,
        color: Color = Color(.systemGray5),
        textColor: Color = .primary,
        action: @escaping () -> Void = {}
    ) {
        self.label = label
        self.value = value
        self.color = color
        self.textColor = textColor
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                if let value {
                    Text(value).bold()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(color.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(textColor)
    }
}
