import Foundation
@testable import RepoBar
import RepoBarCore
import Testing

struct HeatmapSizingTests {
    @Test
    func `pads heatmap to full grid`() {
        // 3 weeks worth of data (21 cells) should be padded to 53 * 7
        let cells = (0 ..< 21).map { HeatmapCell(date: Date().addingTimeInterval(Double($0) * 86400), count: $0 % 3) }
        let reshaped = HeatmapLayout.reshape(cells: cells, columns: 53)
        #expect(reshaped.count == 53)
        #expect(reshaped.allSatisfy { $0.count == HeatmapLayout.rows })
    }
}
