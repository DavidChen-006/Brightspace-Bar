import SwiftUI

struct FlowLayout: Layout {
    let itemSpacing: CGFloat
    let lineSpacing: CGFloat

    init(itemSpacing: CGFloat = 6, lineSpacing: CGFloat = 4) {
        self.itemSpacing = itemSpacing
        self.lineSpacing = lineSpacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width ?? 240
        return self.measure(in: width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let result = self.measure(in: bounds.width, subviews: subviews)
        for placement in result.placements {
            placement.subview.place(
                at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y),
                proposal: ProposedViewSize(width: placement.size.width, height: placement.size.height)
            )
        }
    }

    private struct Placement {
        let subview: LayoutSubview
        let origin: CGPoint
        let size: CGSize
    }

    private struct MeasureResult {
        let size: CGSize
        let placements: [Placement]
    }

    private func measure(in availableWidth: CGFloat, subviews: Subviews) -> MeasureResult {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        var placements: [Placement] = []
        placements.reserveCapacity(subviews.count)

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let exceeds = (x > 0) && (x + size.width > availableWidth)
            if exceeds {
                x = 0
                y += rowHeight + self.lineSpacing
                rowHeight = 0
            }

            placements.append(Placement(subview: subview, origin: CGPoint(x: x, y: y), size: size))
            x += size.width + self.itemSpacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x)
        }

        let totalHeight = y + rowHeight
        return MeasureResult(size: CGSize(width: min(maxX, availableWidth), height: totalHeight), placements: placements)
    }
}
