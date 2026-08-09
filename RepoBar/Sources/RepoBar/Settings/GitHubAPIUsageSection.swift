import RepoBarCore
import SwiftUI

struct GitHubAPIUsageSection: View {
    @Bindable var session: Session
    let appState: AppState
    @State private var isRefreshing = false

    var body: some View {
        let now = Date()
        let state = self.session.rateLimitDisplayState

        Section {
            DisclosureGroup(isExpanded: self.$session.settingsAPIUsageExpanded) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        if let updated = self.lastUpdatedText(state: state, now: now) {
                            Text("Updated \(updated)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            Task { await self.refresh() }
                        } label: {
                            if self.isRefreshing {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 16, height: 16)
                            } else {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                        }
                        .controlSize(.small)
                        .disabled(self.isRefreshing)
                    }

                    ForEach(Array(self.detailSections(state: state, now: now).enumerated()), id: \.offset) { _, section in
                        GitHubAPIUsageGroup(section: section)
                    }
                }
                .padding(.top, 10)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "speedometer")
                        .foregroundStyle(state.isLimited(now: now) ? .orange : .secondary)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Usage Details")
                            .font(.body.weight(.medium))
                        Text(state.compactSummary(now: now))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } header: {
            Text("GitHub API")
        } footer: {
            Text("Usage for the active account, including shared budgets, reset times, and current blockers.")
        }
        .task(id: self.session.settingsAPIUsageExpanded) {
            guard self.session.settingsAPIUsageExpanded else { return }

            await self.refresh()
        }
    }

    private func detailSections(state: RateLimitDisplayState, now: Date) -> [RateLimitDisplaySection] {
        state.sections(now: now).filter { section in
            section.title != "Current Status"
        }
    }

    private func lastUpdatedText(state: RateLimitDisplayState, now: Date) -> String? {
        state.lastUpdatedAt.map {
            RelativeFormatter.string(from: $0, relativeTo: now)
        }
    }

    private func refresh() async {
        guard !self.isRefreshing else { return }

        self.isRefreshing = true
        defer { self.isRefreshing = false }
        await self.appState.refreshRateLimitDisplayState()
    }
}

private struct GitHubAPIUsageGroup: View {
    let section: RateLimitDisplaySection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(self.section.title ?? "Details")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(self.section.resourceRows.enumerated()), id: \.offset) { index, row in
                    if index > 0 {
                        Divider()
                    }
                    GitHubAPIRateLimitRow(row: row)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
    }
}

private struct GitHubAPIRateLimitRow: View {
    let row: RateLimitDisplayRow

    var body: some View {
        if self.row.resource != nil || self.row.quotaText != nil {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(self.row.resource ?? self.row.text)
                        .font(.body.weight(.medium))

                    Spacer(minLength: 12)

                    if let quota = self.row.quotaText {
                        Text(quota)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if let percent = self.row.percentRemaining {
                    ProgressView(value: percent, total: 100)
                        .tint(Self.tint(for: percent))
                        .accessibilityLabel(self.row.resource ?? "GitHub rate limit")
                        .accessibilityValue("\(Int(percent)) percent remaining")
                }

                if let reset = self.row.resetText {
                    Text(reset)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let detail = self.nonSampledDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
        } else {
            Text(self.row.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var nonSampledDetail: String? {
        guard let detail = self.row.detailText,
              detail.isEmpty == false,
              detail.hasPrefix("sampled ") == false
        else { return nil }

        if let reset = self.row.resetText {
            let repeatedSuffix = " · \(reset)"
            if detail.hasSuffix(repeatedSuffix) {
                return String(detail.dropLast(repeatedSuffix.count))
            }
        }
        return detail
    }

    private static func tint(for percent: Double) -> Color {
        if percent <= 10 {
            return .red
        }
        if percent <= 30 {
            return .orange
        }
        return .green
    }
}
