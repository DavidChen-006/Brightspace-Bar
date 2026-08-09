import Kingfisher
import RepoBarCore
import SwiftUI

struct ContributorMenuItemView: View {
    let summary: RepoContributorSummary
    let onOpen: () -> Void
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        RecentItemRowView(alignment: .top, onOpen: self.onOpen) {
            self.avatar
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                Text(self.summary.login)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                    .lineLimit(1)

                Text("\(self.summary.contributions) contributions")
                    .font(.caption)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = self.summary.avatarURL {
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
