import SwiftUI

struct SubmenuIconColumnView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        self.content
            .frame(width: MenuStyle.submenuIconColumnWidth, alignment: .center)
            .alignmentGuide(.firstTextBaseline) { dimensions in
                dimensions[VerticalAlignment.center] + MenuStyle.submenuIconBaselineOffset
            }
    }
}

struct SubmenuIconPlaceholderView: View {
    let font: Font

    init(font: Font = .caption) {
        self.font = font
    }

    var body: some View {
        SubmenuIconColumnView {
            Text(" ")
                .font(self.font)
                .accessibilityHidden(true)
        }
    }
}
