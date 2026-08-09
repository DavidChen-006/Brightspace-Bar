import Kingfisher
import RepoBarCore
import SwiftUI

struct CommitMenuItemView: View {
    let summary: RepoCommitSummary
    let onOpen: () -> Void
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        RecentItemRowView(alignment: .top, onOpen: self.onOpen) {
            self.avatar
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                Text(self.summary.message)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(self.shortSHA)
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)

                    if let author = self.authorLabel, author.isEmpty == false {
                        Text(author)
                            .font(.caption)
                            .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                            .lineLimit(1)
                    }

                    if let repo = self.summary.repoFullName, repo.isEmpty == false {
                        Text(repo)
                            .font(.caption2)
                            .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                            .lineLimit(1)
                    }

                    Text(RelativeFormatter.string(from: self.summary.authoredAt, relativeTo: Date()))
                        .font(.caption2)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)
                }
            }
        }
    }

    private var shortSHA: String {
        String(self.summary.sha.prefix(7))
    }

    private var authorLabel: String? {
        self.summary.authorLogin ?? self.summary.authorName
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
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            )
    }
}
