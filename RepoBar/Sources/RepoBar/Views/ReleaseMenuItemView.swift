import Kingfisher
import RepoBarCore
import SwiftUI

struct ReleaseMenuItemView: View {
    let summary: RepoReleaseSummary
    let onOpen: () -> Void
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        RecentItemRowView(alignment: .top, onOpen: self.onOpen) {
            self.avatar
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                Text(self.summary.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(self.summary.tag)
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)

                    if let author = self.summary.authorLogin, author.isEmpty == false {
                        Text(author)
                            .font(.caption)
                            .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                            .lineLimit(1)
                    }

                    Text(RelativeFormatter.string(from: self.summary.publishedAt, relativeTo: Date()))
                        .font(.caption2)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)

                    Spacer(minLength: 2)

                    if self.summary.isPrerelease {
                        PrereleasePillView(isHighlighted: self.isHighlighted)
                    }

                    if self.summary.assetCount > 0 {
                        MenuStatBadge(label: nil, value: self.summary.assetCount, systemImage: "shippingbox")
                    }

                    if self.summary.downloadCount > 0 {
                        MenuStatBadge(label: nil, value: self.summary.downloadCount, systemImage: "arrow.down.circle")
                    }
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
                Image(systemName: "tag.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            )
    }
}

private struct PrereleasePillView: View {
    let isHighlighted: Bool

    var body: some View {
        Text("Pre")
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(self.isHighlighted ? .white.opacity(0.95) : Color(nsColor: .systemPurple))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(self.isHighlighted ? .white.opacity(0.16) : Color(nsColor: .systemPurple).opacity(0.14))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(self.isHighlighted ? .white.opacity(0.30) : Color(nsColor: .systemPurple).opacity(0.55), lineWidth: 1)
            )
    }
}
