import RepoBarCore
import SwiftUI

struct HeatmapView: View {
    let cells: [HeatmapCell]
    let accentTone: AccentTone
    private let height: CGFloat?
    @Environment(\.menuItemHighlighted) private var isHighlighted
    private var summary: String {
        let total = self.cells.map(\.count).reduce(0, +)
        let maxVal = self.cells.map(\.count).max() ?? 0
        return "Commit activity heatmap, total \(total) commits, max \(maxVal) in a day."
    }

    init(cells: [HeatmapCell], accentTone: AccentTone = .githubGreen, height: CGFloat? = nil) {
        self.cells = cells
        self.accentTone = accentTone
        self.height = height
    }

    var body: some View {
        GeometryReader { proxy in
            HeatmapRasterView(cells: self.cells, accentTone: self.accentTone, isHighlighted: self.isHighlighted)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: self.height)
        .accessibilityLabel(self.summary)
        .accessibilityElement(children: .ignore)
    }
}

enum HeatmapLayout {
    static let rows = 7
    static let minColumns = 53
    static let spacing: CGFloat = 0.5
    static let cornerRadiusFactor: CGFloat = 0.12
    static let minCellSide: CGFloat = 2
    static let maxCellSide: CGFloat = 10

    static func columnCount(cellCount: Int) -> Int {
        let dataColumns = max(1, Int(ceil(Double(cellCount) / Double(self.rows))))
        return max(dataColumns, self.minColumns)
    }

    static func cellSide(for height: CGFloat) -> CGFloat {
        let totalSpacingY = CGFloat(rows - 1) * self.spacing
        let availableHeight = max(height - totalSpacingY, 0)
        let side = availableHeight / CGFloat(self.rows)
        return max(self.minCellSide, min(self.maxCellSide, floor(side)))
    }

    static func cellSide(forHeight height: CGFloat, width: CGFloat, columns: Int) -> CGFloat {
        let heightSide = self.cellSide(for: height)
        let totalSpacingX = CGFloat(max(columns - 1, 0)) * self.spacing
        let availableWidth = max(width - totalSpacingX, 0)
        let widthSide = availableWidth / CGFloat(max(columns, 1))
        let side = floor(min(heightSide, widthSide))
        return max(self.minCellSide, min(self.maxCellSide, side))
    }

    static func reshape(cells: [HeatmapCell], columns: Int) -> [[HeatmapCell]] {
        var padded = cells
        if padded.count < columns * self.rows {
            let missing = columns * self.rows - padded.count
            padded.append(contentsOf: Array(repeating: HeatmapCell(date: Date(), count: 0), count: missing))
        }
        return stride(from: 0, to: padded.count, by: self.rows).map { index in
            Array(padded[index ..< min(index + self.rows, padded.count)])
        }
    }

    static func contentWidth(columns: Int, cellSide: CGFloat) -> CGFloat {
        let totalSpacingX = CGFloat(max(columns - 1, 0)) * self.spacing
        return CGFloat(max(columns, 0)) * cellSide + totalSpacingX
    }

    static func centeredInset(available: CGFloat, content: CGFloat) -> CGFloat {
        guard available > content else { return 0 }

        return floor((available - content) / 2)
    }
}
