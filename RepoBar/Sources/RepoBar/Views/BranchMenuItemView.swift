import RepoBarCore
import SwiftUI

struct BranchMenuItemView: View {
    let summary: RepoBranchSummary
    let onOpen: () -> Void
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        RecentItemRowView(alignment: .center, onOpen: self.onOpen) {
            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                .font(.caption)
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(self.summary.name)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                        .lineLimit(1)

                    if self.summary.isProtected {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    }
                }

                Text(self.shortSHA)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1)
            }
        }
    }

    private var shortSHA: String {
        String(self.summary.commitSHA.prefix(7))
    }
}
