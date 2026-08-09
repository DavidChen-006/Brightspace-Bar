import RepoBarCore
import SwiftUI

struct IssueNavigatorResultRow: View {
    let match: GitHubReferenceMatch
    let now: Date
    let isSelected: Bool
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: self.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(self.iconForeground)
                .frame(width: 18, height: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(self.match.issueNavigatorTitle)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(self.primaryForeground)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(self.match.repositoryFullName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let state = match.state?.label {
                        Text(state)
                    }
                    Text(RelativeFormatter.string(from: self.match.updatedAt, relativeTo: self.now))
                }
                .font(.caption)
                .foregroundStyle(self.secondaryForeground)
                if let summary = self.summaryDisplayText, summary.isEmpty == false {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(self.secondaryForeground)
                        .lineLimit(self.summaryLineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(self.rowBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture(count: 2, perform: self.onOpen)
    }

    private var symbolName: String {
        switch self.match.kind {
        case .issue:
            self.match.state == .closed ? "checkmark.circle" : "exclamationmark.circle"
        case .pullRequest:
            switch self.match.state {
            case .merged: "arrow.triangle.merge"
            case .closed: "xmark.circle"
            case .open, nil: "arrow.triangle.branch.circle"
            }
        case .commit:
            "number.square"
        case .workflowRun:
            "play.circle"
        }
    }

    private var tint: Color {
        switch self.match.kind {
        case .issue:
            self.match.state == .closed ? .purple : .green
        case .pullRequest:
            self.match.state == .merged ? .purple : (self.match.state == .closed ? .red : .green)
        case .commit, .workflowRun:
            .secondary
        }
    }

    private var primaryForeground: Color {
        self.isSelected ? .white : .primary
    }

    private var secondaryForeground: Color {
        self.isSelected ? Color.white.opacity(0.76) : .secondary
    }

    private var iconForeground: Color {
        self.isSelected ? Color.white.opacity(0.92) : self.tint
    }

    private var summaryDisplayText: String? {
        self.match.aiSummary ?? self.match.bodyPreview
    }

    private var summaryLineLimit: Int {
        self.match.aiSummary == nil ? 2 : 4
    }

    private var rowBackground: Color {
        self.isSelected ? Color.accentColor.opacity(0.86) : .clear
    }
}

struct IssueNavigatorCountBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 7) {
            Text("\(self.count)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
            Text(self.count == 1 ? "match" : "matches")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06)))
    }
}
