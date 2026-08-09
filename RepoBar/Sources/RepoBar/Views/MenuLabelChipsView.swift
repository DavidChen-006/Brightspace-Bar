import AppKit
import RepoBarCore
import SwiftUI

struct MenuLabelChipsView: View {
    let labels: [RepoIssueLabel]
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        FlowLayout(itemSpacing: 6, lineSpacing: 4) {
            ForEach(self.labels, id: \.self) { label in
                MenuLabelChipView(label: label, isHighlighted: self.isHighlighted)
            }
        }
    }
}

private struct MenuLabelChipView: View {
    let label: RepoIssueLabel
    let isHighlighted: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let base = MenuLabelColor.nsColor(from: self.label.colorHex) ?? .separatorColor
        let baseColor = Color(nsColor: base)

        let fillOpacity: CGFloat = self.colorScheme == .dark ? 0.16 : 0.16
        let strokeOpacity: CGFloat = self.colorScheme == .dark ? 0.45 : 0.85

        let fill = self.isHighlighted ? .white.opacity(0.16) : baseColor.opacity(fillOpacity)
        let stroke = self.isHighlighted ? .white.opacity(0.30) : baseColor.opacity(strokeOpacity)
        let dot = self.isHighlighted ? .white.opacity(0.85) : baseColor
        let text = self.isHighlighted ? Color.white.opacity(0.95) : Color(nsColor: .labelColor)

        HStack(spacing: 5) {
            Circle()
                .fill(dot)
                .frame(width: 6, height: 6)
            Text(self.label.name)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(text)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(stroke, lineWidth: 1)
        )
    }
}

private enum MenuLabelColor {
    static func nsColor(from hex: String) -> NSColor? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else { return nil }

        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
    }
}
