import Kingfisher
import RepoBarCore
import SwiftUI

struct PullRequestMenuItemView: View {
    let summary: RepoPullRequestSummary
    let onOpen: () -> Void
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        RecentItemRowView(alignment: .top, onOpen: self.onOpen) {
            self.avatar
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                Text(self.summary.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text("#\(self.summary.number)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)

                    if let author = self.summary.authorLogin, author.isEmpty == false {
                        Text(author)
                            .font(.caption)
                            .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                            .lineLimit(1)
                    }

                    Text(RelativeFormatter.string(from: self.summary.updatedAt, relativeTo: Date()))
                        .font(.caption2)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)

                    Spacer(minLength: 2)

                    if self.summary.isDraft {
                        DraftPillView(isHighlighted: self.isHighlighted)
                    }

                    if self.summary.reviewCommentCount > 0 {
                        MenuStatBadge(label: nil, value: self.summary.reviewCommentCount, systemImage: "checkmark.bubble")
                    }

                    if self.summary.commentCount > 0 {
                        MenuStatBadge(label: nil, value: self.summary.commentCount, systemImage: "text.bubble")
                    }
                }

                if let head = self.summary.headRefName, let base = self.summary.baseRefName, head.isEmpty == false, base.isEmpty == false {
                    Text("\(head) → \(base)")
                        .font(.caption2)
                        .monospaced()
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)
                }

                if self.summary.labels.isEmpty == false {
                    MenuLabelChipsView(labels: self.summary.labels)
                }
            }
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = self.summary.authorAvatarURL {
            KFImage(url)
                .placeholder { self.avatarPlaceholder }
                .resizable()
                .scaledToFill()
                .frame(width: 20, height: 20)
                .clipShape(Circle())
        } else {
            self.avatarPlaceholder
                .frame(width: 20, height: 20)
        }
    }

    private var avatarPlaceholder: some View {
        Circle()
            .fill(Color(nsColor: .separatorColor))
            .overlay(
                Image(systemName: "person.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            )
    }
}

private struct DraftPillView: View {
    let isHighlighted: Bool

    var body: some View {
        Text("Draft")
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(self.isHighlighted ? .white.opacity(0.95) : Color(nsColor: .systemOrange))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(self.isHighlighted ? .white.opacity(0.16) : Color(nsColor: .systemOrange).opacity(0.14))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(self.isHighlighted ? .white.opacity(0.30) : Color(nsColor: .systemOrange).opacity(0.55), lineWidth: 1)
            )
    }
}
