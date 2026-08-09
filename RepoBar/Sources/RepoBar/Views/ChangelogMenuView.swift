import RepoBarCore
import SwiftUI

struct ChangelogMenuView: View {
    let content: ChangelogContent

    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: MenuStyle.submenuIconSpacing) {
                SubmenuIconColumnView {
                    Image(systemName: "doc.text")
                        .symbolRenderingMode(.hierarchical)
                        .font(.caption)
                        .offset(y: -1)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                }

                Text(self.content.fileName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                    .lineLimit(1)

                Text(self.content.source.label)
                    .font(.caption2)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            ScrollView(.vertical) {
                MarkdownTextView(
                    markdown: self.content.markdown,
                    isHighlighted: self.isHighlighted
                )
                .padding(.top, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: MenuStyle.changelogPreviewHeight)
            .clipped()

            if self.content.isTruncated {
                Text("Preview truncated")
                    .font(.caption2)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
            }
        }
        .padding(.horizontal, MenuStyle.cardHorizontalPadding)
        .padding(.vertical, MenuStyle.cardVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownTextView: View {
    let markdown: String
    let isHighlighted: Bool

    var body: some View {
        let blocks = MarkdownBlockParser.parse(markdown: self.markdown)

        VStack(alignment: .leading, spacing: 4) {
            ForEach(blocks.indices, id: \.self) { index in
                ChangelogMarkdownBlockView(
                    block: blocks[index],
                    isHighlighted: self.isHighlighted
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChangelogMarkdownBlockView: View {
    let block: MarkdownBlock
    let isHighlighted: Bool

    var body: some View {
        switch self.block {
        case .blankLine:
            Color.clear.frame(height: 4)
        case let .heading(level, text):
            Text(self.inlineAttributed(text, baseFont: self.headingFont(level)))
                .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level == 1 ? 6 : 4)
        case let .listItem(marker, text, indentLevel):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(.caption)
                    .frame(width: self.markerWidth(for: marker), alignment: .leading)

                Text(self.inlineAttributed(text, baseFont: .caption))
            }
            .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, CGFloat(indentLevel) * 12)
        case let .paragraph(text):
            Text(self.inlineAttributed(text, baseFont: .caption))
                .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        case let .codeBlock(text):
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(.quaternary.opacity(self.isHighlighted ? 0.35 : 0.2))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .fixedSize(horizontal: false, vertical: true)
        case let .blockQuote(text, indentLevel):
            Text(self.inlineAttributed(text, baseFont: .caption))
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                .padding(.leading, 10 + CGFloat(indentLevel) * 12)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(MenuHighlightStyle.secondary(self.isHighlighted).opacity(0.6))
                        .frame(width: 2)
                        .padding(.leading, CGFloat(indentLevel) * 12)
                }
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:
            .system(size: 12, weight: .semibold)
        case 2:
            .system(size: 11, weight: .semibold)
        default:
            .caption.weight(.semibold)
        }
    }

    private func markerWidth(for marker: String) -> CGFloat {
        marker.count >= 2 ? 18 : 12
    }

    private func inlineAttributed(_ text: String, baseFont: Font) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        let parsed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        return self.applyBaseFont(to: parsed, baseFont: baseFont)
    }

    private func applyBaseFont(to text: AttributedString, baseFont: Font) -> AttributedString {
        var output = text
        for run in output.runs where run.font == nil {
            output[run.range].font = baseFont
        }
        return output
    }
}
