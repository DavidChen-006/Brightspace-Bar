import RepoBarCore
import SwiftUI

struct HeatmapView: View {
    let cells: [HeatmapCell]
    let accentTone: AccentTone
    let height: CGFloat?

    init(cells: [HeatmapCell], accentTone: AccentTone = .githubGreen, height: CGFloat? = nil) {
        self.cells = cells
        self.accentTone = accentTone
        self.height = height
    }

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let columns = HeatmapLayout.columnCount(cellCount: cells.count)
                let cellSide = HeatmapLayout.cellSide(forHeight: size.height, width: size.width, columns: columns)
                let totalSpacingX = CGFloat(max(columns - 1, 0)) * HeatmapLayout.spacing
                let contentWidth = CGFloat(columns) * cellSide + totalSpacingX
                let xOffset = HeatmapLayout.centeredInset(available: size.width, content: contentWidth)
                let palette = HeatmapPalette.palette(accentTone: accentTone)

                let reshaped = HeatmapLayout.reshape(cells: cells, columns: columns)
                for (columnIndex, column) in reshaped.enumerated() {
                    for rowIndex in 0 ..< min(HeatmapLayout.rows, column.count) {
                        let cell = column[rowIndex]
                        let bucket = HeatmapPalette.bucketIndex(for: cell.count)
                        let color = palette[min(bucket, palette.count - 1)]
                        let x = xOffset + CGFloat(columnIndex) * (cellSide + HeatmapLayout.spacing)
                        let y = CGFloat(rowIndex) * (cellSide + HeatmapLayout.spacing)
                        let rect = CGRect(x: x, y: y, width: cellSide, height: cellSide)
                        let path = RoundedRectangle(cornerRadius: cellSide * HeatmapLayout.cornerRadiusFactor)
                            .path(in: rect)
                        context.fill(path, with: .color(color))
                    }
                }
            }
        }
        .frame(height: height)
    }
}

enum HeatmapLayout {
    static let rows = 7
    static let minColumns = 53
    static let spacing: CGFloat = 1
    static let cornerRadiusFactor: CGFloat = 0.2
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

    static func centeredInset(available: CGFloat, content: CGFloat) -> CGFloat {
        guard available > content else { return 0 }
        return floor((available - content) / 2)
    }
}

enum HeatmapPalette {
    static func bucketIndex(for count: Int) -> Int {
        switch count {
        case 0: 0
        case 1 ... 3: 1
        case 4 ... 7: 2
        case 8 ... 12: 3
        default: 4
        }
    }

    static func palette(accentTone: AccentTone) -> [Color] {
        let empty = Color(.quaternaryLabel)
        switch accentTone {
        case .githubGreen:
            return [
                empty,
                Color(red: 0.74, green: 0.86, blue: 0.75).opacity(0.8),
                Color(red: 0.56, green: 0.76, blue: 0.6).opacity(0.85),
                Color(red: 0.3, green: 0.62, blue: 0.38).opacity(0.9),
                Color(red: 0.18, green: 0.46, blue: 0.24).opacity(0.95)
            ]
        case .system:
            let accent = Color.accentColor
            return [
                empty,
                accent.opacity(0.25),
                accent.opacity(0.4),
                accent.opacity(0.55),
                accent.opacity(0.7)
            ]
        }
    }
}
