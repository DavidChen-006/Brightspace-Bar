import SwiftUI

struct RecentItemRowView<Leading: View, Content: View>: View {
    let alignment: VerticalAlignment
    let leadingSpacing: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let onOpen: () -> Void
    let leading: Leading
    let content: Content

    init(
        alignment: VerticalAlignment = .top,
        leadingSpacing: CGFloat = 8,
        horizontalPadding: CGFloat = 10,
        verticalPadding: CGFloat = 6,
        onOpen: @escaping () -> Void,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder content: () -> Content
    ) {
        self.alignment = alignment
        self.leadingSpacing = leadingSpacing
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.onOpen = onOpen
        self.leading = leading()
        self.content = content()
    }

    var body: some View {
        HStack(alignment: self.alignment, spacing: self.leadingSpacing) {
            self.leading
            self.content
            Spacer(minLength: 2)
        }
        .padding(.horizontal, self.horizontalPadding)
        .padding(.vertical, self.verticalPadding)
        .contentShape(Rectangle())
        .onTapGesture { self.onOpen() }
    }
}
