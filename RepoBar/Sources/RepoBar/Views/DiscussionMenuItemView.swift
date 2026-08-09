import Kingfisher
import RepoBarCore
import SwiftUI

struct DiscussionMenuItemView: View {
    let summary: RepoDiscussionSummary
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
                    if let category = self.summary.categoryName, category.isEmpty == false {
                        Text(category)
                            .font(.caption)
                            .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                            .lineLimit(1)
                    }

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

                    if self.summary.commentCount > 0 {
                        MenuStatBadge(label: nil, value: self.summary.commentCount, systemImage: "text.bubble")
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
                Image(systemName: "person.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            )
    }
}
